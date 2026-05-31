# Phase A: native-root probe. NO disk surgery. Fully reversible.
# Sets feature.rooting=1 + enable_root_access=1 (modify-only, no BOM), cold-boots Rvc64,
# then empirically probes every su path/invocation and reports uid. Leaves instance running.
$ErrorActionPreference = 'Stop'
$Instance = 'Rvc64'
$Install  = 'C:\Program Files\BlueStacks_nxt'
$Conf     = 'C:\ProgramData\BlueStacks_nxt\bluestacks.conf'
$Adb      = Join-Path $Install 'HD-Adb.exe'
$Player   = Join-Path $Install 'HD-Player.exe'
$Port     = 5555
$serial   = "127.0.0.1:$Port"

function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function A { param([string[]]$ar) (& $Adb @ar 2>&1 | Out-String) }
function Sh { param([string]$c) (& $Adb @('-s',$serial,'shell',$c) 2>&1 | Out-String) }

Log "==> Killing BlueStacks processes for a clean cold boot" Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper'){
  Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
Start-Sleep 3

# --- conf: backup + modify-only, no BOM ---
if(-not (Test-Path "$Conf.probebak")){ Copy-Item $Conf "$Conf.probebak" -Force; Log "  backed up conf -> conf.probebak" }
$txt = [System.IO.File]::ReadAllText($Conf)
function SetKey($t,$k,$v){
  $rx = [regex]::Escape($k) + '="[^"]*"'
  if($t -match $rx){ return ([regex]::Replace($t, $rx, ($k + '="' + $v + '"'))) }
  Log "  (key absent, NOT adding): $k" Yellow; return $t
}
$txt = SetKey $txt 'bst.feature.rooting' '1'
$txt = SetKey $txt "bst.instance.$Instance.enable_root_access" '1'
$txt = SetKey $txt 'bst.enable_adb_access' '1'
[System.IO.File]::WriteAllText($Conf, $txt, (New-Object System.Text.UTF8Encoding($false)))
Log "  conf set: feature.rooting=1, $Instance.enable_root_access=1, enable_adb_access=1 (no BOM)" Green
$bom = [System.IO.File]::ReadAllBytes($Conf)[0..2] -join ','
Log "  conf first 3 bytes: $bom  (BOM would be 239,187,191)"

Log "==> Launching $Instance (cold boot)" Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null

Log "==> Waiting for boot (adb connect + sys.boot_completed)..." Cyan
$booted = $false
for($i=0; $i -lt 90; $i++){
  Start-Sleep 2
  A @('connect',$serial) | Out-Null
  $b = (Sh 'getprop sys.boot_completed').Trim()
  if($b -match '1'){ $booted=$true; Log "  boot_completed=1 after ~$($i*2)s" Green; break }
  if($i % 10 -eq 0){ Log "  ...waiting ($($i*2)s) boot_completed='$b'" }
}
if(-not $booted){ Log "  TIMEOUT waiting for boot" Red }
Start-Sleep 3

Log "==> Device + build state" Cyan
Log ("  devices:`n" + (A @('devices')))
Log ("  ro.build.version.release = " + (Sh 'getprop ro.build.version.release').Trim())
Log ("  ro.debuggable           = " + (Sh 'getprop ro.debuggable').Trim())
Log ("  ro.boot.selinux         = " + (Sh 'getprop ro.boot.selinux').Trim())
Log ("  getenforce              = " + (Sh 'getenforce').Trim())
Log ("  bst rooting props       = " + (Sh 'getprop | grep -iE "root|magisk"').Trim())

Log "==> su discovery" Cyan
Log (Sh 'ls -l /system/xbin/su /system/bin/su /sbin/su /debug_ramdisk/su 2>/dev/null; echo "---"; which su')

Log "==> root invocation matrix (looking for uid=0)" Cyan
$tests = @(
  @('adb root',            'A',  @('root')),
  @('su -c id',            'SH', 'su -c id'),
  @('su 0 id',             'SH', 'su 0 id'),
  @('su root -c id',       'SH', 'su root -c id'),
  @('su -c "id"',          'SH', 'su -c "id"'),
  @('echo id | su',        'SH', 'echo id | su'),
  @('su --version',        'SH', 'su --version'),
  @('/system/xbin/su -c id','SH','/system/xbin/su -c id')
)
foreach($t in $tests){
  $name=$t[0]
  if($t[1] -eq 'A'){ $out = A $t[2] } else { $out = Sh $t[2] }
  $out = $out.Trim()
  $flag = if($out -match 'uid=0'){'  <<< ROOT uid=0'}else{''}
  Log ("  [$name] -> '$out'$flag") (if($flag){'Green'}else{'Gray'})
}

# re-probe after adb root (it may restart adbd as root)
Start-Sleep 1; A @('connect',$serial) | Out-Null
Log ("  [after adb root] id = " + (Sh 'id').Trim())

$shot = Join-Path $PSScriptRoot 'probe_screen.png'
& $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null | Set-Content -Path $shot -Encoding Byte -EA SilentlyContinue
if(Test-Path $shot){ Log "  screenshot -> $shot ($((Get-Item $shot).Length) bytes)" Green }

Log "==> Instance LEFT RUNNING for follow-up. conf backup at $Conf.probebak" Cyan
