@echo off
setlocal EnableExtensions
title BlueStacksRoot ADB Diagnostic

rem ===========================================================================
rem  debug.cmd  --  read-only ADB, bootstrap-root, and SELinux diagnostic.
rem  Does NOT touch any disk image, conf, or HD-Player binary. It only launches
rem  the instance and observes adb, boot progress, root delivery, and guest SELinux, writing a
rem  redacted log to the Desktop. Run it, reproduce, then attach the .log file.
rem
rem  Usage:   debug.cmd                 (auto-detects the most-recent instance)
rem           debug.cmd Rvc64           (diagnose a specific instance)
rem ===========================================================================

rem --- self-elevate to Administrator (parity with the real tool's conditions) ---
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo [*] Requesting Administrator elevation...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
  )
  exit /b
)

rem --- extract the embedded PowerShell body (after the marker) to a temp .ps1 ---
set "SELF=%~f0"
set "PS1=%TEMP%\bsr_debug_%RANDOM%%RANDOM%.ps1"
set "BSR_DEBUG_HOME=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF); $m='#__BSR'+'_DEBUG_PS__'; $i=$t.IndexOf($m); if($i -lt 0){ Write-Error 'marker not found'; exit 1 }; [IO.File]::WriteAllText($env:PS1, $t.Substring($i))"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %1
del "%PS1%" >nul 2>&1
echo.
echo ============================================================
echo  Done. Attach the bsr_debug_*.log on your Desktop to GitHub.
echo ============================================================
pause
exit /b

#__BSR_DEBUG_PS__
param([string]$Instance)
$ErrorActionPreference = 'Continue'

# ----------------------------- logging / redaction -----------------------------
function Redact($v){
  if($null -eq $v){ return $v }
  $s = [string]$v
  $up = $env:USERPROFILE
  if($up){
    $s = $s -replace [regex]::Escape($up), '%USERPROFILE%'
    $s = $s -replace [regex]::Escape(($up -replace '\\','/')), '%USERPROFILE%'
  }
  $s = $s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)', '${1}xxxxx'
  $s
}
$ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
$Desktop = [Environment]::GetFolderPath('Desktop'); if(-not $Desktop){ $Desktop = $env:USERPROFILE }
$LogFile = Join-Path $Desktop "bsr_debug_$ts.log"
function Log($m,$c='Gray'){
  $line = ('{0:HH:mm:ss.fff}  {1}' -f (Get-Date), (Redact $m))
  try { Write-Host $line -ForegroundColor $c } catch { Write-Host $line }
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 } catch {}
}
function Section($t){ Log ''; Log ('==================== ' + $t + ' ====================') Cyan }
function Compact($s,[int]$max=100){ if($null -eq $s){ return '' }; $x = (($s -replace "`r?`n",' | ').Trim()); if($x.Length -gt $max){ $x.Substring(0,$max-3)+'...' } else { $x } }

Log "BlueStacksRoot ADB diagnostic" Green
Log "log file : $(Redact $LogFile)"
Log "OS       : $([Environment]::OSVersion.VersionString)   PowerShell $($PSVersionTable.PSVersion)"

# ----------------------------- validated layout discovery -----------------------------
function Prop($o,$n){ if($o){$p=$o.PSObject.Properties[$n];if($p){return $p.Value}};$null }
function Norm($v){
  if([string]::IsNullOrWhiteSpace("$v")){return $null}
  $s=[Environment]::ExpandEnvironmentVariables(("$v").Trim())
  if($s -match '^\s*"([^"]+)"'){$s=$Matches[1]}
  $s.Trim().Trim('"').TrimEnd(' ','\','/')
}
function ExeFrom($v){
  if([string]::IsNullOrWhiteSpace("$v")){return $null}
  $s=[Environment]::ExpandEnvironmentVariables(("$v").Trim())
  if($s -match '^\s*"([^"]+?\.exe)"'){return $Matches[1]}
  if($s -match '^\s*(.+?\.exe)(?:\s|$)'){return $Matches[1].Trim('"')}
  $null
}
function Records {
  $a=New-Object System.Collections.Generic.List[object];$seen=@{}
  function Add($src,$p){
    $i=Norm (Prop $p 'InstallDir');if(-not $i){$i=Norm (Prop $p 'InstallLocation')}
    if(-not $i){$x=ExeFrom (Prop $p 'DisplayIcon');if(-not $x){$x=ExeFrom (Prop $p 'UninstallString')};if($x){$i=Norm (Split-Path -Parent $x)}}
    $d=Norm (Prop $p 'DataDir');$u=Norm (Prop $p 'UserDefinedDir')
    if(-not $i -and -not $d -and -not $u){return}
    $id=("$i|$d|$u").ToLowerInvariant();if($seen[$id]){return};$seen[$id]=$true
    [void]$a.Add([pscustomobject]@{InstallDir=$i;DataDir=$d;UserDefinedDir=$u;Source="$src"})
  }
  foreach($root in @('HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node','HKCU:\SOFTWARE','HKCU:\SOFTWARE\WOW6432Node')){
    try{foreach($k in @(Get-ChildItem -LiteralPath $root -EA Stop|Where-Object{$_.PSChildName -match '(?i)(bluestacks|msi.*app.*player)'})){try{Add $k.PSPath (Get-ItemProperty -LiteralPath $k.PSPath -EA Stop)}catch{}}}catch{}
  }
  foreach($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')){
    try{foreach($k in @(Get-ChildItem -LiteralPath $root -EA Stop)){try{$p=Get-ItemProperty -LiteralPath $k.PSPath -EA Stop;if($k.PSChildName -match '(?i)bluestacks|msi.*app.*player' -or (Prop $p 'DisplayName') -match '(?i)bluestacks|msi.*app.*player'){Add $k.PSPath $p}}catch{}}}catch{}
  }
  @($a|ForEach-Object{$_})
}
function DataAt($v){
  $p=Norm $v;if(-not $p -or -not(Test-Path -LiteralPath $p)){return $null}
  try{if(-not(Get-Item -LiteralPath $p -EA Stop).PSIsContainer){if((Split-Path -Leaf $p)-ieq'bluestacks.conf'){$p=Split-Path -Parent $p}else{return $null}}}catch{return $null}
  for($i=0;$i-lt5-and$p;$i++){if(Test-Path -LiteralPath (Join-Path $p 'bluestacks.conf')){return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\','/')};$q=Split-Path -Parent $p;if(-not$q-or$q-eq$p){break};$p=$q}
  $null
}
function InstallAt($v){
  $p=Norm $v;if(-not$p-or-not(Test-Path -LiteralPath $p)){return $null}
  try{if(-not(Get-Item -LiteralPath $p -EA Stop).PSIsContainer){$p=Split-Path -Parent $p}}catch{return $null}
  for($i=0;$i-lt4-and$p;$i++){if((Test-Path -LiteralPath (Join-Path $p 'HD-Player.exe'))-and(Test-Path -LiteralPath (Join-Path $p 'HD-Adb.exe'))){return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\','/')};$q=Split-Path -Parent $p;if(-not$q-or$q-eq$p){break};$p=$q}
  $null
}
function Same($a,$b){if(-not$a-or-not$b){return $false};try{[IO.Path]::GetFullPath($a).TrimEnd('\','/')-ieq[IO.Path]::GetFullPath($b).TrimEnd('\','/')}catch{$a-ieq$b}}
function RecordData($r){foreach($v in @($r.DataDir,$r.UserDefinedDir)){$d=DataAt $v;if($d){return $d}};$null}

$custom=$null;$customFile=if($env:BSR_DEBUG_HOME){Join-Path $env:BSR_DEBUG_HOME 'bluestacksconfig.txt'}else{$null}
if($customFile-and(Test-Path -LiteralPath $customFile)){try{$custom=([IO.File]::ReadAllText($customFile)).Trim()}catch{}}
$records=@(Records);$customData=DataAt $custom;$customInstall=InstallAt $custom
if($custom-and-not$customData-and-not$customInstall){Log "[!] Saved custom path is not a valid install or data folder: $(Redact $custom)" Red;return}
$DataRoot=$customData
if(-not$DataRoot-and$customInstall){foreach($r in $records){$ri=InstallAt $r.InstallDir;if($ri-and(Same $ri $customInstall)){$DataRoot=RecordData $r;if($DataRoot){break}}}}
if(-not$DataRoot){foreach($r in $records){$DataRoot=RecordData $r;if($DataRoot){break}}}
if(-not$DataRoot){Log '[!] No validated BlueStacks data folder was found in the registry; use option 8 in blueStackRoot.cmd first.' Red;return}
$Install=$customInstall
if(-not$Install){foreach($r in $records){$rd=RecordData $r;$ri=InstallAt $r.InstallDir;if($ri-and$rd-and(Same $rd $DataRoot)){$Install=$ri;break}}}
if(-not$Install){try{foreach($p in @(Get-Process -Name 'HD-Player','HD-Adb' -EA SilentlyContinue)){$Install=InstallAt $p.Path;if($Install){break}}}catch{}}
if(-not$Install){try{foreach($s in @(Get-CimInstance Win32_Service -EA Stop|Where-Object{$_.Name-match'(?i)bstk|bluestacks'-or$_.DisplayName-match'(?i)bluestacks|msi.*app.*player'})){$Install=InstallAt (ExeFrom $s.PathName);if($Install){break}}}catch{}}
if(-not$Install){foreach($r in $records){$Install=InstallAt $r.InstallDir;if($Install){break}}}
if(-not$Install){Log '[!] No validated BlueStacks install folder was found; use option 8 in blueStackRoot.cmd first.' Red;return}
$Conf      = Join-Path $DataRoot 'bluestacks.conf'
$PlayerLog = Join-Path $DataRoot 'Logs\Player.log'
$Player    = Join-Path $Install 'HD-Player.exe'
$AdbExe    = Join-Path $Install 'HD-Adb.exe'

function Adb([string[]]$a){ try{ (& $AdbExe @a 2>&1 | Out-String).Trim() }catch{ "ERR: $($_.Exception.Message)" } }
function State($serial){ $o = Adb @('-s',$serial,'get-state'); ($o -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1) }

# ----------------------------- instance selection -----------------------------
function Get-ConfInstances {
  if(-not (Test-Path $Conf)){ return @() }
  try{ $ct=[IO.File]::ReadAllText($Conf) }catch{ return @() }
  @([regex]::Matches($ct,'(?im)^\s*bst\.instance\.([A-Za-z0-9_]+)\.adb_port\s*=') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}
$allInst = Get-ConfInstances
if([string]::IsNullOrWhiteSpace($Instance)){
  $eng = Join-Path $DataRoot 'Engine'; $pick = $null
  if(Test-Path $eng){
    $pick = Get-ChildItem $eng -Directory -EA SilentlyContinue | Where-Object { $allInst -contains $_.Name } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty Name
  }
  if(-not $pick -and $allInst.Count -ge 1){ $pick = $allInst[0] }
  if(-not $pick){ $pick = 'Rvc64' }
  $Instance = $pick
}

function Get-ConfPort($name,$key){
  if(-not (Test-Path $Conf)){ return $null }
  try{ $ct=[IO.File]::ReadAllText($Conf) }catch{ return $null }
  $m=[regex]::Match($ct,'(?im)^\s*bst\.instance\.'+[regex]::Escape($name)+'\.'+[regex]::Escape($key)+'\s*=\s*"?(\d+)"?')
  if($m.Success){ $m.Groups[1].Value } else { $null }
}
$statusPort = Get-ConfPort $Instance 'status.adb_port'
$adbPort    = Get-ConfPort $Instance 'adb_port'
$PrimaryPort = if($statusPort){ $statusPort } elseif($adbPort){ $adbPort } else { '5555' }

# ----------------------------- host helpers -----------------------------
function Get-BandListeners($lo,$hi){
  $o = New-Object System.Collections.Generic.List[object]
  try{
    Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -ge $lo -and $_.LocalPort -le $hi } |
      ForEach-Object { [void]$o.Add([pscustomobject]@{ Port=$_.LocalPort; PID=$_.OwningProcess; Proc=(Get-Process -Id $_.OwningProcess -EA SilentlyContinue).Name }) }
  }catch{
    try{ foreach($ln in (netstat -ano -p tcp 2>$null)){ if($ln -match 'LISTENING' -and $ln -match ':(\d{4,5})\b'){ $p=[int]$Matches[1]; if($p -ge $lo -and $p -le $hi){ [void]$o.Add([pscustomobject]@{Port=$p;PID='?';Proc='?'}) } } } }catch{}
  }
  ,@($o | Sort-Object Port -Unique)
}
function Fmt-Band($b){ ($b | ForEach-Object { "$($_.Port)/$($_.Proc)" }) -join ',' }

function Test-CmdLine($cmdLine,$name){
  if([string]::IsNullOrWhiteSpace($cmdLine) -or [string]::IsNullOrWhiteSpace($name)){ return $false }
  $e=[regex]::Escape($name); ($cmdLine -match "(?i)(^|\s)--instance(?:\s+|=)(`"$e`"|$e)(?=\s|$)")
}
function Probe-Player($name){
  $r = [ordered]@{ proc=0; wmi_total=0; wmi_match=0; cmds=@() }
  $r.proc = @(Get-Process -Name 'HD-Player' -EA SilentlyContinue).Count
  try{
    $w = @(Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -ErrorAction Stop)
    $r.wmi_total = $w.Count
    $r.wmi_match = @($w | Where-Object { Test-CmdLine $_.CommandLine $name }).Count
    $r.cmds = @($w | ForEach-Object { $_.CommandLine })
  }catch{ $r.cmds = @("WMI ERROR: $($_.Exception.Message)") }
  $r
}

$script:logOffset = 0
function Snapshot-Log { if(Test-Path $PlayerLog){ try{ $script:logOffset = (Get-Item $PlayerLog).Length }catch{ $script:logOffset = 0 } } else { $script:logOffset = 0 } }
function Read-NewLog($name){
  if(-not (Test-Path $PlayerLog)){ return @() }
  try{
    $fs=[IO.File]::Open($PlayerLog,'Open','Read','ReadWrite')
    try{
      if($fs.Length -lt $script:logOffset){ $script:logOffset = 0 }   # rotated / shrank
      $fs.Position = $script:logOffset
      $sr = New-Object IO.StreamReader($fs)
      $txt = $sr.ReadToEnd()
      $script:logOffset = $fs.Position
    } finally { $fs.Close() }
    @($txt -split "`r?`n" | Where-Object { $_ -match (' ' + [regex]::Escape($name) + ' \[') })
  }catch{ @() }
}
function Phase-Of($line){ $m=[regex]::Match($line, [regex]::Escape($Instance)+'\s+\[([A-Za-z]+)\]'); if($m.Success){ $m.Groups[1].Value } }

# ----------------------------- report environment -----------------------------
Section 'ENVIRONMENT'
Log "Install   : $(Redact $Install)   exists=$([bool](Test-Path $Install))"
Log "DataRoot  : $(Redact $DataRoot)"
Log "Conf      : $(Redact $Conf)   exists=$([bool](Test-Path $Conf))"
Log "Player.log: $(Redact $PlayerLog)   exists=$([bool](Test-Path $PlayerLog))"
Log "HD-Player : exists=$([bool](Test-Path $Player))"
Log "HD-Adb    : exists=$([bool](Test-Path $AdbExe))   version=[$(Compact (Adb @('version')))]"
if(-not (Test-Path $Player) -or -not (Test-Path $AdbExe)){ Log '[!] HD-Player.exe or HD-Adb.exe not found -- cannot continue.' Red; return }

Section 'CONF PORTS'
Log "instances in conf : $($allInst -join ', ')"
Log "TARGET instance   : $Instance" Yellow
Log "status.adb_port   : $statusPort"
Log "adb_port          : $adbPort"
Log "PRIMARY port used : $PrimaryPort  (this is what the fix should try FIRST)" Yellow

# ----------------------------- private adb server port -----------------------------
$serverBand = Get-BandListeners 15037 15057
$serverPort = '15037'
$owned = @{}; foreach($b in $serverBand){ $owned[[int]$b.Port] = ($b.Proc -ieq 'HD-Adb') }
foreach($p in 15037..15057){ if(-not $owned.ContainsKey($p) -or $owned[$p]){ $serverPort = "$p"; break } }
$env:ANDROID_ADB_SERVER_PORT = $serverPort
Log "ADB server port   : $serverPort   (current 15037-15057 listeners: $(Fmt-Band $serverBand))"

# ----------------------------- clean cold start -----------------------------
Section 'CLEAN START'
Log 'killing BlueStacks processes for a clean cold-boot timing measurement...'
Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match '^(HD-|Bstk|BlueStacks)' } | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 3
Log "kill-server  -> $(Compact (Adb @('kill-server')))"
Log "start-server -> $(Compact (Adb @('start-server')))"
Snapshot-Log

Section 'LAUNCH + WATCH'
Log "launch: HD-Player.exe --instance $Instance"
try{ Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null }catch{ Log "[!] launch failed: $($_.Exception.Message)" Red }
$sw = [Diagnostics.Stopwatch]::StartNew()

# timing knobs (reasonable, but fail fast when it is clearly NOT just slow boot)
$HARD_CAP   = 480   # absolute ceiling
$NOPROGRESS = 120   # nothing alive at all by here -> bail
$POST_READY = 75    # booted but adb won't come online even after heal -> conclusive

$readyAt=$null; $firstOnlineAt=$null; $healWorkedAt=$null; $sawProc=$false; $lastPhase=$null; $diagSerial=$null
$identityLogged=$false; $nextHeal=20; $done=$false; $verdict='(inconclusive)'

while(-not $done){
  $el = [int]$sw.Elapsed.TotalSeconds
  if($el -ge $HARD_CAP){ $verdict = "TIMEOUT: no success within $HARD_CAP s"; break }
  Start-Sleep 2
  try {
    $pp = Probe-Player $Instance
    if($pp.proc -gt 0){ $sawProc = $true }

    foreach($l in (Read-NewLog $Instance)){
      $ph = Phase-Of $l; if($ph){ $lastPhase = $ph }
      if(-not $readyAt -and ($l -match '\[Ready\]' -or $l -match 'HomeActivity' -or $l -match 'Player state:.*->\s*Player state:\s*Ready')){
        $readyAt = $el; Log "*** Player.log: instance reached [Ready] (fully booted) at elapsed=${el}s ***" Green
      }
    }

    $bl   = Get-BandListeners 5550 5900
    $cand = "127.0.0.1:$PrimaryPort"
    $conn = Adb @('connect',$cand)
    $state= State $cand
    $devs = Adb @('devices')
    $bc   = if($state -eq 'device'){ Adb @('-s',$cand,'shell','getprop','sys.boot_completed') } else { '' }

    Log ("t=${el}s proc[getproc=$($pp.proc) wmi_total=$($pp.wmi_total) wmi_match=$($pp.wmi_match)] phase=$lastPhase band=[$(Fmt-Band $bl)] connect=[$(Compact $conn 40)] state=[$state] boot=[$(Compact $bc 14)] devices=[$(Compact $devs 60)]")

    if($pp.proc -gt 0 -and $pp.wmi_match -eq 0){
      Log "   >> WMI false-zero: HD-Player IS running but instance-filtered match=0 (this is why the real tool spams 'retrying launch'):" Yellow
      foreach($cl in $pp.cmds){ Log "      cmdline: $(Redact (Compact $cl 160))" DarkGray }
    }

    if($state -eq 'device' -and -not $identityLogged){
      $identityLogged=$true
      Log "   guest identity: release=[$(Compact (Adb @('-s',$cand,'shell','getprop','ro.build.version.release')) 12)] bst=[$(Compact (Adb @('-s',$cand,'shell','getprop','bst.version')) 20)]"
    }

    # SUCCESS without heal
    if($state -eq 'device' -and (($bc -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains '1')){
      if(-not $firstOnlineAt){ $firstOnlineAt = $el }
      $diagSerial=$cand
      $verdict = "SUCCESS: $cand online + boot_completed=1 at ${el}s (no disconnect needed)"; $done=$true; break
    }

    # HEAL EXPERIMENT when offline (periodically, and immediately once [Ready] is seen)
    if($state -ne 'device' -and ($el -ge $nextHeal -or ($readyAt -and -not $healWorkedAt))){
      $nextHeal = $el + 25
      Log "   -- HEAL EXPERIMENT on $cand (state=$state): disconnect + reconnect --" Magenta
      Log "      disconnect -> $(Compact (Adb @('disconnect',$cand)) 50)"
      Start-Sleep 1
      Log "      connect    -> $(Compact (Adb @('connect',$cand)) 50)"
      Start-Sleep 2
      $s2 = State $cand
      Log "      get-state  -> $s2" $(if($s2 -eq 'device'){'Green'}else{'Yellow'})
      if($s2 -eq 'device'){
        if(-not $healWorkedAt){ $healWorkedAt=$el; Log "   >> HEAL WORKED: disconnect+connect flipped $cand offline->device at ${el}s" Green }
        $bc2 = Adb @('-s',$cand,'shell','getprop','sys.boot_completed')
        Log "      boot_completed after heal -> $(Compact $bc2 14)"
        if(($bc2 -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains '1'){
          $diagSerial=$cand
          $verdict = "SUCCESS via HEAL: $cand online+boot_completed=1 at ${el}s -- disconnect+connect WAS required (this is the fix)"; $done=$true; break
        }
      }
    }

    # fail-fast: nothing alive at all
    if(-not $sawProc -and $el -ge $NOPROGRESS -and $bl.Count -eq 0 -and -not $readyAt){
      $verdict = "FAIL-FAST: no HD-Player process, no adb listener, no Player.log activity after ${el}s -- instance never started"; break
    }
    # fail-fast: process died after we saw it
    if($sawProc -and $pp.proc -eq 0){
      $verdict = "FAIL-FAST: HD-Player disappeared at ${el}s -- instance crashed or was closed"; break
    }
    # conclusive: booted but adb won't come online even with heal
    if($readyAt -and ($el - $readyAt) -ge $POST_READY -and -not $firstOnlineAt -and -not $healWorkedAt){
      $verdict = "CONCLUSIVE: instance booted (Player.log [Ready] at ${readyAt}s) but $cand stayed offline AND disconnect+connect did not recover it after +${POST_READY}s"; break
    }
  } catch {
    Log "   [iter error] $($_.Exception.Message)" DarkYellow
  }
}

Section 'ROOT + SELINUX DIAGNOSTICS'
if($diagSerial){
  try{
    $confLines = [IO.File]::ReadAllLines($Conf) | Where-Object {
      $_ -match ('^bst\.instance\.'+[regex]::Escape($Instance)+'\.enable_root_access=') -or
      $_ -match '^bst\.(feature\.rooting|enable_adb_access)='
    }
    foreach($line in $confLines){Log "host conf: $line"}
  }catch{Log "host conf read failed: $($_.Exception.Message)" DarkYellow}
  Log "guest getenforce      : $(Compact (Adb @('-s',$diagSerial,'shell','getenforce')) 120)"
  Log "guest selinux fs      : $(Compact (Adb @('-s',$diagSerial,'shell','if [ -d /sys/fs/selinux ]; then ls -ld /sys/fs/selinux; cat /sys/fs/selinux/enforce 2>/dev/null; else echo MISSING; fi')) 180)"
  Log "guest selinux props   : $(Compact (Adb @('-s',$diagSerial,'shell','getprop ro.boot.selinux; getprop ro.build.selinux')) 120)"
  Log "guest kernel cmdline  : $(Compact (Adb @('-s',$diagSerial,'shell','cat /proc/cmdline')) 240)"
  Log "guest bindmount prop  : $(Compact (Adb @('-s',$diagSerial,'shell','getprop bst.config.bindmount')) 80)"
  Log "guest bootstrap files : $(Compact (Adb @('-s',$diagSerial,'shell','ls -l /system/etc/bsr_su /system/xbin/su /system/xbin/bstk/su /system/bin/bindmount 2>&1')) 360)"
  Log "guest bootstrap hashes: $(Compact (Adb @('-s',$diagSerial,'shell','sha256sum /system/etc/bsr_su /system/xbin/su /system/xbin/bstk/su 2>&1')) 360)"
  Log "guest xbin mount      : $(Compact (Adb @('-s',$diagSerial,'shell','mount | grep " /system/xbin "')) 300)"
  $bootstrapId=Adb @('-s',$diagSerial,'shell','/system/etc/bsr_su -c id 2>&1')
  Log "guest direct bsr_su id: $(Compact $bootstrapId 180)" $(if($bootstrapId-match'uid=0'){'Green'}else{'Yellow'})
  if($bootstrapId-match'uid=0'){
    Log "guest bsr kernel log  : $(Compact (Adb @('-s',$diagSerial,'shell','/system/etc/bsr_su -c "dmesg | grep -i bsr | tail -20"')) 500)"
  }
}else{
  Log 'Guest was never adb-ready, so root/SELinux guest probes were skipped.' Yellow
}

Section 'VERDICT'
Log $verdict $(if($verdict -match '^SUCCESS'){'Green'}else{'Red'})
Log ("timeline: PlayerLog[Ready]=$readyAt s | firstAdbOnline=$firstOnlineAt s | healWorked=$healWorkedAt s | sawProcess=$sawProc | primaryPort=$PrimaryPort")
Log ''
Log '------------------------------------------------------------------'
Log "Full log: $(Redact $LogFile)" Cyan
Log 'Attach that .log file to the GitHub issue. (Instance left running for inspection.)' Cyan
