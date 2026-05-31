# Corrected root-disk flow. The HD-Player anti-tamper patch STAYS ON (we only read it, never restore).
# Steps: DiskRW (.bstk->Normal) -> Root (inject su into Root.vhd) -> ConfRoot -> boot -> verify su uid=0.
$ErrorActionPreference = 'Continue'
$Instance = 'Rvc64'
$Install  = 'C:\Program Files\BlueStacks_nxt'
$EngRoot  = 'C:\ProgramData\BlueStacks_nxt\Engine\Rvc64'
$Conf     = 'C:\ProgramData\BlueStacks_nxt\bluestacks.conf'
$Vhd      = Join-Path $EngRoot 'Root.vhd'
$Bstk     = Join-Path $EngRoot 'Rvc64.bstk'
$Adb      = Join-Path $Install 'HD-Adb.exe'
$Player   = Join-Path $Install 'HD-Player.exe'
$Hd       = Join-Path $Install 'HD-Player.exe'
$Self     = 'C:\Users\Jordan\Documents\BluestacksRoot\blueStackRoot.cmd'
$Engine   = 'C:\Users\Jordan\Documents\BluestacksRoot\tools\bsr_engine.ps1'
$PlayerLog= 'C:\ProgramData\BlueStacks_nxt\Logs\Player.log'

function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Eng([string[]]$a,[string]$desc){
  Log "`n==== ENGINE: $desc ====" Cyan
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine @a 2>&1 | ForEach-Object { Log "   $_" }
  Log "   (exit $LASTEXITCODE)"
  return $LASTEXITCODE
}
function A  { param([string[]]$ar) $o = & $Adb @ar 2>&1; ($o | Out-String).Trim() }
function Dev { $d=(A @('devices')) -split "`n" | Where-Object {$_ -match '\tdevice$'} | ForEach-Object {($_ -split '\t')[0]}; if($d){@($d)[0]}else{$null} }
function Sh { param([string]$s,[string]$c) $o = & $Adb @('-s',$s,'shell',$c) 2>&1; ($o | Out-String).Trim() }

# 0) Safety: confirm patch is ON (read-only check; we DO NOT modify HD-Player here).
$fs=[System.IO.File]::OpenRead($Hd); $buf=New-Object byte[] 4; $fs.Position=0xB46E6; [void]$fs.Read($buf,0,4); $fs.Close()
$hex = ($buf | ForEach-Object { $_.ToString('X2') }) -join ' '
if($hex -eq '84 C0 90 90'){ Log "[OK] HD-Player anti-tamper patch is APPLIED (84 C0 90 90). Leaving it untouched." Green }
else { Log "[STOP] HD-Player NOT patched (got $hex). Aborting so we don't boot into anti-tamper." Red; exit 9 }

# 1) kill for clean state
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 3

# 2) root-disk: .bstk -> Normal, inject su, conf flags  (NO Patch action)
if((Eng @('-Action','DiskRW','-Bstk',$Bstk) '.bstk Root.vhd -> Normal') -ne 0){ Log "DiskRW failed" Red }
if((Eng @('-Action','Root','-Vhd',$Vhd,'-SelfPath',$Self) 'inject su into Root.vhd (offline ext4)') -ne 0){ Log "Root inject failed; aborting" Red; exit 3 }
if((Eng @('-Action','ConfRoot','-Conf',$Conf,'-Instance',$Instance) 'conf root flags') -ne 0){ Log "ConfRoot failed (continuing)" Yellow }

# 3) boot
Log "`n==== BOOT $Instance (patch ON, disk rooted) ====" Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null
$serial=$null;$booted=$false
for($i=0;$i -lt 120;$i++){
  Start-Sleep 2; & $Adb @('start-server') *>$null; $serial=Dev
  if($serial){ if((Sh $serial 'getprop sys.boot_completed') -match '1'){ $booted=$true; Log "  device=$serial boot_completed=1 (~$($i*2)s)" Green; break } }
  elseif($i -gt 6 -and @(Get-Process -Name 'HD-Player' -EA SilentlyContinue).Count -eq 0){ Log "  HD-Player EXITED before boot (anti-tamper or crash). Check Player.log." Red; break }
  if($i % 6 -eq 0){ Log "  ...waiting (~$($i*2)s) serial=$serial" }
}
if(-not $serial){ Log "ABORT: no device" Red; exit 4 }
Start-Sleep 3

# 4) verify
Log "`n==== VERIFY ROOT ====" Cyan
Log ("  enforce=" + (Sh $serial 'getenforce') + "  release=" + (Sh $serial 'getprop ro.build.version.release'))
Log ("  su file: " + (Sh $serial 'ls -l /system/xbin/su 2>/dev/null; echo END'))
$rooted=$false
foreach($cmd in @('su -c id','su 0 id','su root -c id')){
  $o=Sh $serial $cmd
  if($o -match 'uid=0'){ Log "  [$cmd] -> $o   <<<< ROOT uid=0" Green; $rooted=$true } else { Log "  [$cmd] -> $o" }
}
$shot = Join-Path $PSScriptRoot 'root_verify.png'
$bytes = & $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null
if($bytes){ [System.IO.File]::WriteAllBytes($shot,[byte[]]$bytes); Log "  screenshot -> $shot" Green }

Log "`n==== boot-log evidence ====" Cyan
(Get-Content $PlayerLog | Select-Object -Last 80 | Where-Object { $_ -match 'StartingAndroid|Ready|integrity|bvs|Verified|Failed to verify' } | Select-Object -Last 8) | ForEach-Object { Log "  $_" }

if($rooted){ Log "`n*** ROOT CONFIRMED (uid=0). Instance left running for Magisk. serial=$serial ***" Green }
else { Log "`n*** su present but did NOT return uid=0 -- next: diagnose su invocation (NOT the patch). serial=$serial ***" Yellow }
