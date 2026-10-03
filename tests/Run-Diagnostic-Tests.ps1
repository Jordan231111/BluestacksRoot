# Tests the functions shipped in debug.cmd without executing its live workflow.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_host.ps1')
$text=[IO.File]::ReadAllText((Join-Path $repo 'debug.cmd'))
$body=$text.Substring($text.IndexOf('#__BSR'+'_DEBUG_PS__'))
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw ($parseErrors.Message -join '; ')}
foreach($name in @('Redact','Compact','Log-Failure','Quote-NativeArgument','Adb','State','Probe-RootDisk','Test-CmdLine','Get-ExactPlayers','Get-BsrDiagnosticTargetPort','Get-DiagnosticHash','Test-DiagnosticPlayerLine')){
  $function=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0]
  if(-not $function){throw "Missing diagnostic function: $name"}
  . ([scriptblock]::Create($function.Extent.Text))
}
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Host "[PASS] $name"}else{$script:fail++;Write-Host "[FAIL] $name"}}
$script:lines=New-Object System.Collections.Generic.List[string]
function Log($message,$color){$script:lines.Add((Redact $message))}
function Section($name){Log $name}
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_diag_test_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$originalProfile=$env:USERPROFILE
try {
  $env:USERPROFILE='D:\Profiles\Jane Example'
  foreach($sample in @('C:\Users\Jordan\Downloads\Root.vhd',('c:/users/Zo'+[char]0xeb+' Example/AppData/test'),'C:\\Users\\PERSON~1\\AppData\\test','D:\Profiles\Jane Example\Downloads\file.cmd','d:/profiles/jane example/AppData/file.cmd','C:\Documents and Settings\Jane Example\Temp\a')){
    $redacted=Redact $sample
    Check ($redacted -notmatch 'Jordan|Zo.+Example|PERSON~1|Jane Example' -and $redacted -match 'xxxxx') "mask profile component: $sample"
  }
  $evidence='D:\Games\BlueStacks\Root.vhd Win32=5 HRESULT=0xC03A0014 S-1-5-32-544 127.0.0.1:5556 HD-Player.exe'
  Check ((Redact $evidence) -ceq $evidence) 'preserve technical paths, codes, SID, endpoint and executable'
  Check ((Redact 'D:\Profiles\Jane Examples\different') -eq 'D:\Profiles\Jane Examples\different') 'profile matching respects directory boundary'
  Check ((Compact 'D:\Profiles\Jane Example\Downloads\long-file-name.cmd' 27) -notmatch 'Jane') 'redact before truncating output'
  $env:USERPROFILE=$originalProfile

  $hashFile=Join-Path $work 'hash.txt'
  [IO.File]::WriteAllText($hashFile,'abc',(New-Object Text.UTF8Encoding($false)))
  Check ((Get-DiagnosticHash $hashFile) -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') 'file hashing works without PowerShell module auto-loading'

  try {throw (New-Object ComponentModel.Win32Exception(5,'Denied C:\Users\Secret Person\HD-Player.exe'))} catch {Log-Failure 'launch' $_}
  $errorText=$script:lines -join "`n"
  Check ($errorText -match 'Win32=5' -and $errorText -match 'HRESULT=0x' -and $errorText -notmatch 'Secret Person') 'error report preserves native codes and masks profile names'
  $script:lines.Clear()
  try {throw (New-Object IO.IOException('provider missing',[Convert]::ToInt32('C03A0014',16)))} catch {Log-Failure 'mount' $_}
  Check (($script:lines -join "`n") -match 'HRESULT=0xC03A0014') 'retain virtual disk provider HRESULT exactly'

  $listeners=@([pscustomobject]@{Port=5555;PID=10},[pscustomobject]@{Port=5556;PID=20})
  Import-Module Storage -ErrorAction Stop
  Check ((Get-BsrDiagnosticTargetPort $listeners @(20) 5555) -eq 5556) 'stale configured port cannot select a different instance (Storage module loaded)'
  Check (@(Get-BsrDiagnosticTargetPort $listeners @(30) 5555).Count -eq 0) 'no target listener never falls back to another device'
  Check (Test-DiagnosticPlayerLine 'PLR Rvc64 [Ready] E: Failed to verify Root.vhd: VERR_ACCESS_DENIED') 'keep original player disk errors'
  Check (-not (Test-DiagnosticPlayerLine 'HCALL Rvc64 [Ready] I: hcallSyncInstalledAppsClbk jsonData=private inventory')) 'exclude unrelated installed-app inventories'
  Check (-not (Test-DiagnosticPlayerLine 'PLR Rvc64 [Ready] I: plrOnCommonCommandHcall name: input data: private text')) 'exclude unrelated input/telemetry payloads'

  & {
    function Get-CimInstance { @() }
    $PlayerLog=Join-Path $work 'Player.log';[IO.File]::WriteAllText($PlayerLog,'fixture')
    $script:launchedPid=$null
    $script:fakeStart=(Get-Date)
    function Get-Content { '2020-01-01 10:00:00.000-0400 123 456 PLR Rvc64 [Ready] stale' }
    function Get-Process { [pscustomobject]@{Id=123;Name='HD-Player';StartTime=$script:fakeStart} }
    Check (@(Get-ExactPlayers Rvc64).Count -eq 0) 'stale Player.log PID cannot restart a newer process'
    $script:fakeStart=[datetime]'2019-12-31'
    Check (@(Get-ExactPlayers Rvc64).Count -eq 1) 'valid Player.log fallback works when WMI hides command line'
  }

  $disk=Join-Path $work 'Root.vhd'
  $bytes=New-Object byte[] 1024
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes('conectix'),0,$bytes,512,8)
  [IO.File]::WriteAllBytes($disk,$bytes)
  & {
    $script:mounted=0;$script:detached=0;$script:attachFails=$false;$script:inspectFails=$false;$script:detachFails=$false;$script:alreadyAttached=$false;$script:running=$false
    function Get-Process {if($script:running){[pscustomobject]@{Id=1;Name='HD-Player'}}}
    function Get-DiskImage { [pscustomobject]@{Attached=$script:alreadyAttached} }
    function Mount-DiskImage([string]$ImagePath,[string]$StorageType,[string]$Access,[switch]$NoDriveLetter,[switch]$PassThru){
      $script:mounted++
      if($script:attachFails){throw (New-Object ComponentModel.Win32Exception(5))}
      if($StorageType -ne 'VHD' -or $Access -ne 'ReadOnly' -or -not $NoDriveLetter){throw 'unsafe mount options'}
      [pscustomobject]@{ImagePath=$ImagePath;Attached=$true}
    }
    function Get-Disk {if($script:inspectFails){throw 'inspection failure'};[pscustomobject]@{Number=99;Size=1024;PartitionStyle='MBR';IsReadOnly=$true}}
    function Get-Partition { @() }
    function Dismount-DiskImage { $script:detached++;if($script:detachFails){throw 'detach failure'} }
    Check ((Probe-RootDisk $disk) -and $script:mounted -eq 1 -and $script:detached -eq 1) 'probe attaches read-only with explicit format and detaches'
    $script:inspectFails=$true
    Check ((Probe-RootDisk $disk) -and $script:detached -eq 2) 'inspection failure still releases our attachment'
    $script:inspectFails=$false;$script:detachFails=$true
    Check (-not (Probe-RootDisk $disk)) 'detach failure blocks subsequent player launch'
    $script:detachFails=$false;$script:alreadyAttached=$true;$before=$script:detached
    Check ((Probe-RootDisk $disk) -and $script:detached -eq $before) 'existing attachment is never detached'
    $script:alreadyAttached=$false;$script:running=$true;$before=$script:mounted
    Check ((Probe-RootDisk $disk) -and $script:mounted -eq $before) 'another running player prevents shared-master mount probe'
    $script:running=$false;$script:attachFails=$true;$before=$script:detached
    Check ((Probe-RootDisk $disk) -and $script:detached -eq $before) 'failed attach collects evidence without detaching another image'
  }

  $AdbExe=Join-Path $work 'probe.exe'
  Add-Type -TypeDefinition 'using System; class DiagProbe { static void Main(string[] a) { if(a.Length>0 && a[0]=="hang") {System.Threading.Thread.Sleep(20000);return;} Console.WriteLine(String.Join("|",a)); Console.Error.WriteLine("stderr detail"); } }' -OutputAssembly $AdbExe -OutputType ConsoleApplication
  $argsToEcho=@('space argument','literal"quote','C:\Users\Jane Example\folder\')
  $output=Adb $argsToEcho
  Check ($output.Contains(($argsToEcho -join '|')) -and $output.Contains('stderr detail')) 'native argument quoting and stderr capture round-trip'
  $sw=[Diagnostics.Stopwatch]::StartNew();$output=Adb @('hang')
  Check ($output -match 'timed out' -and $sw.Elapsed.TotalSeconds -lt 12) 'hung ADB process is terminated within the command timeout'
  & {
    function Adb { "device`r`nstderr noise" }
    Check ((State '127.0.0.1:5555') -eq 'device') 'ADB state parser ignores stderr noise'
  }
} catch {$fail++;Write-Host $_;Write-Host $_.ScriptStackTrace}
finally{
  $env:USERPROFILE=$originalProfile
  $resolved=[IO.Path]::GetFullPath($work)
  $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'bsr_diag_test_*'){throw 'Unsafe diagnostic test cleanup path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force -EA SilentlyContinue
}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
