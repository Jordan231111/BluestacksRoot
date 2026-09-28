@echo off
setlocal EnableExtensions
title BlueStacksRoot ADB Diagnostic
set "SELF=%~f0"
set "BSR_DEBUG_INSTANCE=%~1"

rem ===========================================================================
rem  debug.cmd -- Windows disk/launch and Android root diagnostic (v20).
rem  Restarts only the selected instance. Disk probes attach READ-ONLY and only
rem  when no players are running. No image, conf, executable or security setting is edited.
rem  User-directory names are masked; technical paths, errors and policy evidence are retained.
rem
rem  Usage:   debug.cmd                 (auto-detects the most-recent instance)
rem           debug.cmd Rvc64           (diagnose a specific instance)
rem ===========================================================================

rem --- self-elevate to Administrator (parity with the real tool's conditions) ---
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo [*] Requesting Administrator elevation...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -ArgumentList $env:BSR_DEBUG_INSTANCE -Verb RunAs"
  )
  exit /b
)

rem --- extract the embedded PowerShell body (after the marker) to a temp .ps1 ---
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

$hostText = [IO.File]::ReadAllText($env:SELF)
$hostStart = $hostText.IndexOf('__BSR_HOST_' + 'BEGIN__')
$hostStop = $hostText.IndexOf('__BSR_HOST_' + 'END__')
if ($hostStart -lt 0 -or $hostStop -le $hostStart) { throw 'Diagnostic HOST helpers are missing; download the complete debug.cmd.' }
$hostStart = $hostText.IndexOf([char]10, $hostStart) + 1
. ([scriptblock]::Create($hostText.Substring($hostStart, $hostStop - $hostStart)))

# ----------------------------- logging / redaction -----------------------------
function Redact($v){
  if($null -eq $v){ return $v }
  $s = [string]$v
  $up = $env:USERPROFILE
  if($up){
    $parent=Split-Path -Parent $up
    $masked=if($parent){[IO.Path]::Combine($parent,'xxxxx')}else{'%USERPROFILE%'}
    $s = $s -replace ('(?i)'+[regex]::Escape($up.TrimEnd('\','/'))+'(?=[\\/\s"''<>]|$)'), ($masked -replace '\$','$$')
    $s = $s -replace ('(?i)'+[regex]::Escape(($up.TrimEnd('\','/') -replace '\\','/'))+'(?=[\\/\s"''<>]|$)'), (($masked -replace '\\','/') -replace '\$','$$')
  }
  $s = $s -replace '(?i)([A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)(?!xxxxx\b)([^\\/\r\n"<>]+)', '${1}xxxxx'
  $s
}
$ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
$Desktop = [Environment]::GetFolderPath('Desktop'); if(-not $Desktop){ $Desktop = $env:USERPROFILE }
$LogFile = Join-Path $Desktop "bsr_debug_$ts.log"
function Log($m,$c='Gray'){
  $line = ('{0:HH:mm:ss.fff}  {1}' -f (Get-Date), (Redact $m))
  try { Write-Host $line -ForegroundColor $c } catch { Write-Host $line }
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 -ErrorAction Stop } catch { Write-Host '[!] Could not write the diagnostic log. Check the Desktop folder permissions.' -ForegroundColor Red }
}
function Section($t){ Log ''; Log ('==================== ' + $t + ' ====================') Cyan }
function Compact($s,[int]$max=100){ if($null -eq $s){ return '' }; $x = (((Redact $s) -replace "`r?`n",' | ').Trim()); if($x.Length -gt $max){ $x.Substring(0,$max-3)+'...' } else { $x } }

function Log-Failure($stage,$failure){
  Log "[!] $stage" Yellow
  Log "category=$($failure.CategoryInfo.Category); id=$($failure.FullyQualifiedErrorId)"
  $e=$failure.Exception
  for($i=0;$e -and $i -lt 6;$i++){
    $hr=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.HResult),0)
    $native=if($e -is [ComponentModel.Win32Exception]){$e.NativeErrorCode}else{'n/a'}
    Log ("exception[{0}] {1}; HRESULT=0x{2:X8}; Win32={3}; {4}" -f $i,$e.GetType().FullName,$hr,$native,$e.Message)
    $e=$e.InnerException
  }
  if($failure.ErrorDetails){Log "details: $($failure.ErrorDetails.Message)"}
}

function Report-PolicyEvents {
  Section 'RELATED WINDOWS EVENTS (last hour, bounded search)'
  foreach($channel in @('Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-AppLocker/EXE and DLL','Microsoft-Windows-Windows Defender/Operational','Application')){
    try{
      $all=@(Get-WinEvent -FilterHashtable @{LogName=$channel;StartTime=(Get-Date).AddHours(-1)} -MaxEvents 200 -ErrorAction Stop)
      $related=@($all | Where-Object {$_.Message -match '(?i)HD-Player\.exe|HD-Adb\.exe|Root\.vhd|BlueStacks|bsr_(engine|magisk|work)'} | Select-Object -First 10)
      Log "$channel : scanned=$($all.Count); matched=$($related.Count); scanLimit=200; reportLimit=10"
      foreach($event in $related){Log "event=$($event.Id); record=$($event.RecordId); time=$($event.TimeCreated.ToString('s')); level=$($event.LevelDisplayName); $(Compact $event.Message 2500)"}
    }catch{Log "$channel : unavailable or no matching events; $(Compact $_.Exception.Message 300)"}
  }
  Log 'An empty, disabled, or unavailable event log does not prove that a security policy allowed the launch.'
}

function Get-DiagnosticHash([string]$path){
  $stream=[IO.File]::Open($path,'Open','Read','ReadWrite')
  $sha=[Security.Cryptography.SHA256]::Create()
  try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
  finally{$sha.Dispose();$stream.Dispose()}
}

function Report-HostDetails {
  Section 'WINDOWS CONTEXT'
  $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  Log "elevated=$admin; process64bit=$([Environment]::Is64BitProcess); OS64bit=$([Environment]::Is64BitOperatingSystem); languageMode=$($ExecutionContext.SessionState.LanguageMode)"
  try{$cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA Stop;Log "Windows build=$($cv.CurrentBuildNumber).$($cv.UBR); displayVersion=$($cv.DisplayVersion)"}catch{Log-Failure 'Windows build query' $_}
  try{
    $policy=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -EA Stop
    foreach($key in @('EnableLUA','ValidateAdminCodeSignatures','EnableSecureUIAPaths','ConsentPromptBehaviorAdmin')){Log "UAC $key=$($policy.$key)"}
  }catch{Log-Failure 'UAC policy query' $_}
  try{
    $dg=Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -OperationTimeoutSec 5 -EA Stop
    Log "DeviceGuard: VBS=$($dg.VirtualizationBasedSecurityStatus); kernelCI=$($dg.CodeIntegrityPolicyEnforcementStatus); userCI=$($dg.UsermodeCodeIntegrityPolicyEnforcementStatus) (CI: 0=off, 1=audit, 2=enforced)"
  }catch{Log "DeviceGuard unavailable: $(Compact $_.Exception.Message 250)"}
  foreach($name in @('vds','AppIDSvc','WinDefend')){
    try{$svc=Get-Service -Name $name -EA Stop;Log "service $name : status=$($svc.Status); startType=$($svc.StartType)"}catch{Log "service $name : unavailable"}
  }
  Log 'A stopped manual-start service alone does not establish a failure.'
  try{Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntivirusProduct -OperationTimeoutSec 5 -EA Stop | ForEach-Object {Log "registered antivirus: $($_.displayName); productState=$($_.productState)"}}catch{Log "Antivirus registration query unavailable: $(Compact $_.Exception.Message 250)"}
  try{Log "Storage module: $((Get-Command Mount-DiskImage -EA Stop).Module.Version); virtdisk.dll=$((Get-Item (Join-Path $env:WINDIR 'System32\virtdisk.dll') -EA Stop).VersionInfo.FileVersion)"}catch{Log-Failure 'Virtual disk provider components' $_}
  foreach($path in @($Install,$DataRoot)){
    try{
      $volume=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($path))
      Log "volume for $path : type=$($volume.DriveType); filesystem=$($volume.DriveFormat); freeBytes=$($volume.AvailableFreeSpace)"
      Log "directory ACL $path : $((Get-Acl -LiteralPath $path -EA Stop).Sddl)"
    }catch{Log-Failure 'Volume/directory inspection' $_}
  }
  foreach($path in @($Player,"$Player.bak")){
    if(-not(Test-Path -LiteralPath $path)){continue}
    try{
      $file=Get-Item -LiteralPath $path -EA Stop
      Log "player file: $path; bytes=$($file.Length); attributes=$($file.Attributes); version=$($file.VersionInfo.FileVersion); SHA256=$(Get-DiagnosticHash $path)"
      Log "signature: $((Get-AuthenticodeSignature -LiteralPath $path -EA Stop).Status)"
      $zone=Get-Content -LiteralPath $path -Stream Zone.Identifier -EA SilentlyContinue | Where-Object {$_ -match '^ZoneId=\d+$'}
      Log "download zone: $(if($zone){$zone -join ','}else{'no ZoneId recorded'})"
      if($path -eq $Player -and $file.Length -lt 64MB){
        $text=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
        $manifest=[regex]::Match($text,'<requestedExecutionLevel\b[^>]{0,200}>')
        Log "execution manifest: $(if($manifest.Success){$manifest.Value}else{'not found by bounded text scan'})"
      }
    }catch{Log-Failure 'Player file inspection' $_}
  }
}

function Probe-RootDisk([string]$path){
  Section 'READ-ONLY DISK PROBE'
  if(-not(Test-Path -LiteralPath $path)){Log "Root image not found: $path" Yellow;return $true}
  if(@(Get-Process -Name HD-Player -EA SilentlyContinue).Count){Log 'Attach probe skipped: a BlueStacks player is running and may share this master. Close the other instances and rerun for mount evidence.' Yellow;return $true}
  $mounted=$null;$detached=$true
  try{
    $format=Get-BsrDiskFormat $path
    Log "probe path=$path; detected=$format; extension=$([IO.Path]::GetExtension($path)); access=ReadOnly"
    if($format -notin @('VHD','VHDX')){Log 'Unsupported or incomplete image; no attach attempted.' Yellow;return $true}
    $existing=Get-DiskImage -ImagePath $path -StorageType $format -EA Stop
    if($existing.Attached){Log 'Image already attached; leaving the existing attachment alone.' Yellow;return $true}
    $mounted=Mount-DiskImage -ImagePath $path -StorageType $format -Access ReadOnly -NoDriveLetter -PassThru -EA Stop
    $disk=$mounted | Get-Disk -EA Stop
    Log "attach succeeded: disk=$($disk.Number); bytes=$($disk.Size); style=$($disk.PartitionStyle); logicalSector=$($disk.LogicalSectorSize); physicalSector=$($disk.PhysicalSectorSize); readOnly=$($disk.IsReadOnly); offline=$($disk.IsOffline)"
    foreach($part in @(Get-Partition -DiskNumber $disk.Number -EA Stop)){Log "partition=$($part.PartitionNumber); offset=$($part.Offset); bytes=$($part.Size); type=$($part.Type)"}
  }catch{Log-Failure 'Disk attach/inspection failed (no disk writes attempted)' $_}
  finally{
    if($mounted){try{Dismount-DiskImage -InputObject $mounted -EA Stop | Out-Null;Log 'Our read-only attachment was detached.'}catch{$detached=$false;Log-Failure 'Detach failed; player launch will be skipped' $_}}
  }
  return $detached
}

Log "BlueStacksRoot v20 diagnostic" Green
Log 'Privacy: user-directory names are masked. Technical paths, ACLs, Windows errors and related event details are kept. Review the log before posting; it is never uploaded automatically.'
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

function Quote-NativeArgument([string]$value){
  $escaped=[regex]::Replace($value,'(\\*)"','$1$1\"')
  '"'+[regex]::Replace($escaped,'(\\+)$','$1$1')+'"'
}
function Adb([string[]]$a){
  $process=$null
  try{
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$AdbExe;$psi.Arguments=($a | ForEach-Object {Quote-NativeArgument $_}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($psi)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(8000)){$process.Kill();Log "ADB timed out after 8s: $($a -join ' ')" Yellow;return 'ERR: adb command timed out'}
    if(-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)){return 'ERR: adb output pipe did not close'}
    $output=($stdout.Result+"`n"+$stderr.Result).Trim()
    if($process.ExitCode){Log "ADB exit=$($process.ExitCode); command=$($a -join ' '); $(Compact $output 800)" DarkYellow}
    $output
  }catch{Log-Failure 'ADB invocation failed' $_;"ERR: $($_.Exception.Message)"}
  finally{if($process){$process.Dispose()}}
}
function State($serial){
  $o=Adb @('-s',$serial,'get-state')
  $state=@($o -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^(device|offline|unauthorized|unknown)$'} | Select-Object -Last 1)
  if($state.Count){$state[0]}else{'unavailable'}
}

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
if($Instance -notmatch '^[A-Za-z0-9_]+$' -or $allInst -notcontains $Instance){Log 'Selected instance is not a registered BlueStacks instance. Check its internal name in bluestacks.conf.' Red;return}

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
function Get-ExactPlayers($name){
  $ids=New-Object System.Collections.Generic.List[int]
  try{Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -EA Stop | Where-Object {Test-CmdLine $_.CommandLine $name} | ForEach-Object {$ids.Add([int]$_.ProcessId)}}catch{}
  try{
    $tail=(Get-Content -LiteralPath $PlayerLog -Tail 6000 -EA Stop) -join "`n"
    $matchesForName=[regex]::Matches($tail,'(?m)^(\S+\s+\S+)\s+(\d+)\s+\d+\s+\S+\s+'+[regex]::Escape($name)+'\s+\[')
    if($matchesForName.Count){
      $last=$matchesForName[$matchesForName.Count-1]
      $candidate=Get-Process -Id ([int]$last.Groups[2].Value) -EA Stop
      $logged=[datetimeoffset]::Parse($last.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
      if($logged.UtcDateTime -ge $candidate.StartTime.ToUniversalTime().AddSeconds(-2)){$ids.Add($candidate.Id)}
    }
  }catch{}
  if($script:launchedPid){$ids.Add([int]$script:launchedPid)}
  @($ids | Select-Object -Unique | ForEach-Object {Get-Process -Id $_ -EA SilentlyContinue} | Where-Object {$_.Name -eq 'HD-Player'})
}
function Get-BsrDiagnosticTargetPort($listeners,$ids,$preferred){
  @($listeners | Where-Object {$ids -contains $_.PID} |
    Sort-Object @{Expression={if($_.Port -eq [int]$preferred){0}else{1}}},Port |
    Select-Object -First 1 -ExpandProperty Port)
}
function Probe-Player($name){
  $r = [ordered]@{ proc=0; exact=0; ids=@(); wmi_total=0; wmi_match=0; cmds=@() }
  $r.proc = @(Get-Process -Name 'HD-Player' -EA SilentlyContinue).Count
  $exact=@(Get-ExactPlayers $name);$r.exact=$exact.Count;$r.ids=@($exact | Select-Object -ExpandProperty Id)
  try{
    $w = @(Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -ErrorAction Stop)
    $r.wmi_total = $w.Count
    $r.wmi_match = @($w | Where-Object { Test-CmdLine $_.CommandLine $name }).Count
    $r.cmds = @($w | Where-Object {Test-CmdLine $_.CommandLine $name} | ForEach-Object { $_.CommandLine })
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
      if($fs.Length - $script:logOffset -gt 256KB){$script:logOffset=$fs.Length-256KB;Log 'Player.log burst limited to the newest 256 KB.'}
      $fs.Position = $script:logOffset
      $sr = New-Object IO.StreamReader($fs)
      $txt = $sr.ReadToEnd()
      $script:logOffset = $fs.Position
    } finally { $fs.Close() }
    @($txt -split "`r?`n" | Where-Object { $_ -match (' ' + [regex]::Escape($name) + ' \[') })
  }catch{ @() }
}
function Phase-Of($line){ $m=[regex]::Match($line, [regex]::Escape($Instance)+'\s+\[([A-Za-z]+)\]'); if($m.Success){ $m.Groups[1].Value } }
function Test-DiagnosticPlayerLine([string]$line){
  # Keep host startup/disk evidence, not unrelated app inventories or input/telemetry payloads.
  $line -match '\b(?:PLR|VMMGR|VBOX)\s+\S+\s+\[' -and
    $line -match '(?i)\]\s+[WE]:|integrity|Root\.vhd|Player state\s*:|VERR_|VBOX_E_|failed to start|crashed'
}

# ----------------------------- report environment -----------------------------
Section 'ENVIRONMENT'
Log "Install   : $(Redact $Install)   exists=$([bool](Test-Path $Install))"
Log "DataRoot  : $(Redact $DataRoot)"
Log "Conf      : $(Redact $Conf)   exists=$([bool](Test-Path $Conf))"
Log "Player.log: $(Redact $PlayerLog)   exists=$([bool](Test-Path $PlayerLog))"
Log "HD-Player : exists=$([bool](Test-Path $Player))"
Get-BsrPlayerDiagnostics $Player | ForEach-Object { Log $_ }
Report-HostDetails
foreach($disk in @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'Engine') -Filter Root.vhd -Recurse -File -EA SilentlyContinue)){
  try { Log "disk: $($disk.FullName); format=$(Get-BsrDiskFormat $disk.FullName); bytes=$($disk.Length); attributes=$($disk.Attributes)" } catch { Log "disk inspection: $($_.Exception.Message)" Yellow }
}
Log "HD-Adb    : exists=$([bool](Test-Path $AdbExe))   version=[$(Compact (Adb @('version')))]"
if(-not (Test-Path $Player) -or -not (Test-Path $AdbExe)){ Log '[!] HD-Player.exe or HD-Adb.exe not found -- cannot continue.' Red; return }

Section 'CONF PORTS'
Log "instances in conf : $($allInst -join ', ')"
Log "TARGET instance   : $Instance" Yellow
Log "status.adb_port   : $statusPort"
Log "adb_port          : $adbPort"
Log "Configured port   : $PrimaryPort (live listener ownership takes precedence)" Yellow

# ----------------------------- private adb server port -----------------------------
$serverBand = Get-BandListeners 15037 15057
$serverPort = $null
$used = @{}; foreach($b in $serverBand){ $used[[int]$b.Port] = $true }
foreach($p in 15037..15057){ if(-not $used.ContainsKey($p)){ $serverPort = "$p"; break } }
if(-not $serverPort){Log 'No free private ADB server port in 15037-15057; other ADB servers were left alone.' Red;return}
$oldAdbServerPort=$env:ANDROID_ADB_SERVER_PORT
$env:ANDROID_ADB_SERVER_PORT = $serverPort
Log "ADB server port   : $serverPort   (current 15037-15057 listeners: $(Fmt-Band $serverBand))"

# ----------------------------- clean cold start -----------------------------
try {
Section 'CLEAN START'
$script:launchedPid=$null
$targets=@(Get-ExactPlayers $Instance)
Log "restarting selected instance only: $Instance; matched PIDs=$($targets.Id -join ',')"
$targets | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 3
$base=$Instance -replace '_\d+$',''
$rootImage=Join-Path $DataRoot "Engine\$base\Root.vhd"
if(-not (Probe-RootDisk $rootImage)){Report-PolicyEvents;return}
Log "start-server -> $(Compact (Adb @('start-server')))"
Snapshot-Log

Section 'LAUNCH + WATCH'
Log "launch: HD-Player.exe --instance $Instance"
try{ $script:launchedPid=Start-BsrPlayer $Player $Instance }catch{
  Log-Failure 'HD-Player launch failed' $_
  Report-PolicyEvents
  Section 'VERDICT'
  Log 'HOST LAUNCH FAILED: Windows rejected HD-Player before Android/ADB started. No ADB reconnect loop is needed.' Red
  Log "Full log: $(Redact $LogFile)" Cyan
  return
}
$sw = [Diagnostics.Stopwatch]::StartNew()

# timing knobs (reasonable, but fail fast when it is clearly NOT just slow boot)
$HARD_CAP   = 480   # observation limit; individual ADB commands have an 8-second timeout
$NOPROGRESS = 120   # nothing alive at all by here -> bail
$POST_READY = 75    # booted but adb won't come online even after heal -> conclusive

$readyAt=$null; $firstOnlineAt=$null; $healWorkedAt=$null; $sawProc=$false; $lastPhase=$null; $diagSerial=$null
$identityLogged=$false; $nextHeal=20; $done=$false; $verdict='(inconclusive)'
$recentPlayerLines=New-Object System.Collections.Generic.Queue[string]

while(-not $done){
  $el = [int]$sw.Elapsed.TotalSeconds
  if($el -ge $HARD_CAP){ $verdict = "TIMEOUT: no success within $HARD_CAP s"; break }
  Start-Sleep 2
  try {
    $pp = Probe-Player $Instance
    if($pp.exact -gt 0){ $sawProc = $true }

    foreach($l in (Read-NewLog $Instance)){
      if(Test-DiagnosticPlayerLine $l){$recentPlayerLines.Enqueue($l);while($recentPlayerLines.Count -gt 40){$null=$recentPlayerLines.Dequeue()}}
      $ph = Phase-Of $l; if($ph){ $lastPhase = $ph }
      if(-not $readyAt -and ($l -match '\[Ready\]' -or $l -match 'HomeActivity' -or $l -match 'Player state:.*->\s*Player state:\s*Ready')){
        $readyAt = $el; Log "*** Player.log: instance reached [Ready] (fully booted) at elapsed=${el}s ***" Green
      }
    }

    $bl   = Get-BandListeners 5550 5900
    $port=@(Get-BsrDiagnosticTargetPort $bl $pp.ids $PrimaryPort)
    if(-not $port.Count){
      Log "t=${el}s exactPlayers=$($pp.exact); phase=$lastPhase; no listener owned by the target; band=[$(Fmt-Band $bl)]"
      if($sawProc -and -not $pp.exact){$verdict='PLAYER EXITED: selected instance crashed or was closed';break}
      if($el -ge $NOPROGRESS){$verdict='NO TARGET LISTENER: selected instance did not expose ADB';break}
      continue
    }
    $cand = "127.0.0.1:$($port[0])"
    $conn = Adb @('connect',$cand)
    $state= State $cand
    $bc   = if($state -eq 'device'){ Adb @('-s',$cand,'shell','getprop','sys.boot_completed') } else { '' }

    Log ("t=${el}s proc[total=$($pp.proc) exact=$($pp.exact) wmi_match=$($pp.wmi_match)] phase=$lastPhase target=$cand band=[$(Fmt-Band $bl)] connect=[$(Compact $conn 80)] state=[$state] boot=[$(Compact $bc 20)]")

    if($pp.exact -gt 0 -and $pp.wmi_match -eq 0){
      Log '   WMI hides the instance command line; target identified by launch PID / Player.log.' DarkGray
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
    if($sawProc -and $pp.exact -eq 0){
      $verdict = "FAIL-FAST: HD-Player disappeared at ${el}s -- instance crashed or was closed"; break
    }
    # conclusive: booted but adb won't come online even with heal
    if($readyAt -and ($el - $readyAt) -ge $POST_READY -and -not $firstOnlineAt -and -not $healWorkedAt){
      $verdict = "CONCLUSIVE: instance booted (Player.log [Ready] at ${readyAt}s) but $cand stayed offline AND disconnect+connect did not recover it after +${POST_READY}s"; break
    }
  } catch {
    Log-Failure 'Boot observation iteration' $_
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
  Log "guest Magisk root     : $(Compact (Adb @('-s',$diagSerial,'shell','su -c id; readlink /system/bin/su; su -c "magisk -c"')) 500)"
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

Section 'TARGET PLAYER.LOG STARTUP/DISK EVIDENCE (up to 40 lines)'
foreach($line in $recentPlayerLines){Log (Compact $line 1200)}
Report-PolicyEvents
Section 'VERDICT'
Log $verdict $(if($verdict -match '^SUCCESS'){'Green'}else{'Red'})
Log ("timeline: PlayerLog[Ready]=$readyAt s | firstAdbOnline=$firstOnlineAt s | healWorked=$healWorkedAt s | sawProcess=$sawProc | primaryPort=$PrimaryPort")
Log ''
Log '------------------------------------------------------------------'
Log "Full log: $(Redact $LogFile)" Cyan
Log 'Attach that .log file to the GitHub issue. (Instance left running for inspection.)' Cyan
} finally {
  Adb @('kill-server') | Out-Null
  $env:ANDROID_ADB_SERVER_PORT=$oldAdbServerPort
}

<#
__BSR_HOST_BEGIN__
# Shared Windows disk and process helpers. Embedded in both single-file launchers.
# This file only defines functions; loading it never changes the host.

function Get-BsrDiskFormat([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt 512) { return 'Truncated' }
        $head = New-Object byte[] 512
        if ($stream.Read($head, 0, 512) -ne 512) { throw "Short read of disk header: $Path" }
        if ([Text.Encoding]::ASCII.GetString($head, 0, 8) -ceq 'vhdxfile') { return 'VHDX' }
        if ([BitConverter]::ToUInt32($head, 64) -eq 0xbeda107fL) { return 'VDI' }
        $stream.Position = $stream.Length - 512
        $footer = New-Object byte[] 512
        if ($stream.Read($footer, 0, 512) -ne 512) { throw "Short read of disk footer: $Path" }
        if ([Text.Encoding]::ASCII.GetString($footer, 0, 8) -ceq 'conectix') { return 'VHD' }
        return 'Unknown'
    } finally { $stream.Dispose() }
}

function Get-BsrNativeError($Failure) {
    $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
    while ($exception) {
        if ($exception -is [ComponentModel.Win32Exception]) { return $exception.NativeErrorCode }
        $exception = $exception.InnerException
    }
    return $null
}

function Copy-BsrDiskRegion([string]$Device, [long]$Start, [long]$Length, [string]$Destination) {
    if($Start -lt 0 -or $Length -le 0 -or ($Start % 512) -or ($Length % 512)){throw 'Disk region must have a positive, sector-aligned size and offset.'}
    $inputStream=[IO.File]::Open($Device,'Open','Read','ReadWrite')
    try {
        $inputStream.Position=$Start
        $outputStream=[IO.File]::Open($Destination,'Create','Write','None')
        try {
            $buffer=New-Object byte[] (16MB)
            $remaining=$Length
            while($remaining -gt 0){
                $count=$inputStream.Read($buffer,0,[int][Math]::Min([long]$buffer.Length,[long]$remaining))
                if($count -le 0){throw "Short disk read: $remaining of $Length bytes missing. Refusing to edit or write back an incomplete image."}
                $outputStream.Write($buffer,0,$count)
                $remaining-=$count
            }
        } finally {$outputStream.Dispose()}
    } finally {$inputStream.Dispose()}
}

function Write-BsrDiskRegion([string]$Source, [string]$Device, [long]$Start, [long]$ExpectedLength=0) {
    $inputStream=[IO.File]::OpenRead($Source)
    try {
        # Reject a damaged/expanded staging image BEFORE opening the destination
        # for writing. Never pad its tail with stale bytes from a previous read.
        if($Start -lt 0 -or ($Start % 512) -or $inputStream.Length -le 0 -or ($inputStream.Length % 512)) {throw 'Staging image and destination offset must be sector-aligned.'}
        if($ExpectedLength -gt 0 -and $inputStream.Length -ne $ExpectedLength) {throw "Staging image size changed: expected $ExpectedLength bytes, got $($inputStream.Length). No write started."}
        $outputStream=[IO.File]::Open($Device,'Open','ReadWrite','ReadWrite')
        try {
            $outputStream.Position=$Start
            $buffer=New-Object byte[] (16MB)
            $remaining=$inputStream.Length
            while($remaining -gt 0){
                $want=[int][Math]::Min([long]$buffer.Length,[long]$remaining)
                $filled=0
                while($filled -lt $want){
                    $count=$inputStream.Read($buffer,$filled,$want-$filled)
                    if($count -le 0){throw 'Staging image ended during writeback.'}
                    $filled+=$count
                }
                $outputStream.Write($buffer,0,$filled)
                $remaining-=$filled
            }
            $outputStream.Flush()
        } finally {$outputStream.Dispose()}
    } finally {$inputStream.Dispose()}
}

function Mount-BsrDisk([string]$Path, [switch]$ReadOnly) {
    $Path = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    $format = Get-BsrDiskFormat $Path
    if ($format -notin @('VHD', 'VHDX')) {
        throw "Cannot mount '$Path': detected $format disk content. Expected a complete VHD or VHDX image. Repair/recreate this BlueStacks Android image; renaming the file does not convert it."
    }
    $existing = Get-DiskImage -ImagePath $Path -StorageType $format -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) {
        throw "Disk is already attached: '$Path'. Close the instance and detach this image in Disk Management before retrying."
    }
    try {
        # Root.vhd can contain VHDX; backup/test copies also have arbitrary extensions.
        # Never ask the Windows provider to guess from the filename.
        $access = if ($ReadOnly) { 'ReadOnly' } else { 'ReadWrite' }
        Mount-DiskImage -ImagePath $Path -StorageType $format -Access $access -NoDriveLetter -PassThru -ErrorAction Stop
    } catch {
        $detail = $_.Exception.Message.Trim()
        $code = $_.FullyQualifiedErrorId
        throw "Windows could not attach '$Path' as $format ($code): $detail Check that BlueStacks is closed and the image is on an uncompressed, unencrypted local volume. If the virtual disk provider is missing, repair Windows Virtual Disk/Storage components. No disk edits were started."
    }
}

function Get-BsrPlayerDiagnostics([string]$Player) {
    try {
        # A .cmd launched from PowerShell 7 can pass its incompatible module path
        # into Windows PowerShell 5.1. Load the security module for THIS host.
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
    } catch { "Host security module: $($_.Exception.Message)" }
    try {
        $file = Get-Item -LiteralPath $Player -ErrorAction Stop
        "HD-Player version=$($file.VersionInfo.FileVersion); attributes=$($file.Attributes); bytes=$($file.Length)"
        $signature = Get-AuthenticodeSignature -LiteralPath $Player -ErrorAction Stop
        "HD-Player signature=$($signature.Status) (a byte-patched executable normally reports HashMismatch)"
    } catch { "HD-Player file/signature inspection: $($_.Exception.Message)" }
    try { "HD-Player ACL: $((Get-Acl -LiteralPath $Player -ErrorAction Stop).Sddl)" } catch { "HD-Player ACL: $($_.Exception.Message)" }
    foreach($log in @('Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-AppLocker/EXE and DLL')){
        try {
            $events=@(Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=(Get-Date).AddMinutes(-10)} -MaxEvents 100 -ErrorAction Stop |
                Where-Object {$_.Message -match 'HD-Player\.exe'} | Select-Object -First 3)
            foreach($event in $events){"$log event $($event.Id) at $($event.TimeCreated.ToString('s')): $($event.Message)"}
        } catch { } # Missing/disabled logs are not evidence of a policy block.
    }
}

function Start-BsrPlayer([string]$Player, [string]$Instance) {
    if ($Instance -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid BlueStacks instance identifier: $Instance" }
    $Player = (Get-Item -LiteralPath $Player -ErrorAction Stop).FullName
    try {
        if (-not ('Bsr.HostLauncher' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Bsr {
    public static class HostLauncher {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        struct StartupInfo {
            public int cb; public string reserved, desktop, title;
            public int x,y,xSize,ySize,xChars,yChars,fill,flags;
            public short show, reservedSize;
            public IntPtr reservedPtr, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr process, thread; public int processId, threadId; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern bool CreateProcessW(string app, StringBuilder command,
            IntPtr processAttrs, IntPtr threadAttrs, bool inheritHandles, uint flags,
            IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo info);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static int Start(string player, string instance, string directory) {
            var startup=new StartupInfo(); startup.cb=Marshal.SizeOf(startup);
            startup.flags=1; startup.show=0; // STARTF_USESHOWWINDOW / SW_HIDE
            ProcessInfo info;
            var command=new StringBuilder("\""+player+"\" --instance \""+instance+"\"");
            // No inherited stdout/stderr handles: a GUI process must not keep
            // its parent PowerShell pipeline alive after the rooter has exited.
            if(!CreateProcessW(player,command,IntPtr.Zero,IntPtr.Zero,false,0x08000000,
                IntPtr.Zero,directory,ref startup,out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(info.thread); CloseHandle(info.process);
            return info.processId;
        }
    }
}
'@ -ErrorAction Stop
        }
        # Use the already-elevated token and Windows' normal process access checks.
        return [Bsr.HostLauncher]::Start($Player,$Instance,(Split-Path -Parent $Player))
    } catch {
        $native = Get-BsrNativeError $_
        $reason = $_.Exception.GetBaseException().Message
        $diagnostics = (Get-BsrPlayerDiagnostics $Player) -join [Environment]::NewLine
        throw "Windows could not start HD-Player for '$Instance' (Win32=$native): $reason`n$diagnostics`nThis is a host launch failure, before Android or ADB. Check this executable's permissions and Windows CodeIntegrity/AppLocker events; a Defender exclusion does not resolve every launch denial."
    }
}
__BSR_HOST_END__
#>
