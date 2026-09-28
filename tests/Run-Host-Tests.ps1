<# Windows host regressions for issues #31/#32. Only creates throwaway files/disks.
   -LiveDisks also tests real VHD/VHDX attach, detach, and reattach; needs admin. #>
param([switch]$LiveDisks)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\tools\bsr_host.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_host_test_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$pass=0; $fail=0
function Check($condition,[string]$name) {
    if($condition){$script:pass++;Write-Host "[PASS] $name" -ForegroundColor Green}
    else{$script:fail++;Write-Host "[FAIL] $name" -ForegroundColor Red}
}
function Expect-Failure([scriptblock]$action,[string]$pattern,[string]$name) {
    $message='';try{& $action | Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match $pattern) "$name ($message)"
}
try {
    $disk=Join-Path $work 'Root.vhd'
    [IO.File]::WriteAllBytes($disk,(New-Object byte[] 20))
    Check ((Get-BsrDiskFormat $disk) -eq 'Truncated') 'truncated image is rejected explicitly'
    Expect-Failure {Mount-BsrDisk $disk} 'Truncated' 'do not hand damaged content to a disk provider'
    $bytes=New-Object byte[] 4096
    [IO.File]::WriteAllBytes($disk,$bytes)
    Expect-Failure {Mount-BsrDisk $disk} 'Unknown' 'unrecognized image is rejected before mounting'
    [Array]::Copy([BitConverter]::GetBytes([uint32]3201962111),0,$bytes,64,4)
    [IO.File]::WriteAllBytes($disk,$bytes)
    Expect-Failure {Mount-BsrDisk $disk} 'VDI' 'VDI named .vhd is identified, never modified as VHD'

    $carve=Join-Path $work 'carve.img'
    Expect-Failure {Copy-BsrDiskRegion $disk 0 8192 $carve} 'Short disk read' 'short disk read never becomes a successful carve'
    Expect-Failure {Copy-BsrDiskRegion $disk 0 ([long]8GB) $carve} 'Short disk read' 'regions above 2 GB use 64-bit sizes without overload truncation'
    $before=(Get-FileHash -LiteralPath $disk).Hash
    [IO.File]::WriteAllBytes($carve,(New-Object byte[] 513))
    Expect-Failure {Write-BsrDiskRegion $carve $disk 0} 'sector-aligned' 'unaligned images cannot be padded into adjacent data'
    [IO.File]::WriteAllBytes($carve,(New-Object byte[] 512))
    Expect-Failure {Write-BsrDiskRegion $carve $disk 0 1024} 'size changed' 'changed image size blocks writeback'
    Check ((Get-FileHash -LiteralPath $disk).Hash -eq $before) 'rejected writeback leaves destination byte-identical'
    Copy-BsrDiskRegion $disk 512 1024 $carve
    Write-BsrDiskRegion $carve $disk 512 1024
    Check ((Get-FileHash -LiteralPath $disk).Hash -eq $before) 'aligned region copy round-trips byte-for-byte'

    # A real process reports the argv/cwd it received. The same file then gets a
    # temporary execute-deny ACE to reproduce Win32 5 without touching BlueStacks.
    $exe=Join-Path $work 'HD-Player.exe'
    Add-Type -TypeDefinition 'using System; using System.IO; class BsrHostProbe { static void Main(string[] args) { File.WriteAllText("launch-result.txt",Environment.CurrentDirectory+"|"+String.Join("|",args)); if(args[1]=="Rvc64_456") { File.WriteAllText("long.pid",System.Diagnostics.Process.GetCurrentProcess().Id.ToString()); System.Threading.Thread.Sleep(15000); } } }' -OutputAssembly $exe -OutputType WindowsApplication
    $launched=Start-BsrPlayer $exe 'Rvc64_123'
    $result=Join-Path $work 'launch-result.txt'
    for($i=0;$i -lt 50 -and -not(Test-Path -LiteralPath $result);$i++){Start-Sleep -Milliseconds 100}
    Check ((Test-Path -LiteralPath $result) -and ([IO.File]::ReadAllText($result) -eq "$work|--instance|Rvc64_123")) 'real player launch preserves working directory and exact instance argv'
    Expect-Failure {Start-BsrPlayer $exe 'Rvc64" --other'} 'Invalid BlueStacks instance' 'reject command-line injection in instance identifiers'
    $library=(Resolve-Path (Join-Path $PSScriptRoot '..\tools\bsr_host.ps1')).Path
    $command=". '$($library.Replace("'","''"))'; Start-BsrPlayer '$($exe.Replace("'","''"))' Rvc64_456"
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=(Get-Command powershell.exe).Source
    $start.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $runner=[Diagnostics.Process]::Start($start)
    $stdout=$runner.StandardOutput.ReadToEndAsync();$stderr=$runner.StandardError.ReadToEndAsync()
    try {
        Check ($runner.WaitForExit(7000)) 'parent PowerShell exits while the launched GUI is still alive'
        Check ($stdout.Wait(2000) -and $stderr.Wait(2000)) 'GUI inherits no output pipe that can hang the caller'
        $longPidFile=Join-Path $work 'long.pid'
        Check ((Test-Path -LiteralPath $longPidFile) -and $null -ne (Get-Process -Id ([int][IO.File]::ReadAllText($longPidFile)) -EA SilentlyContinue)) 'pipe regression was tested against a still-running process'
    } finally {
        $longPidFile=Join-Path $work 'long.pid'
        if(Test-Path -LiteralPath $longPidFile){Stop-Process -Id ([int][IO.File]::ReadAllText($longPidFile)) -Force -EA SilentlyContinue}
        if(-not $runner.HasExited){$runner.Kill()}
        $runner.Dispose()
    }
    $oldAcl=Get-Acl -LiteralPath $exe
    $acl=Get-Acl -LiteralPath $exe
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $deny=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::ExecuteFile,[Security.AccessControl.AccessControlType]::Deny)
    try {
        $acl.AddAccessRule($deny);Set-Acl -LiteralPath $exe -AclObject $acl
        Expect-Failure {Start-BsrPlayer $exe Rvc64} 'Win32=5' 'execute denial retains the native Windows error'
    } finally {Set-Acl -LiteralPath $exe -AclObject $oldAcl}

    $command=". '$($library.Replace("'","''"))'; `$env:PSModulePath=''; Get-BsrPlayerDiagnostics '$($exe.Replace("'","''"))'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $diagnostics=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | Out-String)
    Check ($diagnostics -match 'HD-Player signature=NotSigned' -and $diagnostics -match 'HD-Player ACL: [OGDS]:') 'signature and ACL diagnostics work without inherited module discovery paths'

    # The offline phase must fail before changing either the player or conf.
    & {
        . (Join-Path $PSScriptRoot '..\tools\bsr_magisk.ps1')
        $script:hostMutated=$false
        function Assert-BlueStacksHostTools {}
        function Ensure-MagiskApk {}
        function Ensure-BsrSu {}
        function Ensure-Debugfs {}
        function Kill-BlueStacks {}
        function Mount-BsrDisk {throw 'PRECHECK_PROVIDER_MISSING'}
        function Set-ConfKey {$script:hostMutated=$true}
        function Copy-Item {$script:hostMutated=$true}
        function powershell.exe {$script:hostMutated=$true}
        Expect-Failure {Do-Prep} 'PRECHECK_PROVIDER_MISSING' 'mount failure aborts the offline preflight'
        Check (-not $script:hostMutated) 'mount failure leaves the player, conf, and backups unchanged'
    }

    if($LiveDisks) {
        $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
        if(-not $admin){throw '-LiveDisks requires Administrator.'}
        foreach($format in 'VHD','VHDX') {
            $original=Join-Path $work ('original.'+$format.ToLowerInvariant())
            $dp=Join-Path $work 'diskpart.txt'
            @("create vdisk file=`"$original`" maximum=64 type=expandable",'exit') | Set-Content -LiteralPath $dp -Encoding ascii
            & diskpart.exe /s $dp | Out-Null
            if(-not(Test-Path -LiteralPath $original)){throw "diskpart did not create $format test image"}
            foreach($name in @("$format-Root.vhd","$format-backup.bsrbak")) {
                $path=Join-Path $work $name
                Copy-Item -LiteralPath $original -Destination $path
                Check ((Get-BsrDiskFormat $path) -eq $format) "$name detected from its contents"
                $mounted=$null
                try {
                    $mounted=Mount-BsrDisk $path -ReadOnly
                    Check $mounted.Attached "$name attaches read-only with explicit format"
                    Expect-Failure {Mount-BsrDisk $path} 'already attached' 'do not take ownership of somebody else''s mounted image'
                } finally {if($mounted){Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null}}
                $after=Get-DiskImage -ImagePath $path -StorageType $format
                Check (-not $after.Attached) "$name is actually detached (including VHDX with .vhd extension)"
                $mounted=$null
                try{$mounted=Mount-BsrDisk $path;Check $mounted.Attached "$name can reopen read/write after detach"}
                finally{if($mounted){Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null}}
            }
        }
    }
} catch {$fail++;Write-Host $_ -ForegroundColor Red;Write-Host $_.ScriptStackTrace}
finally {
    $resolved=[IO.Path]::GetFullPath($work)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'bsr_host_test_*'){throw "Unsafe test cleanup path: $resolved"}
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
