# Decisive PATH A test: set rooting flags while NOTHING is running (no race), launch,
# check whether BlueStacks resets feature.rooting at launch, and whether native su then grants.
# Touches ONLY conf (modify-only, no BOM). HD-Player patch stays on. No disk surgery.
$ErrorActionPreference='Continue'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent (Split-Path -Parent $Here)
$Inst='Rvc64'; $Install='C:\Program Files\BlueStacks_nxt'; $Conf='C:\ProgramData\BlueStacks_nxt\bluestacks.conf'
$Adb=Join-Path $Install 'HD-Adb.exe'; $Player=Join-Path $Install 'HD-Player.exe'
$Engine=Join-Path $Repo 'tools\bsr_engine.ps1'
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function A($ar){ (& $Adb @ar 2>&1 | Out-String).Trim() }
function Dev{ $d=(A @('devices')) -split "`n" | Where-Object {$_ -match '\tdevice$'} | %{($_ -split '\t')[0]}; if($d){@($d)[0]}else{$null} }
function Sh($s,$c){ (& $Adb @('-s',$s,'shell',$c) 2>&1 | Out-String).Trim() }
function ConfVal($k){ $l=(Select-String -Path $Conf -Pattern ([regex]::Escape($k)+'="') -SimpleMatch -EA SilentlyContinue | Select-Object -First 1); if($l){$l.Line.Trim()}else{"(absent)"} }

Log '== kill everything for a clean, race-free state ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

Log '== set rooting flags via engine (nothing running -> no race) ==' Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Action ConfRoot -Conf $Conf -Instance $Inst 2>&1 | Select-Object -Last 1 | ForEach-Object { Log "   $_" }
Log ("   BEFORE launch: " + (ConfVal 'bst.feature.rooting') + " | " + (ConfVal "bst.instance.$Inst.enable_root_access"))

Log '== launch + wait for boot ==' Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Inst) | Out-Null
$serial=$null
for($i=0;$i -lt 120;$i++){ Start-Sleep 2; & $Adb @('start-server') *>$null; $serial=Dev; if($serial -and (Sh $serial 'getprop sys.boot_completed') -match '1'){ Log "   booted (~$($i*2)s) serial=$serial" Green; break } }
if(-not $serial){ Log 'no device; abort' Red; exit 1 }
Start-Sleep 3

Log '== did feature.rooting SURVIVE the launch? ==' Cyan
Log ("   AFTER launch:  " + (ConfVal 'bst.feature.rooting') + " | " + (ConfVal "bst.instance.$Inst.enable_root_access"))

Log '== native su test (gated su grants iff root mode set up at boot) ==' Cyan
foreach($cmd in @('su -c id','su 0 id','su root -c id')){
  $o=Sh $serial $cmd
  if($o -match 'uid=0'){ Log "   [$cmd] -> $o   <<<< ROOT" Green } else { Log "   [$cmd] -> '$o' (rc/empty)" }
}
Log ("   getprop root hints: " + (Sh $serial 'getprop | grep -iE "root|magisk|bstk" | tr "\n" " "'))
Log ("   shell id: " + (Sh $serial 'id'))

$shot=Join-Path $PSScriptRoot 'native_root.png'
$b=& $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null
if($b){ [System.IO.File]::WriteAllBytes($shot,[byte[]]$b); Log "   screenshot -> $shot" Green }
Log "== done. instance left running. serial=$serial ==" Cyan
