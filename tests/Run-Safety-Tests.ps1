# Regression fixtures only: never boots or modifies an installed BlueStacks instance.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_magisk.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_safety_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$script:WorkDir=Join-Path $work 'session'
$pass=0; $fail=0
function Check($condition,$message){
    if($condition){$script:pass++;Write-Host "[PASS] $message"}
    else{$script:fail++;Write-Host "[FAIL] $message"}
}
function Reject([scriptblock]$action,$pattern,$message){
    $reason='';try{& $action | Out-Null}catch{$reason=$_.Exception.Message}
    Check ($reason -match $pattern) "$message ($reason)"
}
try {
    $confFile=Join-Path $work ('conf [test] & O''Brien ! '+[char]0xe9+'.txt')
    $raw="# header`r`nkey=`"0`"`n`r`nkey=`"0`"`r`nother=`"kept`""
    [IO.File]::WriteAllText($confFile,$raw)
    $missing=@(Set-BsrConfValues $confFile ([ordered]@{key='literal $1'; absent='x'}))
    $expected=$raw.Replace('key="0"','key="literal $1"')
    Check ([IO.File]::ReadAllText($confFile) -ceq $expected) 'config update preserves mixed EOLs, blank lines, duplicates and literal dollar signs'
    Check ($missing.Count -eq 1 -and $missing[0] -eq 'absent') 'missing config keys are reported without adding unsupported settings'
    $bytes=[IO.File]::ReadAllBytes($confFile)
    Check (-not($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'atomic config writes have no UTF-8 BOM'
    $backup=Join-Path $work 'once.bak'
    Copy-BsrBackupOnce $confFile $backup
    [IO.File]::WriteAllText($confFile,'changed')
    Copy-BsrBackupOnce $confFile $backup
    Check ([IO.File]::ReadAllText($backup) -ceq $expected) 'one-time backup retains the original content'
    Reject {Copy-BsrFileAtomically (Join-Path $work 'missing') $confFile -Replace} 'find|exist' 'failed restore leaves the current file intact'
    Check ([IO.File]::ReadAllText($confFile) -ceq 'changed') 'a failed restore does not truncate its target'
    Copy-BsrFileAtomically $backup $confFile -Replace
    Check ([IO.File]::ReadAllText($confFile) -ceq $expected) 'restore atomically replaces the destination with the backup'
    $absentBackup=Join-Path $work 'absent.bak'
    Reject {Copy-BsrBackupOnce (Join-Path $work 'missing') $absentBackup} 'find|exist' 'failed backup is not published'
    Check (-not(Test-Path -LiteralPath $absentBackup)) 'failed copy leaves no final backup'
    Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count -eq 0) 'transaction temporary files are cleaned up'

    $disk=Join-Path $work 'disk.bin'
    $diskBytes=New-Object byte[] 1536; $diskBytes[511]=83; $diskBytes[512]=239
    [IO.File]::WriteAllBytes($disk,$diskBytes)
    $read=Read-BsrDeviceBytes $disk 511 2
    Check ($read -is [byte[]] -and $read.Length -eq 2 -and $read[0] -eq 83 -and $read[1] -eq 239) 'raw read crosses a sector boundary and retains byte-array shape'
    Reject {Read-BsrDeviceBytes $disk 1535 2} 'Short disk read' 'truncated sectors cannot be zero-filled into a successful read'
    Reject {Read-BsrDeviceBytes $disk -1 2} 'Invalid' 'negative raw offsets are rejected'

    $stat="debugfs:  stat /missing`n"+
          "debugfs:  stat /present`nInode: 12 Type: regular Mode: 0700 Flags: 0x0`nUser: 0 Group: 0 Size: 10`n"+
          "debugfs:  stat /another`nInode: 13 Type: regular Mode: 0755`nUser: 1000 Group: 1000 Size: 20`n"
    Check (-not(Test-BsrDebugfsFile $stat '/missing' 10 448)) 'another file inode cannot validate a missing offline payload'
    Check (Test-BsrDebugfsFile $stat '/present' 10 448) 'offline stat validates size, permissions and ownership'
    Check (-not(Test-BsrDebugfsFile $stat '/present' 20 448)) 'offline stat rejects the wrong file length'
    Check (-not(Test-BsrDebugfsFile $stat '/present' 10 493)) 'offline stat rejects the wrong permissions'
    Check (-not(Test-BsrDebugfsFile $stat '/present' 10 448 1000 1000)) 'offline stat rejects the wrong owner'
    Check ((ConvertTo-BsrDebugfsPath "C:\space & O'Brien\file") -ceq '"C:/space & O''Brien/file"') 'debugfs source paths are quoted without shell interpretation'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $zipPath=Join-Path $work 'unsafe.zip'
    $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($name in @('safe.txt','../escape.txt')){
            $entry=$zip.CreateEntry($name);$stream=$entry.Open()
            try{$stream.WriteByte(65)}finally{$stream.Dispose()}
        }
    }finally{$zip.Dispose()}
    $extract=Join-Path $work 'extract'
    Reject {Expand-BsrZip $zipPath $extract} 'escapes' 'zip traversal is rejected before extracting any entry'
    Check (-not(Test-Path -LiteralPath $extract) -and -not(Test-Path -LiteralPath (Join-Path $work 'escape.txt'))) 'invalid archive writes nothing outside or inside the destination'
    Reject {Expand-BsrMagiskApk $zipPath (Join-Path $work 'magisk')} 'missing expected member' 'incomplete APK fails before creating staging files'

    # Issue #38 stops between the embedded APK message and PREP. Exercise all
    # three embedded payloads with a profile-shaped path containing punctuation,
    # spaces and Unicode, without reaching player shutdown or disk attachment.
    & {
        $savedWork=$script:WorkDir
        $savedApk=$script:MagiskApk;$savedSu=$script:BsrSu;$savedDfs=$script:Debugfs
        try {
            $script:WorkDir=Join-Path $work ("Users\Test [1] & O'Brien ! "+[char]0xe9+'\AppData\Local\Temp\bsr_work\session')
            $SelfCmd=Join-Path $repo 'blueStackRoot.cmd'
            $Here=Join-Path $work 'standalone'
            $script:MagiskApk=$null;$script:BsrSu=$null;$script:Debugfs=$null
            function Assert-BlueStacksHostTools {}
            function Kill-BlueStacks {throw 'fixture reached end of payload preparation'}
            Reject {Do-Prep} 'fixture reached end of payload preparation' 'standalone embedded APK, bootstrap su and debugfs all prepare from a complex temp path'
            Check ((Get-BsrFileHash $script:MagiskApk) -ceq 'fac319d2de262fcfff1684e13e1a5c61c486d2a773a7a8ffcfdbfe6f763a7fd4' -and (Get-BsrFileHash $script:BsrSu) -ceq $BSR_SU_SHA -and (Test-Path -LiteralPath $script:Debugfs)) 'prepared payloads retain their expected content'
            function Ensure-BsrSu {Get-Item -LiteralPath (Join-Path $work 'missing-bootstrap') -ErrorAction Stop | Out-Null}
            $message='';try {Do-Prep} catch {$message=Redact-UserPath $_.Exception.Message}
            Check ($message -match 'Could not prepare bootstrap su' -and $message -match 'PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand' -and $message -match 'missing-bootstrap') 'preparation failures identify the payload, PowerShell error ID and failing file'
        } finally {
            $script:WorkDir=$savedWork
            $script:MagiskApk=$savedApk;$script:BsrSu=$savedSu;$script:Debugfs=$savedDfs
        }
    }

    & {
        $SelfCmd=Join-Path $repo 'blueStackRoot.cmd'
        function Boot-And-Wait {throw 'fixture reached boot'}
        function Ensure-Debugfs {throw 'online Data must not extract debugfs'}
        Ensure-MagiskApk
        $stage=Join-Path $script:WorkDir 'databin'
        Extract-MagiskApk $MagiskApk $stage
        $expected=@{}
        $stamp=[datetime]::SpecifyKind([datetime]'2001-01-01',[DateTimeKind]::Utc)
        foreach($file in Get-ChildItem -LiteralPath $stage -File){
            $expected[$file.Name]=Get-BsrFileHash $file.FullName
            [IO.File]::SetLastWriteTimeUtc($file.FullName,$stamp)
        }
        Reject {Do-Data -Prepared} 'fixture reached boot' 'prepared Data reaches boot without an offline tool dependency'
        $same=$expected.Count -eq 10
        foreach($file in Get-ChildItem -LiteralPath $stage -File){
            if((Get-BsrFileHash $file.FullName) -ne $expected[$file.Name] -or $file.LastWriteTimeUtc -ne $stamp){$same=$false}
        }
        Check $same 'Auto reuses all ten prepared payloads without rewriting them'
        $preparedWork=$script:WorkDir
        try {
            $script:WorkDir=Join-Path $work 'standalone-data'
            Reject {Do-Data} 'fixture reached boot' 'standalone Data extracts its payloads before boot without debugfs'
            $files=@(Get-ChildItem -LiteralPath (Join-Path $script:WorkDir 'databin') -File)
            $same=$files.Count -eq $expected.Count
            foreach($file in $files){if((Get-BsrFileHash $file.FullName) -ne $expected[$file.Name]){$same=$false}}
            Check $same 'standalone Data stages the same complete payload as Prep'
        } finally { $script:WorkDir=$preparedWork }
    }

    # A real native fixture checks quoting, concurrent pipe drainage and timeouts.
    $probe=Join-Path $work 'argv probe.exe'
    Add-Type -TypeDefinition @'
using System;
using System.Text;
class BsrNativeFixture {
    static void Main(string[] args) {
        if(args.Length == 1 && args[0] == "sleep") { System.Threading.Thread.Sleep(10000); return; }
        Console.WriteLine("argc="+args.Length);
        foreach(var arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        Console.Error.WriteLine("stderr is data");
        Environment.ExitCode=7;
    }
}
'@ -OutputAssembly $probe -OutputType ConsoleApplication
    $arguments=@('','with spaces','quote"inside','C:\tail\',"O'Brien & !",('unicod'+[char]0xe9))
    $result=Invoke-BsrNative $probe $arguments
    $expectedLines=($arguments | ForEach-Object {[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_))}) -join "`r`n"
    # Output trims the leading empty line, so compare the base64 record for all
    # non-empty arguments as well as the explicit exit code/stderr.
    Check ($result.ExitCode -eq 7 -and $result.Output.StartsWith('argc=6') -and $result.Output.Contains($expectedLines) -and $result.Output.EndsWith('stderr is data')) 'native argv, trailing backslashes, quotes, Unicode and stderr round-trip'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Reject {Invoke-BsrNative $probe @('sleep') 1} 'timed out' 'hung native command is terminated'
    Check ($timer.Elapsed.TotalSeconds -lt 5) 'native timeout is bounded'

    & {
        function Get-CimInstance { @() }
        function Get-Content { '2026-10-01 12:00:00.000 123 1 PLR Rvc64_5 [Ready] I: ready' }
        function Get-Process { [pscustomobject]@{Id=123;Name='HD-Player';StartTime=[datetime]'2026-10-01 13:00:00'} }
        $log=Join-Path $work 'Player.log';[IO.File]::WriteAllText($log,'fixture')
        Check (@(Get-BsrInstanceProcesses 'Rvc64_5' $log).Count -eq 0) 'reused PID from an old Player.log is never treated as the target instance'
    }

    & {
        function Get-NetTCPConnection {throw 'module unavailable'}
        function Invoke-BsrNative {
            [pscustomobject]@{ExitCode=0;Output="  TCP 127.0.0.1:15037 0.0.0.0:0 ESCUCHANDO 42`n  TCP [::]:15038 [::]:0 ECOUTE 43`n  TCP 127.0.0.1:5555 127.0.0.1:6000 ESTABLISHED 44"}
        }
        $listeners=@(Get-BsrTcpListeners)
        Check ($listeners.Count -eq 2 -and $listeners[0].LocalPort -eq 15037 -and $listeners[1].OwningProcess -eq 43) 'netstat fallback recognizes localized IPv4 and IPv6 listeners without accepting connected sockets'
    }

    & {
        $script:stopped=@();$script:serverCalls=0;$script:foreignServer=$false
        function Get-BsrTcpListeners { [pscustomobject]@{LocalPort=15037;OwningProcess=123} }
        function Get-Process { [pscustomobject]@{Id=123;Path=$(if($script:foreignServer){'C:\foreign\adb.exe'}else{'C:\fixture\HD-Adb.exe'})} }
        function Invoke-BsrNative { $script:serverCalls++; throw 'fixture server hangs' }
        function Stop-Process { param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Force); process { $script:stopped+=$InputObject.Id } }
        Stop-BsrAdbServer 'C:\fixture\HD-Adb.exe' '15037'
        Check ($script:serverCalls -eq 1 -and $script:stopped.Count -eq 1 -and $script:stopped[0] -eq 123) 'hung private ADB shutdown stops only the verified owner'
        $script:foreignServer=$true
        Reject {Stop-BsrAdbServer 'C:\fixture\HD-Adb.exe' '15037'} 'foreign process' 'private-server cleanup refuses a foreign executable'
        Reject {Stop-BsrAdbServer 'C:\fixture\HD-Adb.exe' '5037'} 'outside the private' 'private-server cleanup refuses the shared ADB port'
        Check ($script:serverCalls -eq 1 -and $script:stopped.Count -eq 1) 'refused server cleanup neither invokes ADB nor stops a process'
    }

    & {
        $script:scanComplete=$true; $script:sweepComplete=$true; $script:competing=$false
        function Boot-And-Wait { '127.0.0.1:5595' }
        function Fixture-AdbOutput([string[]]$a){
            $script:LastAdbExitCode=0
            $command=$a -join '|'
            if($a -contains 'push'){return '1 file pushed'}
            if($command -match 'su -c id'){return 'uid=0(root) gid=0(root)'}
            if($command -match 'readlink /system/bin/su'){return '/sbin/magisk'}
            if($command -match 'su -c.*bsr_suscan.sh'){
                if($script:competing){return "/system/xbin/su|file|`nBSR_SCAN_DONE"}
                if($script:scanComplete){return "/system/bin/su|link|/sbin/magisk`nBSR_SCAN_DONE"}
                return 'incomplete scan'
            }
            if($command -match 'su -c.*bsr_sweep.sh'){if($script:sweepComplete){return 'SWEEPDONE'}else{return 'permission denied'}}
            return ''
        }
        function Adb([string[]]$a){
            $output=Fixture-AdbOutput $a
            if($a -contains 'exec-out'){return $output+"`nBSR_SHELL_DONE"}
            return $output
        }
        Do-Verify
        Check $true 'complete clean verification succeeds'
        $script:scanComplete=$false
        Reject {Do-Verify} 'verification failed' 'missing inventory completion cannot produce VERIFY PASS'
        $script:scanComplete=$true; $script:sweepComplete=$false
        Reject {Do-Verify} 'verification failed' 'failed bootstrap sweep cannot produce VERIFY PASS'
        $script:sweepComplete=$true; $script:competing=$true
        Reject {Do-Verify} 'verification failed' 'competing su produces a failing operation'
    }

    & {
        $script:attempts=0
        function Start-Sleep {}
        function Repair-AdbTransport {}
        function Adb([string[]]$a){
            if($a -notcontains 'exec-out'){return ''}
            $script:attempts++
            if($script:attempts -eq 1){return ''}
            return 'BSR_SHELL_DONE'
        }
        $output=AdbShellRetry 'fixture' 'sync'
        Check ($output -eq '' -and $script:attempts -eq 2) 'empty ADB response is retried; an explicitly completed silent command succeeds'
        $script:attempts=0
        Reject {AdbShellRetry 'fixture' 'sync' 1} 'did not complete' 'incomplete shell response fails when retries are exhausted'
    }

    & {
        $script:pushes=0;$script:AdbSerial='fixture'
        function Start-Sleep {}
        function Repair-AdbTransport {}
        function Adb([string[]]$a){
            $script:LastAdbExitCode=0
            if($a -notcontains 'push'){return ''}
            $script:pushes++
            if($script:pushes -eq 1){return ''}
            return '[100%] /data/local/tmp/fixture.sh'
        }
        $result=AdbTry @('-s','fixture','push','local','remote')
        Check ($script:pushes -eq 2 -and $result -match '100%') 'ADB push retries an empty success and accepts the older 100-percent progress format'
    }

    & {
        function Start-Sleep {}
        function Repair-AdbTransport {}
        function Adb { $script:LastAdbExitCode=0; 'Failure [DELETE_FAILED_INTERNAL_ERROR]' }
        Reject {AdbTry @('-s','fixture','uninstall','fixture.package') 1} 'did not confirm completion' 'uninstall cannot succeed without the package-manager Success response'
    }

    & {
        function Boot-And-Wait {throw 'fixture boot failure'}
        function Assert-BlueStacksHostTools {}
        function Kill-BlueStacks {}
        function Start-Sleep {}
        function Set-ConfKeys {}
        $Full=$false
        Reject {Do-Undo} 'undo was incomplete' 'undo cannot report success after failing to reach the instance'
    }

    & {
        $Install=Join-Path $work 'full-install';[void][IO.Directory]::CreateDirectory($Install)
        $Vhd=Join-Path $work 'full-root.vhd';$Conf=Join-Path $work 'full.conf'
        $Engine=Join-Path $repo 'tools\bsr_engine.ps1';$SelfCmd=Join-Path $repo 'blueStackRoot.cmd'
        [IO.File]::WriteAllText($Vhd,'modified disk');[IO.File]::WriteAllText(($Vhd+'.bsrbak'),'original disk')
        [IO.File]::WriteAllText((Join-Path $Install 'HD-Player.exe'),'modified player')
        [IO.File]::WriteAllText((Join-Path $Install 'HD-Player.exe.bak'),'original player')
        [IO.File]::WriteAllText($Conf,'bst.feature.rooting="1"')
        $Full=$true
        function Assert-BlueStacksHostTools {}
        function Boot-And-Wait {'fixture'}
        function Kill-BlueStacks {}
        function Start-Sleep {}
        function Adb {''}
        function AdbShellRetry([string]$serial,[string]$command){
            if($command -match 'BSR_RM_OK'){return 'BSR_RM_OK'}
            return 'BSR_PACKAGE_CHECK'
        }
        Do-Undo
        Check ([IO.File]::ReadAllText($Vhd) -ceq 'original disk' -and [IO.File]::ReadAllText((Join-Path $Install 'HD-Player.exe')) -ceq 'original player') 'full scrub restores both host files through the real engine using isolated fixtures'
        Remove-Item -LiteralPath ($Vhd+'.bsrbak')
        Reject {Do-Undo} 'requires a complete backup' 'full scrub rejects a missing backup before touching guest data'
    }

    & {
        $Conf=Join-Path $work 'bluestacks.conf';[IO.File]::WriteAllText($Conf,"bst.feature.rooting=`"1`"`n")
        $Instance='Rvc64_123';$Vhd=Join-Path $work 'Engine\Rvc64\Root.vhd'
        $master=Join-Path $work 'Engine\Rvc64\Rvc64.bstk'
        $clone=Join-Path $work 'Engine\Rvc64_123\Rvc64_123.bstk'
        foreach($path in @($master,$clone)){
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllText($path,'<HardDisk type="Normal" location="../Rvc64/Root.vhd"/><HardDisk location="Data.vhdx" type="Normal"/><HardDisk location="fastboot.vdi" type="Normal"/>')
        }
        Do-Finalize
        foreach($path in @($master,$clone)){
            $text=[IO.File]::ReadAllText($path)
            Check ($text -match 'type="Readonly" location="../Rvc64/Root.vhd"' -and $text -match 'location="Data.vhdx" type="Normal"' -and $text -match 'location="fastboot.vdi" type="Readonly"') 'finalize makes master and clone shared disks readonly while preserving writable Data'
        }
    }
} catch {$fail++;Write-Host "[FAIL] $_";Write-Host $_.ScriptStackTrace}
finally {
    $resolved=[IO.Path]::GetFullPath($work)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^bsr_safety_[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
