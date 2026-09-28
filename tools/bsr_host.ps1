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
