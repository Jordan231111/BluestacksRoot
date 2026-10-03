# Build and standalone-launch tests. Fixtures never modify an installed emulator.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_distribution_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Host "[PASS] $name"}else{$script:fail++;Write-Host "[FAIL] $name"}}
function Run-Ps([string[]]$Arguments){Invoke-BsrNative 'powershell.exe' (@('-NoProfile','-ExecutionPolicy','Bypass','-File')+$Arguments) 90}
try{
    $folder=Join-Path $work ("release [1] & O'Brien ! "+[char]0xe9)
    [void][IO.Directory]::CreateDirectory($folder)
    $cmdFile=Join-Path $folder 'blueStackRoot.cmd';$debugFile=Join-Path $folder 'debug.cmd'
    [IO.File]::Copy((Join-Path $repo 'blueStackRoot.cmd'),$cmdFile)
    [IO.File]::Copy((Join-Path $repo 'debug.cmd'),$debugFile)
    $before=Get-BsrFileHash $cmdFile
    $build=Run-Ps @((Join-Path $repo 'tools\reembed.ps1'),'-Cmd',$cmdFile,'-Diagnostic',$debugFile)
    Check ($build.ExitCode -eq 0 -and (Get-BsrFileHash $cmdFile) -ceq $before) "source rebuild is byte-identical ($($build.Output))"
    $badSource=Join-Path $work 'invalid.ps1';[IO.File]::WriteAllText($badSource,'function {')
    $bad=Run-Ps @((Join-Path $repo 'tools\reembed.ps1'),'-Cmd',$cmdFile,'-Diagnostic',$debugFile,'-Magisk',$badSource)
    Check ($bad.ExitCode -ne 0 -and (Get-BsrFileHash $cmdFile) -ceq $before) 'invalid source leaves the existing distribution intact'
    $fixture=[Text.Encoding]::ASCII.GetBytes("header __BSR_TEST_BEGIN__ is not a marker`n__BSR_TEST_BEGIN__`nold`n__BSR_TEST_END__`ntail")
    $spliced=Set-BsrEmbeddedBlock $fixture 'TEST' ([Text.Encoding]::ASCII.GetBytes("new`n"))
    Check ((Get-BsrEmbeddedText $spliced 'TEST') -ceq "new`n" -and [Text.Encoding]::ASCII.GetString($spliced).EndsWith('tail')) 'splicer uses complete marker lines and preserves surrounding bytes'
    $duplicate=[Text.Encoding]::ASCII.GetBytes("__BSR_TEST_BEGIN__`na`n__BSR_TEST_BEGIN__`nb`n__BSR_TEST_END__`n")
    $reason='';try{Get-BsrBlockBounds $duplicate 'TEST'|Out-Null}catch{$reason=$_.Exception.Message}
    Check ($reason -match 'Duplicate') 'duplicate marker blocks are rejected'
    $apk=Join-Path $repo 'Working Example & Fix\MagiskMyStableBuild.apk'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $rebuilt=Run-Ps @((Join-Path $repo 'tools\reembed-apk.ps1'),'-Cmd',$cmdFile,'-Apk',$apk)
    Check ($rebuilt.ExitCode -eq 0 -and (Get-BsrFileHash $cmdFile) -ceq $before) "APK rebuild preserves every byte ($([Math]::Round($timer.Elapsed.TotalSeconds,2))s)"
    $bad=Run-Ps @((Join-Path $repo 'tools\reembed-apk.ps1'),'-Cmd',$cmdFile,'-Apk',$apk,'-Wrap','0')
    Check ($bad.ExitCode -ne 0 -and (Get-BsrFileHash $cmdFile) -ceq $before) 'zero wrap width fails promptly without changing the build'

    # The batch entry point needs elevation by design. Non-elevated CI still
    # exercises its exact embedded launcher in-process without invoking UAC.
    $originalSelf=$env:BSR_SELF
    try{
        $env:BSR_SELF=$cmdFile
        . ([scriptblock]::Create((Get-BsrEmbeddedText ([IO.File]::ReadAllBytes($cmdFile)) 'LAUNCHER')))
        Initialize-LauncherScripts
        Check ((Test-Path -LiteralPath $script:enginePath) -and (Test-Path -LiteralPath $script:magiskPath)) 'standalone launcher extracts both scripts without a tools directory'
        $layout=Join-Path $folder 'Data [custom]'
        $fakeInstall=Join-Path $folder 'Install [custom]'
        [void][IO.Directory]::CreateDirectory((Join-Path $layout 'Engine\Pie64'))
        [void][IO.Directory]::CreateDirectory($fakeInstall)
        [IO.File]::WriteAllText((Join-Path $layout 'bluestacks.conf'),'bst.instance.Pie64.adb_port="5599"')
        [IO.File]::WriteAllText((Join-Path $layout 'Engine\Pie64\Pie64.bstk'),'<HardDisk location="Root.vhd"/>')
        [IO.File]::WriteAllText((Join-Path $layout 'Engine\Pie64\Root.vhd'),'fixture')
        foreach($name in @('HD-Player.exe','HD-Adb.exe')){[IO.File]::WriteAllText((Join-Path $fakeInstall $name),'fixture')}
        $script:customPath=$layout;$script:installDir=$fakeInstall;$script:dataDir=$layout
        $paths=Resolve-LauncherPaths 'Pie64'
        Check ($paths.BSR_DATADIR -ceq $layout -and $paths.BSR_INSTALL -ceq $fakeInstall -and $paths.BSR_INSTANCE -ceq 'Pie64') 'custom paths containing spaces, brackets, apostrophes, ampersands, ! and Unicode round-trip through the extracted engine'
        & {
            $script:added=New-Object System.Collections.Generic.List[string]
            function Get-MpPreference {[pscustomobject]@{ExclusionPath=@($homeDir)}}
            function Add-MpPreference([string]$ExclusionPath){$script:added.Add($ExclusionPath)}
            Add-LauncherExclusions $layout
            Add-LauncherExclusions $layout
            Check ($added.Count -eq 2 -and $added -notcontains $homeDir -and $addedExclusions -notcontains $homeDir) 'existing Defender exclusions are preserved and new entries are tracked once'
        }
    }finally{
        $env:BSR_SELF=$originalSelf
        if($script:scriptsDir){
            $resolved=[IO.Path]::GetFullPath($script:scriptsDir)
            $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
            if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^bsr_launcher_[a-f0-9]{32}$'){
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }
    $isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if($isAdmin){
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$env:ComSpec;$info.Arguments='/d /v:off /c ""'+$cmdFile+'""'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info)
        try{
            $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine('0');$process.StandardInput.Close()
            if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Standalone menu did not exit.'}
            $menu=$out.GetAwaiter().GetResult();$errors=$err.GetAwaiter().GetResult()
            Check ($process.ExitCode -eq 0 -and $menu -match 'Android 13' -and -not $errors) "standalone .cmd menu opens and exits from a special-character path ($errors)"
        }finally{$process.Dispose()}
    }else{Write-Host '[SKIP] elevated batch bootstrap (embedded launcher was exercised without UAC)'}
}catch{$fail++;Write-Host "[FAIL] $_";Write-Host $_.ScriptStackTrace}
finally{
    $resolved=[IO.Path]::GetFullPath($work)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^bsr_distribution_[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
