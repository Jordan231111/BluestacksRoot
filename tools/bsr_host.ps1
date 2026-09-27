<#
  Shared Windows host I/O helpers. Canonical source: tools/bsr_host.ps1.
  tools/reembed.ps1 copies this block into the two engines and debug.cmd so
  downloaded single-file tools do not need additional files beside them.
  No helper changes ACLs, antivirus settings, or application-control policy.
#>
function Get-BsrExceptionDetail($record) {
    $e = if ($record -is [System.Management.Automation.ErrorRecord]) { $record.Exception } else { $record }
    $parts = New-Object System.Collections.Generic.List[string]
    while ($e -is [Exception]) {
        $hr = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.HResult), 0)
        $native = if ($e -is [ComponentModel.Win32Exception]) { " Win32=$($e.NativeErrorCode)" } else { '' }
        [void]$parts.Add(('{0}: HRESULT=0x{1:X8}{2}: {3}' -f $e.GetType().Name, $hr, $native, $e.Message))
        $e = $e.InnerException
    }
    return ($parts -join ' -> ')
}

# Mount-DiskImage otherwise chooses its provider by EXTENSION, not file bytes.
# Handle a VHDX stored under a .vhd filename without renaming/converting the
# master image. This detects a format, not whether the whole image is healthy.
function Get-BsrDiskStorageType([string]$ImagePath) {
    $fs = [IO.File]::Open($ImagePath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt 512) { throw "[BSR_DISK_FORMAT] Disk image is truncated (less than 512 bytes): $ImagePath" }
        $head = New-Object byte[] 512
        $read = 0
        while ($read -lt $head.Length) {
            $n = $fs.Read($head, $read, $head.Length - $read)
            if ($n -le 0) { throw '[BSR_DISK_FORMAT] Unexpected EOF reading the disk header.' }
            $read += $n
        }
        if ([Text.Encoding]::ASCII.GetString($head, 0, 8) -ceq 'vhdxfile') { return 'VHDX' }
        $fs.Position = $fs.Length - 512
        $footer = New-Object byte[] 512
        $read = 0
        while ($read -lt $footer.Length) {
            $n = $fs.Read($footer, $read, $footer.Length - $read)
            if ($n -le 0) { throw '[BSR_DISK_FORMAT] Unexpected EOF reading the VHD footer.' }
            $read += $n
        }
        if ([Text.Encoding]::ASCII.GetString($footer, 0, 8) -ceq 'conectix') { return 'VHD' }
        if ([BitConverter]::ToUInt32($head, 64) -eq [Convert]::ToUInt32('BEDA107F', 16)) {
            throw "[BSR_DISK_FORMAT] $ImagePath is VDI, not VHD/VHDX. Renaming it cannot convert it. No disk data was written."
        }
        throw "[BSR_DISK_FORMAT] No VHD footer or VHDX header in $ImagePath. The image may be unsupported or damaged; preserve it and its backup. No disk data was written."
    } finally { $fs.Dispose() }
}

function Mount-BsrDiskImage([string]$ImagePath, [switch]$ReadOnly) {
    $path = $ImagePath
    $storage = 'undetermined'
    $access = if ($ReadOnly) { 'ReadOnly' } else { 'ReadWrite' }
    try {
        $path = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path
        $storage = Get-BsrDiskStorageType $path
        # A query can itself fail when the filename has the wrong extension.
        # Let the explicit-format mount report the authoritative native error.
        $existing = $null
        try { $existing = Get-DiskImage -ImagePath $path -ErrorAction Stop } catch { }
        if ($existing -and $existing.Attached) {
            throw "[BSR_DISK_IN_USE] Image is already attached: $path. Close the emulator or detach your existing mount before retrying."
        }
        return Mount-DiskImage -ImagePath $path -StorageType $storage -Access $access -NoDriveLetter -PassThru -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match '\[BSR_DISK_') { throw }
        $cause = $_.Exception
        $detail = Get-BsrExceptionDetail $_
        $attributes = 'unavailable'
        try { $attributes = (Get-Item -LiteralPath $path -ErrorAction Stop).Attributes } catch { }
        $message = "[BSR_DISK_ATTACH] Cannot attach '$path' as $storage ($access; attributes=$attributes). $detail`nCheck image permissions, whether BlueStacks is still using it, the image/backup, and Windows virtual-disk support. A provider error is not evidence that antivirus damaged the script."
        throw (New-Object InvalidOperationException($message, $cause))
    }
}

# Fail before patching HD-Player.exe or changing configuration. Only detach a
# mount acquired here; never unmount a disk which was already attached by others.
function Test-BsrDiskAttach([string]$ImagePath) {
    $attached = $false
    try {
        Mount-BsrDiskImage $ImagePath | Out-Null
        $attached = $true
    } finally {
        if ($attached) { Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null }
    }
}

# These are observations, not a claim that a particular security product blocked
# the launch. HashMismatch is expected after patching and is NOT proof of a block.
function Get-BsrPlayerDiagnostics([string]$Player, [datetime]$Since) {
    try {
        $acl = Get-Acl -LiteralPath $Player -ErrorAction Stop
        $denies = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' }).Count
        "File ACL: explicit/inherited deny entries=$denies; inheritance protected=$($acl.AreAccessRulesProtected). Effective execute access still depends on the caller's token."
    } catch { "File ACL inspection unavailable: $($_.Exception.Message)" }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Player -ErrorAction Stop
        "Authenticode status=$($sig.Status). A patched executable can have HashMismatch; this alone does not prove a policy block."
    } catch { "Signature inspection unavailable: $($_.Exception.Message)" }
    $name = [regex]::Escape([IO.Path]::GetFileName($Player))
    foreach ($log in @('Microsoft-Windows-CodeIntegrity/Operational', 'Microsoft-Windows-AppLocker/EXE and DLL')) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$Since.AddMinutes(-1)} -MaxEvents 30 -ErrorAction Stop |
                Where-Object { $_.Message -match $name } | Select-Object -First 5)
            if (-not $events.Count) { "${log}: no recent matching event; this does not rule out a policy or permission block." }
            foreach ($event in $events) {
                $text = ($event.Message -replace '[\r\n]+', ' ')
                if ($text.Length -gt 1200) { $text = $text.Substring(0, 1200) + '...' }
                "${log}: ID=$($event.Id) at $($event.TimeCreated.ToString('o')) $text"
            }
        } catch { "${log}: no events available to this process." }
    }
}

function Start-BsrPlayer([string]$Player, [string]$Instance) {
    if (-not (Test-Path -LiteralPath $Player -PathType Leaf)) { throw "[BSR_PLAYER_LAUNCH] Player executable not found: $Player" }
    if ([string]::IsNullOrWhiteSpace($Instance) -or $Instance -match '["\x00-\x1f]') { throw '[BSR_PLAYER_LAUNCH] Invalid instance name.' }
    $path = (Resolve-Path -LiteralPath $Player -ErrorAction Stop).Path
    $started = Get-Date
    try {
        # The orchestrator uses ErrorActionPreference=Continue for native adb
        # stderr. Override that here: a rejected launch MUST NOT enter ADB polling.
        $process = Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -ArgumentList @('--instance', ('"{0}"' -f $Instance)) -PassThru -ErrorAction Stop
        if ($process) { try { return $process.Id } finally { $process.Dispose() } }
    } catch {
        $cause = $_.Exception
        $detail = Get-BsrExceptionDetail $_
        $diagnostics = @(Get-BsrPlayerDiagnostics $path $started)
        $message = (@("[BSR_PLAYER_LAUNCH] Windows could not start '$path' for instance '$Instance'.", $detail,
            'No ADB retry can fix a rejected process launch. Repair the BlueStacks installation/file permissions or ask the policy administrator to review the events below. Do not disable antivirus or application-control policies.') + $diagnostics) -join "`n"
        throw (New-Object InvalidOperationException($message, $cause))
    }
}
