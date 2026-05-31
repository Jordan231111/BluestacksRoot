# Probe the already-running instance. EAP=Continue so adb stderr is non-fatal.
$ErrorActionPreference = 'Continue'
$Install='C:\Program Files\BlueStacks_nxt'; $Adb=Join-Path $Install 'HD-Adb.exe'
$serial='127.0.0.1:5555'
function Sh { param([string]$c) $o = & $Adb @('-s',$serial,'shell',$c) 2>&1; ($o | Out-String).Trim() }
function A  { param([string[]]$ar) $o = & $Adb @ar 2>&1; ($o | Out-String).Trim() }
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }

A @('connect',$serial) | Out-Null
Log "devices:`n$(A @('devices'))" Cyan
Log "rooting/magisk props: $(Sh 'getprop | grep -iE \"root|magisk\" || true')"

Log "`n== su discovery ==" Cyan
Log (Sh 'ls -l /system/xbin/su /system/bin/su /sbin/su /system/xbin/daemonsu 2>/dev/null; echo END')
Log ("which su: " + (Sh 'which su 2>/dev/null; echo END'))
Log ("/system mount: " + (Sh 'mount | grep -E " /system | /system/" ; echo END'))

Log "`n== root matrix (want uid=0) ==" Cyan
$m = @(
 @('su -c id','su -c id'), @('su 0 id','su 0 id'), @('su root -c id','su root -c id'),
 @('echo id|su','echo id | su'), @('su --version','su --version'),
 @('su -v','su -v'), @('su -c "id; echo OK"','su -c "id; echo OK"')
)
foreach($t in $m){ $o=Sh $t[1]; $f= if($o -match 'uid=0'){' <<<< uid=0'}else{''}; Log ("[$($t[0])] -> '$o'$f") (if($f){'Green'}else{'Gray'}) }

Log "`n== adb root ==" Cyan
Log (A @('root'))
Start-Sleep 2; A @('connect',$serial) | Out-Null
Log ("id after adb root: " + (Sh 'id'))

$shot = Join-Path $PSScriptRoot 'probe_screen.png'
$bytes = & $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null
if($bytes){ [System.IO.File]::WriteAllBytes($shot, [byte[]]$bytes); Log "screenshot -> $shot ($((Get-Item $shot).Length) b)" Green }
