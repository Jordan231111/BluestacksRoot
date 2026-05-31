# Consolidated, monitored native-root probe. EAP=Continue throughout (adb writes to stderr).
$ErrorActionPreference = 'Continue'
$Instance='Rvc64'
$Install='C:\Program Files\BlueStacks_nxt'
$Adb=Join-Path $Install 'HD-Adb.exe'; $Player=Join-Path $Install 'HD-Player.exe'
$PlayerLog='C:\ProgramData\BlueStacks_nxt\Logs\Player.log'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function A  { param([string[]]$ar) $o = & $Adb @ar 2>&1; ($o | Out-String).Trim() }
function Dev {  # return current device serial or $null
  $d = (A @('devices')) -split "`n" | Where-Object { $_ -match '\tdevice$' } | ForEach-Object { ($_ -split '\t')[0] }
  if($d){ return @($d)[0] } else { return $null }
}
function Sh { param([string]$s,[string]$c) $o = & $Adb @('-s',$s,'shell',$c) 2>&1; ($o | Out-String).Trim() }

Log "==> kill all BlueStacks procs" Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','HD-Adb'){
  Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
Start-Sleep 4
$logStart = (Get-Item $PlayerLog -EA SilentlyContinue).Length; if(-not $logStart){$logStart=0}

Log "==> launch $Instance" Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null

Log "==> wait for device + boot_completed (real cold boot ~30s)" Cyan
$serial=$null; $booted=$false
for($i=0;$i -lt 120;$i++){
  Start-Sleep 2
  & $Adb @('start-server') *>$null
  $serial = Dev
  if($serial){
    $b = (Sh $serial 'getprop sys.boot_completed')
    if($b -match '1'){ $booted=$true; Log "  device=$serial boot_completed=1 (~$($i*2)s)" Green; break }
    if($i % 5 -eq 0){ Log "  device=$serial boot_completed='$b' (~$($i*2)s)" }
  } else {
    $hp = @(Get-Process -Name 'HD-Player' -EA SilentlyContinue)
    if($i % 5 -eq 0){ Log "  no device yet (~$($i*2)s); HD-Player running=$($hp.Count -gt 0)" }
    if($hp.Count -eq 0 -and $i -gt 5){ Log "  HD-Player EXITED before device appeared!" Red; break }
  }
}
$hp = @(Get-Process -Name 'HD-Player' -EA SilentlyContinue)
Log "  HD-Player running now = $($hp.Count -gt 0); booted=$booted; serial=$serial"
if(-not $serial){ Log "ABORT: no device" Red; exit 2 }
Start-Sleep 3

Log "`n==> guest state" Cyan
Log ("  release=" + (Sh $serial 'getprop ro.build.version.release') + "  debuggable=" + (Sh $serial 'getprop ro.debuggable') + "  getenforce=" + (Sh $serial 'getenforce'))
Log ("  root props: " + (Sh $serial 'getprop | grep -iE "root_access|magisk|qemu.sf" || true'))

Log "`n==> su discovery" Cyan
Log (Sh $serial 'for f in /system/xbin/su /system/bin/su /sbin/su /system/xbin/daemonsu; do ls -l $f 2>/dev/null; done; echo END')
Log ("  /system mount line: " + (Sh $serial 'mount | grep -E "( /system )" ; echo END'))

Log "`n==> root matrix (want uid=0)" Cyan
$m = @('su -c id','su 0 id','su root -c id','su --version','su -v')
foreach($cmd in $m){
  $o = Sh $serial $cmd
  $hit = $o -match 'uid=0'
  if($hit){ Log ("  [$cmd] -> $o   <<<< ROOT") Green } else { Log ("  [$cmd] -> $o") }
}
$o = & $Adb @('-s',$serial,'shell','echo id | su') 2>&1 | Out-String
Log ("  [echo id|su] -> " + $o.Trim())

Log "`n==> adb root attempt" Cyan
Log (A @('root'))
Start-Sleep 2; & $Adb @('start-server') *>$null; $serial2 = Dev
if(-not $serial2){ $serial2 = $serial }
Log ("  device after adb root = $serial2; id = " + (Sh $serial2 'id'))

$shot = Join-Path $PSScriptRoot 'probe_screen.png'
$bytes = & $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null
if($bytes){ [System.IO.File]::WriteAllBytes($shot,[byte[]]$bytes); Log "`nscreenshot -> $shot ($((Get-Item $shot).Length) b)" Green }

Log "`n==> new Player.log boot lines (cold-boot / mount / root evidence)" Cyan
$all = Get-Content $PlayerLog
$new = if($all.Count -gt 0){ $all | Select-Object -Last 120 } else { @() }
($new | Where-Object { $_ -match 'StartingAndroid|Ready|integrity|bvs|root|mount|boot_completed|Verified' }) | Select-Object -Last 25 | ForEach-Object { Log "  $_" }
Log "`n==> LEFT RUNNING. serial=$serial" Cyan
