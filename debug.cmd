@echo off
setlocal EnableExtensions
title BlueStacksRoot ADB Diagnostic

rem ===========================================================================
rem  debug.cmd  --  read-only ADB / boot-timing diagnostic for BlueStacksRoot.
rem  Does NOT touch any disk image, conf, or HD-Player binary. It only launches
rem  the instance and observes how adb + the boot progress behave, writing a
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

# ----------------------------- registry discovery -----------------------------
function Get-Reg {
  foreach($k in @('HKLM:\SOFTWARE\BlueStacks_nxt','HKLM:\SOFTWARE\BlueStacks_msi5',
                  'HKLM:\SOFTWARE\WOW6432Node\BlueStacks_nxt','HKLM:\SOFTWARE\WOW6432Node\BlueStacks_msi5')){
    try{ $p = Get-ItemProperty -Path $k -ErrorAction Stop
         if($p -and ($p.InstallDir -or $p.DataDir -or $p.UserDefinedDir)){ return $p } }catch{}
  }
  return $null
}
$reg = Get-Reg
$Install = if($reg -and $reg.InstallDir){ $reg.InstallDir.TrimEnd('\') } else { Join-Path $env:ProgramFiles 'BlueStacks_nxt' }
$DataRoot = if($reg -and $reg.DataDir){ $reg.DataDir } elseif($reg -and $reg.UserDefinedDir){ $reg.UserDefinedDir } else { Join-Path $env:ProgramData 'BlueStacks_nxt' }
if($DataRoot -match '(?i)[\\/]engine[\\/]?$'){ $DataRoot = $DataRoot -replace '(?i)[\\/]engine[\\/]?$','' }
$DataRoot = $DataRoot.TrimEnd('\','/')
$Conf      = Join-Path $DataRoot 'bluestacks.conf'
$PlayerLog = Join-Path $DataRoot 'Logs\Player.log'
$Player    = Join-Path $Install 'HD-Player.exe'
$AdbExe    = Join-Path $Install 'HD-Adb.exe'
if(-not (Test-Path $AdbExe)){
  foreach($c in @((Join-Path $env:ProgramFiles 'BlueStacks_nxt\HD-Adb.exe'),
                  (Join-Path ${env:ProgramFiles(x86)} 'BlueStacks_nxt\HD-Adb.exe'),
                  (Join-Path $env:ProgramFiles 'BlueStacks_msi5\HD-Adb.exe'))){ if(Test-Path $c){ $AdbExe=$c; break } }
}

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

$readyAt=$null; $firstOnlineAt=$null; $healWorkedAt=$null; $sawProc=$false; $lastPhase=$null
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

Section 'VERDICT'
Log $verdict $(if($verdict -match '^SUCCESS'){'Green'}else{'Red'})
Log ("timeline: PlayerLog[Ready]=$readyAt s | firstAdbOnline=$firstOnlineAt s | healWorked=$healWorkedAt s | sawProcess=$sawProc | primaryPort=$PrimaryPort")
Log ''
Log '------------------------------------------------------------------'
Log "Full log: $(Redact $LogFile)" Cyan
Log 'Attach that .log file to the GitHub issue. (Instance left running for inspection.)' Cyan
