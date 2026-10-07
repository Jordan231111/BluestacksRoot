# Execute the real batch entry point with zero arguments. Only external host,
# player and disk operations are fixtures; file/payload checks and orchestration
# remain real. UAC is bypassed in the disposable copy so CI never prompts.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
. (Join-Path $PSScriptRoot 'Test-Support.ps1')
$work=Join-Path $env:TEMP ('bsr_default_diag_test_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Host "[PASS] $name"}else{$script:fail++;Write-Host "[FAIL] $name"}}
function Run-DefaultBatch([string]$Path){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$env:ComSpec;$info.Arguments='/d /v:off /c ""'+$Path+'""'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.EnvironmentVariables['TEMP']=Join-Path $work 'temp'
    $info.EnvironmentVariables['TMP']=$info.EnvironmentVariables['TEMP']
    $process=[Diagnostics.Process]::Start($info)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(90000)){$process.Kill();throw 'Default diagnostic did not finish.'}
        [pscustomobject]@{ExitCode=$process.ExitCode;Output=($stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult())}
    }finally{$process.Dispose()}
}
try{
    $folder=Join-Path $work "Double click [1] & O'Brien !"
    $data=Join-Path $folder 'Data';$install=Join-Path $folder 'Install'
    foreach($path in @($folder,$install,(Join-Path $data 'Engine\Pie64'),(Join-Path $data 'Engine\Pie64_3'),(Join-Path $data 'Logs'),(Join-Path $work 'temp'))){[void][IO.Directory]::CreateDirectory($path)}
    foreach($name in @('HD-Player.exe','HD-Adb.exe')){[IO.File]::WriteAllText((Join-Path $install $name),'fixture - never executed')}
    [IO.File]::WriteAllText((Join-Path $data 'bluestacks.conf'),"bst.instance.Pie64.adb_port=`"5597`"`r`nbst.instance.Pie64_3.adb_port=`"5599`"")
    [IO.File]::WriteAllBytes((Join-Path $data 'Engine\Pie64\Root.vhd'),[byte[]](0,1,2,3))
    [IO.Directory]::SetLastWriteTime((Join-Path $data 'Engine\Pie64'),[datetime]'2020-01-01')
    [IO.Directory]::SetLastWriteTime((Join-Path $data 'Engine\Pie64_3'),[datetime]'2020-01-02')
    $rooter=Join-Path $folder 'blueStackRoot.cmd'
    $rooterBytes=[IO.File]::ReadAllBytes((Join-Path $repo 'blueStackRoot.cmd'))
    [IO.File]::WriteAllBytes($rooter,$rooterBytes)

    $debugBytes=[IO.File]::ReadAllBytes((Join-Path $repo 'debug.cmd'))
    $hostFixture=@'
function Get-RegBlueStacksRecords { [pscustomobject]@{InstallDir=(Join-Path $env:BSR_DEBUG_HOME 'Install');DataDir=(Join-Path $env:BSR_DEBUG_HOME 'Data')} }
function Get-RuntimeInstallRoots { throw 'Fixture discovery must not inspect the real host.' }
function Get-BsrPlayerDiagnostics { 'Fixture player metadata inspected.' }
function Start-BsrPlayer { $script:FixtureStarted=$true; 4242 }
function Get-Process { [pscustomobject]@{Id=4242;Name='HD-Player';StartTime=([datetime]'2020-01-01')} }
function Stop-Process {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Force)
    process { if($InputObject){throw 'This fixture must never stop a real process.'} }
}
function Get-CimInstance { @() }
function Get-BsrTcpListeners { if($script:FixtureStarted){[pscustomobject]@{LocalPort=5599;OwningProcess=4242}} }
function Stop-BsrAdbServer { Log 'Fixture private ADB server cleaned up.' }
function Start-Sleep { }
'@
    $hostSource=(Get-BsrEmbeddedText $debugBytes 'HOST')+"`r`n"+$hostFixture+"`r`n"
    $debugBytes=Set-BsrEmbeddedBlock $debugBytes 'HOST' ([Text.Encoding]::UTF8.GetBytes($hostSource))
    $debugText=[Text.Encoding]::UTF8.GetString($debugBytes)
    $body=$debugText.Substring($debugText.IndexOf('#__BSR'+'_DEBUG_PS__'))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
    if($errors){throw ($errors.Message -join '; ')}
    $fixtures=@{
        'New-DiagnosticLog'=@'
function New-DiagnosticLog {
    $directory=Join-Path $env:BSR_DEBUG_HOME 'logs';[void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory ($PID.ToString()+'.log');[IO.File]::WriteAllText($path,'');$path
}
'@
        'Report-HostDetails'="function Report-HostDetails { Section 'WINDOWS CONTEXT'; Log 'Fixture Windows context collected.' }"
        'Report-PolicyEvents'="function Report-PolicyEvents { Section 'RELATED WINDOWS EVENTS'; Log 'Fixture policy events collected.' }"
        'Probe-RootDisk'=@'
function Probe-RootDisk($path) {
    Section 'READ-ONLY DISK PROBE'
    if(-not [IO.File]::Exists($path)){throw 'Wrong fixture disk selected.'}
    Set-DiagnosticCheck 'Disk attach' 'PASS' 'Fixture read-only disk inspection completed.'
    $true
}
'@
        'Get-ExactPlayers'='function Get-ExactPlayers { @() }'
        'Probe-Player'='function Probe-Player { @{proc=1;exact=1;ids=@(4242);wmi_total=1;wmi_match=1;cmds=@()} }'
        Adb=@'
function Adb([string[]]$a) {
    Log ('Fixture ADB command: '+($a -join ' '))
    if($a -contains 'get-state'){'device'}
    elseif($a -contains 'sys.boot_completed'){'1'}
    else{'fixture reply'}
}
'@
    }
    foreach($name in $fixtures.Keys){
        $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        if($nodes.Count -ne 1){throw "Cannot isolate default diagnostic fixture: $name"}
        $debugText=$debugText.Replace($nodes[0].Extent.Text,$fixtures[$name])
    }
    $adminCheck='$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator);'
    if(-not $debugText.Contains($adminCheck)){throw 'Cannot isolate batch elevation check.'}
    $debugText=$debugText.Replace($adminCheck,'$admin=$true;')
    $debugText=($debugText -replace "`r?`n","`r`n")
    $debugFile=Join-Path $folder 'debug.cmd'
    [IO.File]::WriteAllText($debugFile,$debugText,(New-Object Text.UTF8Encoding($false)))

    $result=Run-DefaultBatch $debugFile
    if($result.ExitCode){Write-Host $result.Output}
    Check ($result.ExitCode -eq 0 -and $result.Output -match 'No command-line options are needed') 'double-click entry point completes with zero diagnostic arguments'
    Check ($result.Output -match 'Diagnostic file : PASS' -and $result.Output -match 'Temporary directory : PASS' -and $result.Output -match 'Rooter payloads : PASS' -and $result.Output -match 'PASS Ensure-Debugfs') 'default run finds the adjacent rooter and executes real file/temp/payload checks'
    Check ($result.Output -match 'TARGET instance\s+: Pie64_3' -and $result.Output -match 'HD-Player.exe --instance Pie64_3') 'default run selects an instance automatically without asking for an internal name'
    Check ($result.Output -match 'WINDOWS CONTEXT' -and $result.Output -match 'RELATED WINDOWS EVENTS' -and $result.Output -match 'Disk attach : PASS' -and $result.Output -match 'Guest evidence : PASS' -and $result.Output -match 'ADB readiness : PASS') 'default workflow includes Windows, disk and guest/ADB evidence in the same run'
    $logs=@(Get-ChildItem -LiteralPath (Join-Path $folder 'logs') -Filter '*.log')
    $saved=if($logs.Count -eq 1){[IO.File]::ReadAllText($logs[0].FullName)}else{''}
    Check ($saved -match 'Rooter payloads : PASS' -and $saved -match 'ADB readiness : PASS' -and $saved -match 'DIAGNOSTIC SUMMARY') 'one saved report includes file and runtime results with a final summary'

    $broken=Set-BsrEmbeddedBlock $rooterBytes 'BSRSU' ([Text.Encoding]::ASCII.GetBytes("not-base64`r`n"))
    [IO.File]::WriteAllBytes($rooter,$broken)
    $result=Run-DefaultBatch $debugFile
    Check ($result.ExitCode -ne 0 -and $result.Output -match 'Rooter payloads : FAIL' -and $result.Output -match 'Disk attach : PASS' -and $result.Output -match 'ADB readiness : PASS' -and $result.Output -match 'DIAGNOSTIC SUMMARY') 'payload failure retains its error and still collects the complete runtime report'
    Check ($result.Output -match 'double-click' -and $result.Output -notmatch '--files-only') 'payload errors direct users to double-click without prescribing command-line options'
}catch{$fail++;Write-Host "[FAIL] $_";Write-Host $_.ScriptStackTrace}
finally{Remove-BsrTestDirectory $work}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
