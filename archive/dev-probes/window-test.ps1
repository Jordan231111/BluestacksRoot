# Test the BOOT WINDOW hypothesis: set feature.rooting=1 a few seconds into boot
# (after HD-Player's launch conf-rewrite, before the guest's root-init reads it).
# Minimal writes (clean, modify-only, no BOM). HD-Player patch stays on. No disk surgery.
$ErrorActionPreference='Continue'
$Inst='Rvc64'; $Install='C:\Program Files\BlueStacks_nxt'; $Conf='C:\ProgramData\BlueStacks_nxt\bluestacks.conf'
$Adb=Join-Path $Install 'HD-Adb.exe'; $Player=Join-Path $Install 'HD-Player.exe'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function A($ar){ (& $Adb @ar 2>&1 | Out-String).Trim() }
function Dev{ $d=(A @('devices')) -split "`n" | Where-Object {$_ -match '\tdevice$'} | %{($_ -split '\t')[0]}; if($d){@($d)[0]}else{$null} }
function Sh($s,$c){ (& $Adb @('-s',$s,'shell',$c) 2>&1 | Out-String).Trim() }
function RootVal{ $m=[regex]::Match([System.IO.File]::ReadAllText($Conf),'bst\.feature\.rooting="(\d)"'); if($m.Success){$m.Groups[1].Value}else{'?'} }
function SetRooting1{
  $raw=[System.IO.File]::ReadAllText($Conf)
  $new=[regex]::Replace($raw,'bst\.feature\.rooting="\d"','bst.feature.rooting="1"')
  $new=[regex]::Replace($new,'(bst\.instance\.'+$Inst+'\.enable_root_access)="\d"','$1="1"')
  if($new -ne $raw){ [System.IO.File]::WriteAllText($Conf,$new,(New-Object System.Text.UTF8Encoding($false))); return $true }
  return $false
}

Log '== kill, pre-set rooting=1 while down ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4
[void](SetRooting1); Log "   pre-launch feature.rooting=$(RootVal)"

Log '== launch ==' Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Inst) | Out-Null

# Observe the conf flips + inject 1 during the boot window (a few clean writes).
Log '== boot-window monitor (observe HD-Player rewrite; re-set 1 every 3s) ==' Cyan
for($t=3; $t -le 24; $t+=3){
  Start-Sleep 3
  $before=RootVal; $did=SetRooting1
  Log ("   t=${t}s: was rooting=$before; re-set->1 applied=$did; now=$(RootVal)")
}

Log '== wait for boot_completed ==' Cyan
$serial=$null
for($i=0;$i -lt 110;$i++){ Start-Sleep 2; & $Adb @('start-server') *>$null; $serial=Dev; if($serial -and (Sh $serial 'getprop sys.boot_completed') -match '1'){ Log "   booted serial=$serial" Green; break } }
if(-not $serial){ Log 'no device'; exit 1 }
Start-Sleep 3

Log "== post-boot feature.rooting=$(RootVal) ==" Cyan
Log '== su test ==' Cyan
foreach($c in 'su -c id','su 0 id'){ $o=Sh $serial $c; if($o -match 'uid=0'){ Log "   [$c] -> $o   <<<< ROOT" Green } else { Log "   [$c] -> '$o'" } }
$shot=Join-Path $PSScriptRoot 'window_root.png'; $b=& $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null; if($b){ [System.IO.File]::WriteAllBytes($shot,[byte[]]$b) }
Log "== done. serial=$serial ==" Cyan
