# Shared Windows disk and process helpers. Embedded in both single-file launchers.
# This file only defines functions; loading it never changes the host.

function Read-BsrDeviceBytes([string]$Device, [long]$Offset, [int]$Count) {
    if ($Offset -lt 0 -or $Count -le 0) { throw 'Invalid disk read offset or size.' }
    $sectorStart = $Offset - ($Offset % 512)
    $delta = [int]($Offset - $sectorStart)
    $needed = [long]$delta + $Count
    $aligned = $needed + ((512 - ($needed % 512)) % 512)
    if ($aligned -gt [int]::MaxValue) { throw 'Disk read is too large.' }
    $stream = [IO.File]::Open($Device, 'Open', 'Read', 'ReadWrite')
    try {
        $stream.Position = $sectorStart
        $buffer = New-Object byte[] ([int]$aligned)
        $filled = 0
        while ($filled -lt $buffer.Length) {
            $read = $stream.Read($buffer, $filled, $buffer.Length - $filled)
            if ($read -le 0) { throw "Short disk read at offset $Offset in '$Device'." }
            $filled += $read
        }
        $result = New-Object byte[] $Count
        [Array]::Copy($buffer, $delta, $result, 0, $Count)
        return ,$result
    } finally { $stream.Dispose() }
}

# ProcessStartInfo avoids PowerShell 5.1's lossy native argument conversion and
# stderr-as-errors. Drain both pipes concurrently, and bound every native call.
function Quote-BsrNativeArgument([AllowEmptyString()][string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
}

function Invoke-BsrNative([string]$FilePath, [string[]]$Arguments,
                          [ValidateRange(1,3600)][int]$TimeoutSec=30) {
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $FilePath
        $info.Arguments = ($Arguments | ForEach-Object { Quote-BsrNativeArgument $_ }) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $process.Kill()
            throw "Native command timed out after ${TimeoutSec}s: $([IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')"
        }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) {
            throw "Native output pipe did not close: $FilePath"
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($stdout.Result + [Environment]::NewLine + $stderr.Result).Trim()
        }
    } finally { if ($process) { $process.Dispose() } }
}

function Get-BsrFileHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}

function Get-BsrBytesHash([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Expand-BsrGzip([byte[]]$Bytes) {
    $inputStream = New-Object IO.MemoryStream(,$Bytes)
    $outputStream = New-Object IO.MemoryStream
    $gzip = $null
    try {
        $gzip = New-Object IO.Compression.GZipStream($inputStream,[IO.Compression.CompressionMode]::Decompress)
        $gzip.CopyTo($outputStream)
        return ,$outputStream.ToArray()
    } finally {
        if ($gzip) { $gzip.Dispose() }
        $inputStream.Dispose(); $outputStream.Dispose()
    }
}

function Expand-BsrZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $files = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            $path = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $entry.FullName))
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName -match ':') {
                throw "Archive entry escapes its extraction directory: $($entry.FullName)"
            }
            $files.Add(@{ Entry=$entry; Path=$path })
        }
        foreach ($file in $files) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file.Path))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($file.Entry, $file.Path, $true)
        }
    } finally { $zip.Dispose() }
}

function Get-BsrMagiskFileMap([switch]$IncludeUninstaller) {
    $map = [ordered]@{
        'lib/x86_64/libbusybox.so'='busybox'; 'lib/x86_64/libmagisk64.so'='magisk64'
        'lib/x86_64/libmagiskboot.so'='magiskboot'; 'lib/x86_64/libmagiskinit.so'='magiskinit'
        'lib/x86_64/libmagiskpolicy.so'='magiskpolicy'; 'lib/x86/libmagisk32.so'='magisk32'
        'assets/stub.apk'='stub.apk'; 'assets/util_functions.sh'='util_functions.sh'
        'assets/boot_patch.sh'='boot_patch.sh'; 'assets/addon.d.sh'='addon.d.sh'
    }
    if ($IncludeUninstaller) { $map['assets/uninstaller.sh']='uninstaller.sh' }
    return $map
}

function Expand-BsrMagiskApk([string]$Apk, [string]$Destination, [switch]$IncludeUninstaller) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $map = Get-BsrMagiskFileMap -IncludeUninstaller:$IncludeUninstaller
    $zip = [IO.Compression.ZipFile]::OpenRead($Apk)
    try {
        # Validate every required entry BEFORE replacing any existing staging file.
        foreach ($name in $map.Keys) {
            $entry = $zip.GetEntry($name)
            if (-not $entry -or $entry.Length -le 0) { throw "APK missing expected member: $name" }
        }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($name in $map.Keys) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($name), (Join-Path $Destination $map[$name]), $true)
        }
    } finally { $zip.Dispose() }
}

# Each disk/config backup appears at its final name only after the entire copy
# succeeds. A full disk or interrupted copy must never become a trusted backup.
function Copy-BsrFileAtomically([string]$Source, [string]$Destination, [switch]$Replace) {
    $temporary = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if($Replace -and [IO.File]::Exists($Destination)){[IO.File]::Replace($temporary,$Destination,[NullString]::Value)}
        else{[IO.File]::Move($temporary, $Destination)}
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-BsrBackupOnce([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { return }
    Copy-BsrFileAtomically $Source $Destination
}

function Write-BsrTextFile([string]$Path, [string]$Text) {
    $Path = [IO.Path]::GetFullPath($Path)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

# Modify only existing keys, retain each line ending, and treat replacement data
# literally (a '$1' in an instance name/value is not a regex backreference).
function Set-BsrConfValues([string]$Path, [System.Collections.IDictionary]$Values) {
    $raw = [IO.File]::ReadAllText($Path)
    $updated = $raw
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Values.Keys) {
        $pattern = '(?m)^[\t ]*' + [regex]::Escape($key) + '[\t ]*=[^\r\n]*'
        if (-not [regex]::IsMatch($updated, $pattern)) { $missing.Add($key); continue }
        $replacement = $key + '="' + $Values[$key] + '"'
        $updated = [regex]::Replace($updated, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
    }
    if ($updated -cne $raw) { Write-BsrTextFile $Path $updated }
    return $missing.ToArray()
}

function ConvertTo-BsrDebugfsPath([string]$Path) {
    if ($Path -match '["\r\n]') { throw 'Invalid character in debugfs path.' }
    '"' + $Path.Replace('\','/') + '"'
}

function Get-BsrDebugfsStat([string]$Output, [string]$Path) {
    # Match only this stat command's response. An inode from the next command
    # must never validate a failed write earlier in the same command file.
    $pattern = '(?ms)^debugfs:\s+stat\s+' + [regex]::Escape($Path) + '[\t ]*\r?\n(.*?)(?=^debugfs:|\z)'
    $match = [regex]::Match($Output, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Test-BsrDebugfsFile([string]$Output, [string]$Path, [long]$Length,
                            [int]$Mode, [int]$Uid=0, [int]$Gid=0) {
    $stat = Get-BsrDebugfsStat $Output $Path
    $permission = [regex]::Match($stat, 'Mode:\s*([0-7]+)')
    return ($stat -match '\bInode:\s*\d+' -and $stat -match ('\bSize:\s*' + $Length + '\b') -and
            $permission.Success -and [Convert]::ToInt32($permission.Groups[1].Value,8) -eq ($Mode -band 0xFFF) -and
            $stat -match ('\bUser:\s*'+$Uid+'\b') -and $stat -match ('\bGroup:\s*'+$Gid+'\b'))
}

function Test-HdPlayerInstance([string]$cmdLine, [string]$name) {
    if ([string]::IsNullOrWhiteSpace($cmdLine) -or [string]::IsNullOrWhiteSpace($name)) { return $false }
    $escaped = [regex]::Escape($name)
    $cmdLine -match "(?i)(^|\s)--instance(?:\s+|=)(`"$escaped`"|$escaped)(?=\s|$)"
}

function Get-BsrInstanceProcesses([string]$Instance, [string]$PlayerLog) {
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -ErrorAction Stop)) {
            if (Test-HdPlayerInstance $process.CommandLine $Instance) { [void]$ids.Add([int]$process.ProcessId) }
        }
    } catch { }
    # Some BlueStacks builds hide their WMI command line. Player.log is a second
    # exact-instance source; reject old log records whose PID has been reused.
    if ($PlayerLog -and (Test-Path -LiteralPath $PlayerLog)) {
        try {
            $tail = (Get-Content -LiteralPath $PlayerLog -Tail 6000 -ErrorAction Stop) -join "`n"
            $hits = [regex]::Matches($tail, '(?m)^(\S+\s+\S+)\s+(\d+)\s+\d+\s+\S+\s+' + [regex]::Escape($Instance) + '\s+\[')
            if ($hits.Count) {
                $last = $hits[$hits.Count - 1]
                $process = Get-Process -Id ([int]$last.Groups[2].Value) -ErrorAction Stop
                $logged = [datetimeoffset]::Parse($last.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                if ($process.Name -eq 'HD-Player' -and $logged.UtcDateTime -ge $process.StartTime.ToUniversalTime().AddSeconds(-2)) {
                    [void]$ids.Add($process.Id)
                }
            }
        } catch { }
    }
    foreach ($processId in $ids) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process -and $process.Name -eq 'HD-Player') { $process }
    }
}

function Get-BsrTcpListeners {
    try {
        Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Select-Object LocalPort, OwningProcess -Unique
    } catch {
        $result = Invoke-BsrNative 'netstat.exe' @('-ano','-p','tcp')
        if ($result.ExitCode) { throw 'Could not inspect local TCP listeners.' }
        foreach ($line in ($result.Output -split '\r?\n')) {
            # A listening socket has an all-zero remote endpoint. Its state
            # label is localized on non-English Windows installations.
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+(?:0\.0\.0\.0|\[::\]):0\s+\S+\s+(\d+)\s*$') {
                [pscustomobject]@{ LocalPort=[int]$Matches[1]; OwningProcess=[int]$Matches[2] }
            }
        }
    }
}

function Get-BsrAdbServerPortState([string]$AdbPath) {
    $state = @{}
    foreach ($listener in @(Get-BsrTcpListeners)) {
        $port = [int]$listener.LocalPort
        if ($port -lt 15037 -or $port -gt 15057) { continue }
        $path = $null
        try { $path = (Get-Process -Id $listener.OwningProcess -ErrorAction Stop).Path } catch { }
        $owner = if ($path -and (Test-SamePath $path $AdbPath)) { 'ours' } else { 'other' }
        # Multiple IPv4/IPv6 listeners may share a port: any foreign owner vetoes reuse.
        if ($state[$port] -ne 'other') { $state[$port] = $owner }
    }
    return $state
}

function Select-BsrAdbServerPort([hashtable]$State, [string]$Preferred=$env:ANDROID_ADB_SERVER_PORT) {
    $port = 0
    if ([int]::TryParse($Preferred, [ref]$port) -and $port -ge 15037 -and $port -le 15057 -and
        (-not $State[$port] -or $State[$port] -eq 'ours')) { return [string]$port }
    foreach ($port in 15037..15057) {
        if (-not $State[$port] -or $State[$port] -eq 'ours') { return [string]$port }
    }
    throw 'All private ADB server ports (15037-15057) are occupied. Close an unused private ADB server and retry.'
}

function Stop-BsrAdbServer([string]$AdbPath, [string]$Port=$env:ANDROID_ADB_SERVER_PORT) {
    $number=0
    if(-not [int]::TryParse($Port,[ref]$number) -or $number -lt 15037 -or $number -gt 15057){
        throw 'Refusing to stop an ADB server outside the private port range.'
    }
    $owners=@(Get-BsrTcpListeners | Where-Object {$_.LocalPort -eq $number} |
        Select-Object -ExpandProperty OwningProcess -Unique)
    if(-not $owners){return}
    foreach($ownerId in $owners){
        $owner=Get-Process -Id $ownerId -ErrorAction SilentlyContinue
        if(-not $owner -or -not (Test-SamePath $owner.Path $AdbPath)){
            throw "Refusing to stop a foreign process on private ADB port $number."
        }
    }
    # Some HD-Adb builds hang in kill-server. Bound the polite shutdown, then
    # stop only the previously verified executable still listening on OUR port.
    try { Invoke-BsrNative $AdbPath @('-P',[string]$number,'kill-server') 5 | Out-Null } catch { }
    foreach($listener in @(Get-BsrTcpListeners | Where-Object {$_.LocalPort -eq $number -and $owners -contains $_.OwningProcess})){
        $owner=Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if($owner -and (Test-SamePath $owner.Path $AdbPath)){ $owner | Stop-Process -Force -ErrorAction Stop }
    }
}

function Enter-BsrOperationLock {
    $mutex = New-Object Threading.Mutex($false, 'Local\BlueStackRoot.Magisk')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another blueStackRoot operation is running. Wait for it to finish before modifying shared BlueStacks disks.' }
        return $mutex
    } finally { if (-not $owned) { $mutex.Dispose() } }
}

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

function Redact-UserPath($value) {
    if ($null -eq $value) { return $value }
    $s = [string]$value
    $roots = @($env:USERPROFILE) | Where-Object { $_ }
    foreach ($root in $roots) {
        $root = $root.TrimEnd('\', '/')
        if (-not $root) { continue }
        $parent = Split-Path -Parent $root
        if ($parent) {
            $masked = [IO.Path]::Combine($parent,'xxxxx')
            $boundary='(?=[\\/\s"''<>]|$)'
            $s = $s -replace ("(?i)$([regex]::Escape($root))"+$boundary), ($masked -replace '\$', '$$')
            $s = $s -replace ("(?i)$([regex]::Escape(($root -replace '\\', '/')))"+$boundary), (($masked -replace '\\', '/') -replace '\$', '$$')
        }
    }
    $s = $s -replace '(?i)([A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)(?!xxxxx\b)([^\\/\r\n"<>]+)', '${1}xxxxx'
    $s = $s -replace '(?i)(/Users/)([^/]+)(?=$|/)', '${1}xxxxx'
    $s
}
function Normalize-DiscoveryPath([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $s = [Environment]::ExpandEnvironmentVariables($value.Trim())
    if ($s -match '^\s*"([^"]+)"') { $s = $Matches[1] }
    $s = $s.Trim().Trim('"').TrimEnd(' ', '\', '/')
    if (-not $s) { return $null }
    return $s
}

function Get-ExePathFromCommand([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $s = [Environment]::ExpandEnvironmentVariables($value.Trim())
    if ($s -match '^\s*"([^"]+?\.exe)"') { return $Matches[1] }
    if ($s -match '^\s*(.+?\.exe)(?:\s|$)') { return $Matches[1].Trim('"') }
    return $null
}

function Get-ObjectProperty($object, [string]$name) {
    if (-not $object) { return $null }
    $prop = $object.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-RegBlueStacksRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    function Add-RegRecord($source, $p) {
        if (-not $p) { return }
        $install = Normalize-DiscoveryPath (Get-ObjectProperty $p 'InstallDir')
        if (-not $install) { $install = Normalize-DiscoveryPath (Get-ObjectProperty $p 'InstallLocation') }
        if (-not $install) {
            $exe = Get-ExePathFromCommand (Get-ObjectProperty $p 'DisplayIcon')
            if (-not $exe) { $exe = Get-ExePathFromCommand (Get-ObjectProperty $p 'UninstallString') }
            if ($exe) { $install = Normalize-DiscoveryPath (Split-Path -Parent $exe) }
        }
        $data = Normalize-DiscoveryPath (Get-ObjectProperty $p 'DataDir')
        $user = Normalize-DiscoveryPath (Get-ObjectProperty $p 'UserDefinedDir')
        if (-not $install -and -not $data -and -not $user) { return }
        $id = ("$install|$data|$user").ToLowerInvariant()
        if ($seen.ContainsKey($id)) { return }
        $seen[$id] = $true
        [void]$records.Add([pscustomobject]@{
            Source = "$source"; InstallDir = $install; DataDir = $data; UserDefinedDir = $user
        })
    }

    foreach ($root in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node',
                        'HKCU:\SOFTWARE', 'HKCU:\SOFTWARE\WOW6432Node')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop |
                               Where-Object { $_.PSChildName -match '(?i)(bluestacks|msi.*app.*player)' })) {
                try { Add-RegRecord $key.PSPath (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop) } catch { }
            }
        } catch { }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                try {
                    $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    if ($key.PSChildName -match '(?i)bluestacks|msi.*app.*player' -or
                        (Get-ObjectProperty $p 'DisplayName') -match '(?i)bluestacks|msi.*app.*player') {
                        Add-RegRecord $key.PSPath $p
                    }
                } catch { }
            }
        } catch { }
    }
    return @($records | ForEach-Object { $_ })
}

function Get-RegBlueStacks {
    return @(Get-RegBlueStacksRecords | Select-Object -First 1)[0]
}

function Get-DataRootFromPath([string]$value) {
    $p = Normalize-DiscoveryPath $value
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
    try {
        if (-not (Get-Item -LiteralPath $p -ErrorAction Stop).PSIsContainer) {
            if ((Split-Path -Leaf $p) -ieq 'bluestacks.conf') { $p = Split-Path -Parent $p }
            else { return $null }
        }
    } catch { return $null }
    for ($i = 0; $i -lt 5 -and $p; $i++) {
        if (Test-Path -LiteralPath (Join-Path $p 'bluestacks.conf')) {
            return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\', '/')
        }
        $parent = Split-Path -Parent $p
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $null
}

function Get-InstallRootFromPath([string]$value) {
    $p = Normalize-DiscoveryPath $value
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
    try {
        if (-not (Get-Item -LiteralPath $p -ErrorAction Stop).PSIsContainer) { $p = Split-Path -Parent $p }
    } catch { return $null }
    for ($i = 0; $i -lt 4 -and $p; $i++) {
        if ((Test-Path -LiteralPath (Join-Path $p 'HD-Player.exe')) -and
            (Test-Path -LiteralPath (Join-Path $p 'HD-Adb.exe'))) {
            return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\', '/')
        }
        $parent = Split-Path -Parent $p
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $null
}

function Test-SamePath([string]$left, [string]$right) {
    if (-not $left -or -not $right) { return $false }
    try {
        return ([IO.Path]::GetFullPath($left).TrimEnd('\', '/') -ieq
                [IO.Path]::GetFullPath($right).TrimEnd('\', '/'))
    } catch { return ($left.TrimEnd('\', '/') -ieq $right.TrimEnd('\', '/')) }
}

function Get-RecordDataRoot($record) {
    if (-not $record) { return $null }
    foreach ($p in @($record.DataDir, $record.UserDefinedDir)) {
        $root = Get-DataRootFromPath $p
        if ($root) { return $root }
    }
    return $null
}

function Get-RuntimeInstallRoots {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('HD-Player', 'HD-Adb')) {
        try {
            foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try {
                    $root = Get-InstallRootFromPath $proc.Path
                    if ($root) { [void]$out.Add($root) }
                } catch { }
            }
        } catch { }
    }
    try {
        foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction Stop |
                           Where-Object { $_.Name -match '(?i)bstk|bluestacks' -or
                                          $_.DisplayName -match '(?i)bluestacks|msi.*app.*player' })) {
            $root = Get-InstallRootFromPath (Get-ExePathFromCommand $svc.PathName)
            if ($root) { [void]$out.Add($root) }
        }
    } catch { }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
        foreach ($exeName in @('HD-Player.exe', 'HD-Adb.exe')) {
            $key = Join-Path $root $exeName
            try {
                $raw = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('')
                $found = Get-InstallRootFromPath $raw
                if ($found) { [void]$out.Add($found) }
            } catch { }
        }
    }
    foreach ($exeName in @('HD-Player.exe', 'HD-Adb.exe')) {
        try {
            $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
            if ($cmd) {
                $root = Get-InstallRootFromPath $cmd.Source
                if ($root) { [void]$out.Add($root) }
            }
        } catch { }
    }
    return @($out | Select-Object -Unique)
}

function Get-Ext4Target($diskNumber, $physical) {
    # Returns @{ Device; Start; Length } for the ext4 region, by probing +0x438 == 0xEF53.
    $parts = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object Offset)
    foreach ($p in $parts) {
        $dev = "\\.\Harddisk$($diskNumber)Partition$($p.PartitionNumber)"
        try {
            $m = Read-BsrDeviceBytes $dev 0x438 2
            if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
                return @{ Device = $dev; Start = [long]0; Length = [long]$p.Size; Offset = [long]$p.Offset }
            }
        }
        catch { }  # partition device not openable -> skip
        # fallback: probe on the physical drive at the partition's absolute offset
        try {
            $m = Read-BsrDeviceBytes $physical ([long]$p.Offset + 0x438) 2
            if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
                return @{ Device = $physical; Start = [long]$p.Offset; Length = [long]$p.Size; Offset = [long]$p.Offset }
            }
        }
        catch { }
    }
    # superfloppy: ext4 directly at disk offset 0
    try {
        $m = Read-BsrDeviceBytes $physical 0x438 2
        if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
            $disk = Get-Disk -Number $diskNumber
            return @{ Device = $physical; Start = [long]0; Length = [long]$disk.Size; Offset = [long]0 }
        }
    }
    catch { }
    return $null
}
