<#
  bsr_engine.ps1  --  blueStackRoot engine

  PowerShell helpers for player patching, instance configuration, disk editing,
  and the legacy classic-su actions used by the regression tests.

  This file is the canonical source.  It is embedded verbatim inside
  blueStackRoot.cmd (between the engine BEGIN/END marker lines); the .cmd
  extracts it to a temp .ps1 at run time and calls it.  The test-suite extracts
  the embedded copy and runs it, so the .cmd is what is actually tested.

  ACTIONS
    Patch     Version-proof HD-Player.exe disk-integrity patch (NOP the jz of every
              validated  CALL ; TEST AL,AL ; JZ  site).   -Restore reverts from .bak,
              -DryRun previews.
    Root      Offline install of the embedded setuid su into the ext4 inside Root.vhd
              (/android/system/xbin/su, mode 0106755, owner 0:0) via debugfs.
    Unroot    Offline removal of /android/system/xbin/su from Root.vhd.
    ExtractSu Decode the embedded su payload to -OutFile (used by tests / debugging).
    TestExt4  Run the exact debugfs edit against a plain ext4 image (-Img) -- used by
              the test-suite to exercise the ext4 logic with no VHD / no admin.

  The su payload travels inside the .cmd.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Patch', 'Root', 'Unroot', 'ExtractSu', 'TestExt4', 'DiskRW', 'DiskRO', 'ConfRoot', 'ConfUnroot', 'Resolve', 'BaseDir', 'VhdSelfTest', 'AdbRoot', 'AdbUnroot', 'AdbVerify')]
    [string]$Action,

    [string]$Exe,        # HD-Player.exe (Patch)
    [string]$Vhd,        # Root.vhd       (Root / Unroot)
    [string]$Bstk,       # <instance>.bstk (DiskRW / DiskRO)
    [string]$Conf,       # bluestacks.conf (ConfRoot / ConfUnroot)
    [string]$Instance,   # instance name   (ConfRoot / ConfUnroot / AdbRoot)
    [string]$SelfPath,   # the .cmd carrying the embedded su (+debugfs) blobs
    [string]$Debugfs,    # path to debugfs.exe (offline fallback)
    [string]$OutFile,    # ExtractSu target
    [string]$Img,        # TestExt4 target (plain ext4 image)
    [string]$DataDir,    # BlueStacks DataDir (Resolve / BaseDir)
    [string]$UserDef,    # BlueStacks UserDefinedDir (Resolve / BaseDir)
    [string]$InstallDir, # BlueStacks install folder (Resolve)
    [string]$CustomPath, # user-selected install OR data folder (Resolve / BaseDir)
    [string]$Base,       # base version e.g. Rvc64 (Resolve)
    [string]$Adb,        # HD-Adb.exe                       (AdbRoot / AdbUnroot)
    [string]$Player,     # HD-Player.exe (to boot instance) (AdbRoot)
    [string]$AdbPort,    # instance adb port, e.g. 5555     (AdbRoot)

    [switch]$Restore,
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$NoLaunch,   # AdbRoot: do not auto-launch the instance (assume already booted)
    [switch]$Force       # patch even when no anchor string validates a candidate
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Set-StrictMode -Version 2

# Allow the .cmd to pass path-like inputs via environment variables (avoids batch quoting pain).
function EnvOr([string]$val, [string]$name) { if ($val) { return $val } $e = [Environment]::GetEnvironmentVariable($name); if ($e) { return $e } return $val }
$Exe = EnvOr $Exe 'BSR_EXE'
$Vhd = EnvOr $Vhd 'BSR_VHD'
$Bstk = EnvOr $Bstk 'BSR_BSTK'
$Conf = EnvOr $Conf 'BSR_CONF'
$Instance = EnvOr $Instance 'BSR_INSTANCE'
$SelfPath = EnvOr $SelfPath 'BSR_SELF'
$Debugfs = EnvOr $Debugfs 'BSR_DEBUGFS'
$DataDir = EnvOr $DataDir 'BSR_DATADIR'
$UserDef = EnvOr $UserDef 'BSR_USERDEF'
$InstallDir = EnvOr $InstallDir 'BSR_INSTALL'
$CustomPath = EnvOr $CustomPath 'BSR_CUSTOM'
$Base = EnvOr $Base 'BSR_BASE'
$Adb = EnvOr $Adb 'BSR_ADB'
$Player = EnvOr $Player 'BSR_PLAYER'
$AdbPort = EnvOr $AdbPort 'BSR_ADBPORT'
if (-not $Restore -and $env:BSR_RESTORE -eq '1') { $Restore = $true }
if (-not $NoBackup -and $env:BSR_NOBACKUP -eq '1') { $NoBackup = $true }
if (-not $NoLaunch -and $env:BSR_NOLAUNCH -eq '1') { $NoLaunch = $true }
if (-not $Force -and $env:BSR_FORCE -eq '1') { $Force = $true }

function Say([string]$m, [string]$c = 'Gray') { Write-Host (Redact-UserPath $m) -ForegroundColor $c }

# Read the (large) self/.cmd file at most once per process. Get-EmbeddedSu and
# Expand-EmbeddedDebugfs both scan it; on the Root path BOTH run, so memoizing by path turns
# up to two ~21 MB reads into one. $Script:SelfReadCount is a test seam (asserted by tests).
$Script:SelfTextCache = @{}
$Script:SelfReadCount = 0
function Get-SelfText([string]$path) {
    if (-not $path) { return $null }
    if ($Script:SelfTextCache.ContainsKey($path)) { return $Script:SelfTextCache[$path] }
    $Script:SelfReadCount++
    $t = [System.IO.File]::ReadAllText($path)
    $Script:SelfTextCache[$path] = $t
    return $t
}

if ($SelfPath) {
    $hostText = Get-SelfText $SelfPath
    $hostBegin = '__BSR_HOST_' + 'BEGIN__'; $hostEnd = '__BSR_HOST_' + 'END__'
    $hostStart = $hostText.IndexOf($hostBegin); $hostStop = $hostText.IndexOf($hostEnd)
    if ($hostStart -lt 0 -or $hostStop -le $hostStart) { throw 'Embedded HOST helpers are missing; re-download the complete blueStackRoot.cmd.' }
    $hostStart = $hostText.IndexOf([char]10, $hostStart) + 1
    . ([scriptblock]::Create($hostText.Substring($hostStart, $hostStop - $hostStart)))
} else {
    . (Join-Path $PSScriptRoot 'bsr_host.ps1')
}

# BlueStacks layout discovery. Filesystem locations are never guessed from ProgramFiles/ProgramData or
# product folder names. Product + uninstall registry records remain paired, and every selected location
# is validated by BlueStacks-owned marker files before use. A running process/service, App Paths entry,
# or PATH entry can rescue a missing/stale InstallDir.
function Resolve-InstallRoot([string]$preferred, [string]$custom, [string]$dataRoot) {
    $customInstall = Get-InstallRootFromPath $custom
    if ($customInstall) { return $customInstall }

    $records = @(Get-RegBlueStacksRecords)
    foreach ($record in $records) {
        $recordData = Get-RecordDataRoot $record
        $recordInstall = Get-InstallRootFromPath $record.InstallDir
        if ($recordInstall -and $recordData -and (Test-SamePath $recordData $dataRoot)) { return $recordInstall }
    }

    $preferredInstall = Get-InstallRootFromPath $preferred
    if ($preferredInstall) { return $preferredInstall }

    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-RuntimeInstallRoots)) {
        if ($root -and -not ($valid -contains $root)) { [void]$valid.Add($root) }
    }
    foreach ($record in $records) {
        $root = Get-InstallRootFromPath $record.InstallDir
        if ($root -and -not ($valid -contains $root)) { [void]$valid.Add($root) }
    }
    if ($valid.Count -eq 1) { return $valid[0] }
    if ($valid.Count -gt 1) {
        throw "Multiple BlueStacks installations were found and none matches the selected data folder. Use option 8 and select the intended install folder."
    }
    throw "BlueStacks install folder was not found. Registry, uninstall records, running processes, services, App Paths, and PATH contained no folder with both HD-Player.exe and HD-Adb.exe. Use option 8 to select it."
}

# Expected SHA-256 of the decrypted su ELF (derivation Â§1).  Used as an integrity gate.
$Script:SuSha256 = '185106357CFC0D1DB4B8EFB033DE863F437850437E0EF6B62630C05F291B4902'

# ---------------------------------------------------------------------------
# Embedded su extraction
# ---------------------------------------------------------------------------
# Markers are built by concatenation so the literal token appears in the file
# ONLY on the real blob lines, never here -- otherwise IndexOf would match this code.
function Get-EmbeddedSu([string]$selfPath) {
    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath)) {
        throw "Embedded-su source not found (SelfPath='$selfPath'). Pass -SelfPath <blueStackRoot.cmd>."
    }
    $text = Get-SelfText $selfPath
    $beg = '__BSR_SU_' + 'BEGIN__'
    $end = '__BSR_SU_' + 'END__'
    $i = $text.IndexOf($beg)
    $j = $text.IndexOf($end)
    if ($i -lt 0 -or $j -lt 0 -or $j -le $i) { throw "su payload markers not found in '$selfPath'." }
    $i += $beg.Length
    $b64 = $text.Substring($i, $j - $i)
    # strip all whitespace (line wraps, CR/LF, the marker's own EOL)
    $b64 = ($b64 -replace '\s', '')
    if ($b64.Length -lt 64) { throw "su payload is empty -- run tools/embed-su.ps1 to populate it." }
    $gz = [Convert]::FromBase64String($b64)
    $bytes = Expand-BsrGzip $gz
    # integrity gate
    $sha = (Get-Sha256Hex $bytes)
    if ($sha -ne $Script:SuSha256) {
        throw "Embedded su FAILED integrity check.`n  expected $($Script:SuSha256)`n  got      $sha"
    }
    return ,$bytes
}

function Get-Sha256Hex([byte[]]$bytes) {
    return (Get-BsrBytesHash $bytes).ToUpperInvariant()
}

# ---------------------------------------------------------------------------
# Embedded debugfs bundle (offline fallback) -- a base64'd .zip of the Cygwin
# debugfs.exe + its 10 DLLs, carried inside the .cmd between __BSR_DFS_* lines.
# Extracted to a private directory for this invocation. Returns debugfs.exe
# path, or $null if no bundle is embedded.
# ---------------------------------------------------------------------------
function Expand-EmbeddedDebugfs([string]$selfPath) {
    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath)) { return $null }
    $text = Get-SelfText $selfPath
    $beg = '__BSR_DFS_' + 'BEGIN__'; $end = '__BSR_DFS_' + 'END__'
    $i = $text.IndexOf($beg); $j = $text.IndexOf($end)
    if ($i -lt 0 -or $j -le $i) { return $null }   # no bundle embedded
    $i += $beg.Length
    $bytes = [Convert]::FromBase64String($text.Substring($i, $j - $i))
    if ((Get-BsrBytesHash $bytes) -ne '008b6006e766d2591c8c7db7bf6d6a0a4b9cd6116b9a8e2737151828eb577632') {
        throw 'Embedded debugfs bundle failed integrity verification. Re-download the complete .cmd.'
    }
    $destDir = Join-Path (Join-Path $env:TEMP 'bsr_work') ('engine_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($destDir)
    [void]$Script:TempDirectories.Add($destDir)
    $zipPath = Join-Path $destDir '_dfs.zip'
    [IO.File]::WriteAllBytes($zipPath, $bytes)
    Expand-BsrZip $zipPath $destDir
    $exe = Join-Path $destDir 'debugfs.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'debugfs.exe missing after embedded extraction.' }
    $script:Debugfs = $exe
    return $exe
}

# ===========================================================================
#  PATCH  --  HD-Player.exe disk-integrity bypass (version proof)
# ===========================================================================
# raw file offset -> RVA across all sections
function RawToRva([int]$raw, $sections) {
    foreach ($s in $sections) {
        if ($raw -ge $s.RawPtr -and $raw -lt ($s.RawPtr + $s.RawSize)) { return [int]($s.VA + ($raw - $s.RawPtr)) }
    }
    return -1
}

# RVA of every occurrence of an ASCII (NUL-terminated) string
function StringRvas([byte[]]$b, [string]$text, $sections) {
    $needle = [System.Text.Encoding]::ASCII.GetBytes($text)
    $hits = New-Object System.Collections.Generic.List[int]
    $max = $b.Length - $needle.Length - 1
    # Native [Array]::IndexOf jumps straight to each first-byte match instead of stepping every
    # byte in interpreted PowerShell (~88x faster on a 27 MB file). Identical hit set: it visits
    # exactly the same positions -- every i in [0,max] where b[i]==needle[0] -- and runs the same
    # needle + NUL-terminator verification at each.
    $first = $needle[0]; $nlen = $needle.Length
    $i = [Array]::IndexOf($b, $first, 0)
    while ($i -ge 0 -and $i -le $max) {
        $ok = $true
        for ($k = 1; $k -lt $nlen; $k++) { if ($b[$i + $k] -ne $needle[$k]) { $ok = $false; break } }
        if ($ok -and $b[$i + $nlen] -eq 0) {
            $rva = RawToRva $i $sections
            if ($rva -ge 0) { [void]$hits.Add($rva) }
        }
        $i = [Array]::IndexOf($b, $first, $i + 1)
    }
    return $hits
}

# Is there a RIP-relative LEA to any of $targetRvas within +/-window of $t (TEST offset)?
function NearAnchor([byte[]]$b, [int]$t, [int]$textVA, [int]$textRaw, [int]$window, $targetSet) {
    $lo = [Math]::Max($textRaw, $t - $window); $hi = $t + $window
    if ($hi -gt $b.Length - 7) { $hi = $b.Length - 7 }
    for ($p = $lo; $p -lt $hi; $p++) {
        $rex = $b[$p]
        if ($rex -ne 0x48 -and $rex -ne 0x4C -and $rex -ne 0x49 -and $rex -ne 0x4D) { continue }
        if ($b[$p + 1] -ne 0x8D) { continue }              # LEA
        if (($b[$p + 2] -band 0xC7) -ne 0x05) { continue }  # mod=00, rm=101 -> [rip+disp32]
        $disp = [BitConverter]::ToInt32($b, $p + 3)
        $target = $textVA + (($p + 7) - $textRaw) + $disp   # RVA after the 7-byte LEA + disp
        if ($targetSet.Contains($target)) { return $true }
    }
    return $false
}

function Invoke-Patch {
    if (-not $Exe) { throw "Patch requires -Exe <HD-Player.exe>." }
    if (-not (Test-Path -LiteralPath $Exe)) { throw "HD-Player.exe not found: $Exe" }
    $bak = "$Exe.bak"

    if ($Restore) {
        if (-not (Test-Path -LiteralPath $bak)) { Say "[!] No backup to restore: $bak" Red; return 1 }
        if ($DryRun) { Say "[+] Dry run -- would restore $Exe from $bak. No file written." Yellow; return 0 }
        Copy-BsrFileAtomically $bak $Exe -Replace
        Say "[+] Restored $Exe from $bak" Green
        return 0
    }

    $b = [System.IO.File]::ReadAllBytes($Exe)
    Say "[*] Loaded $Exe ($($b.Length) bytes)"
    if ($b.Length -lt 0x200) { Say "[!] File too small for a PE." Red; return 1 }

    $e_lfanew = [BitConverter]::ToInt32($b, 0x3C)
    if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A -or $e_lfanew -le 0 -or
        [long]$e_lfanew + 0x40 -ge $b.Length -or
        [BitConverter]::ToUInt32($b,$e_lfanew) -ne 0x4550) {
        Say "[!] Invalid PE header." Red; return 1
    }
    $numSections = [BitConverter]::ToUInt16($b, $e_lfanew + 6)
    $sizeOptHdr = [BitConverter]::ToUInt16($b, $e_lfanew + 20)
    $optHdr = $e_lfanew + 24
    $secTable = [long]$optHdr + $sizeOptHdr
    if ($sizeOptHdr -lt 32 -or $numSections -eq 0 -or $secTable + [long]$numSections * 40 -gt $b.Length) {
        Say '[!] Truncated PE optional header or section table.' Red; return 1
    }
    $magic = [BitConverter]::ToUInt16($b, $optHdr)
    if ($magic -eq 0x20B) { $imageBase = [BitConverter]::ToUInt64($b, $optHdr + 24) }
    elseif ($magic -eq 0x10B) { $imageBase = [BitConverter]::ToUInt32($b, $optHdr + 28) }
    else { Say '[!] Unsupported PE optional header.' Red; return 1 }

    $textRaw = $null; $textRawSize = $null; $textVA = $null
    $sections = @()
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secTable + ($i * 40)
        $name = ([System.Text.Encoding]::ASCII.GetString($b, $s, 8)).TrimEnd([char]0)
        $va = [BitConverter]::ToUInt32($b, $s + 12)
        $rs = [BitConverter]::ToUInt32($b, $s + 16)
        $pr = [BitConverter]::ToUInt32($b, $s + 20)
        if ($rs -gt 0 -and ([long]$pr + $rs -gt $b.Length -or $pr -lt $secTable + [long]$numSections * 40)) {
            Say "[!] Invalid PE section bounds: $name" Red; return 1
        }
        $sections += [pscustomobject]@{ Name = $name; VA = $va; RawSize = $rs; RawPtr = $pr }
        if ($name -eq '.text') { $textVA = [int]$va; $textRaw = [int]$pr; $textRawSize = [int]$rs }
    }
    if ($null -eq $textRaw) { Say "[!] .text section not found." Red; return 1 }

    # anchor string RVAs (faithful set + extra-hardening set)
    $primaryStr = @('Verified the disk integrity!', 'Failed to verify the disk integrity!')
    $fallbackStr = @('plrDiskCheckThreadEntry',
        'Shutting down: disk file have been illegally tampered with!',
        'Failed to verify the file', 'In warmup mode: Stopping player.')

    $primarySet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($s in $primaryStr) { foreach ($r in (StringRvas $b $s $sections)) { [void]$primarySet.Add($r) } }
    $fallbackSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($r in $primarySet) { [void]$fallbackSet.Add($r) }
    foreach ($s in $fallbackStr) { foreach ($r in (StringRvas $b $s $sections)) { [void]$fallbackSet.Add($r) } }

    Say ("[*] anchor strings: {0} primary RVA(s), {1} total" -f $primarySet.Count, $fallbackSet.Count)

    # scan .text for  E8 ?? ?? ?? ??  84 C0  74 ??   (t = offset of TEST AL,AL)
    $textStart = $textRaw + 5
    $textEnd = $textRaw + $textRawSize - 3
    if ($textEnd -gt $b.Length - 3) { $textEnd = $b.Length - 3 }
    # match  E8.. 84 C0  74 ??  (unpatched)  OR  E8.. 84 C0  90 90  (already patched)
    $cands = New-Object System.Collections.Generic.List[int]
    # Jump to each 0x84 (TEST AL,AL opcode) with native [Array]::IndexOf bounded to .text instead
    # of stepping every byte (~82x faster). Identical candidate set: same 0x84 positions in
    # [textStart,textEnd), same CALL/TEST/JZ (and already-patched 90 90) checks at each.
    if ($textStart -lt $textEnd) {
        $t = [Array]::IndexOf($b, [byte]0x84, $textStart, $textEnd - $textStart)
        while ($t -ge 0) {
            if ($b[$t + 1] -eq 0xC0 -and $b[$t - 5] -eq 0xE8 -and
                ($b[$t + 2] -eq 0x74 -or ($b[$t + 2] -eq 0x90 -and $b[$t + 3] -eq 0x90))) {
                [void]$cands.Add($t)
            }
            if ($t + 1 -ge $textEnd) { break }
            $t = [Array]::IndexOf($b, [byte]0x84, $t + 1, $textEnd - ($t + 1))
        }
    }
    Say "[*] Found $($cands.Count) candidate site(s) (CALL; TEST AL,AL; JZ)"
    if ($cands.Count -eq 0) { Say "[!] No candidate sites. BlueStacks build differs too much -- aborting (nothing changed)." Red; return 1 }

    # select sites to patch: primary (verify/fail, tight window) first, then fallback (wider)
    $sites = New-Object System.Collections.Generic.List[int]
    $how = ''
    if ($primarySet.Count -gt 0) {
        foreach ($c in $cands) { if (NearAnchor $b $c $textVA $textRaw 0xE0 $primarySet) { [void]$sites.Add($c) } }
        if ($sites.Count -gt 0) { $how = 'verify/fail disk-integrity string' }
    }
    if ($sites.Count -eq 0 -and $fallbackSet.Count -gt 0) {
        foreach ($c in $cands) { if (NearAnchor $b $c $textVA $textRaw 0x700 $fallbackSet) { [void]$sites.Add($c) } }
        if ($sites.Count -gt 0) { $how = 'fallback anchor (plrDiskCheckThreadEntry/shutdown/per-block/warmup)' }
    }
    if ($sites.Count -eq 0) {
        if ($cands.Count -eq 1 -and $Force) { [void]$sites.Add($cands[0]); $how = 'single candidate (-Force)' }
        else {
            Say "[!] $($cands.Count) candidate(s) but none validated by an anchor string." Red
            Say "    Refusing to blind-patch (would risk corrupting HD-Player.exe). Use -Force only if you are sure." Yellow
            return 1
        }
    }

    $toApply = @(); $already = 0
    foreach ($t in $sites) {
        if ($b[$t + 2] -eq 0x90 -and $b[$t + 3] -eq 0x90) { $already++; continue }
        if ($b[$t + 2] -ne 0x74) { continue }
        $toApply += $t
    }
    foreach ($t in $sites) {
        $rva = RawToRva $t $sections
        $va = $imageBase + $rva
        Say ("    site file=0x{0:X} va=0x{1:X}  {2:X2} {3:X2} {4:X2} {5:X2}  [{6}]" -f `
                $t, $va, $b[$t], $b[$t + 1], $b[$t + 2], $b[$t + 3], $how)
    }
    if ($toApply.Count -eq 0) {
        if ($already -gt 0) { Say "[~] Already patched ($already site(s)). Nothing to do." Yellow; return 0 }
        Say "[~] Nothing to patch." Yellow; return 0
    }

    if ($DryRun) { Say "[+] Dry run -- would NOP $($toApply.Count) site(s). No file written." Yellow; return 0 }

    if (-not $NoBackup) {
        if (-not (Test-Path -LiteralPath $bak)) { Copy-BsrBackupOnce $Exe $bak; Say "[*] Backup created: $bak" }
        else { Say "[*] Backup already exists, skipping copy." }
    }
    foreach ($t in $toApply) {
        Say ("[*] Patching at 0x{0:X}: {1:X2} {2:X2} -> 90 90" -f ($t + 2), $b[$t + 2], $b[$t + 3]) Cyan
    }
    # Only 2 bytes per site change. Seek to each and write them in place instead of rewriting the
    # entire multi-hundred-MB file (WriteAllBytes). Byte-identical result; the disk write drops from
    # the whole file to (toApply * 2) bytes. ($b is intentionally not mutated -- it is discarded here.)
    try {
        $fs = [System.IO.File]::Open($Exe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { foreach ($t in $toApply) { $fs.Position = $t + 2; $fs.WriteByte(0x90); $fs.WriteByte(0x90) } }
        finally { $fs.Close() }
    }
    catch { Say "[!] Failed to write -- run as Administrator / close the emulator first." Red; return 1 }
    Say "[+] Patched successfully! ($($toApply.Count) site(s), $already already patched)" Green
    return 0
}

# ===========================================================================
#  EXT4 EDIT  --  shared debugfs logic (used by Root / Unroot / TestExt4)
# ===========================================================================
function To-DebugfsPath([string]$p) {
    # forward slashes are accepted by Win32 CreateFile and avoid debugfs backslash escaping
    return ($p -replace '\\', '/')
}

function Resolve-Debugfs {
    if ($Debugfs -and (Test-Path -LiteralPath $Debugfs)) { return (Resolve-Path -LiteralPath $Debugfs).Path }
    $c = Get-Command debugfs.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    # fall back to the debugfs bundle embedded in the .cmd itself
    $emb = Expand-EmbeddedDebugfs $SelfPath
    if ($emb) { Say "[*] using embedded debugfs (extracted from the .cmd)." ; return $emb }
    throw @"
debugfs.exe was not found and no embedded debugfs bundle is present.

The offline ext4 method needs e2fsprogs' debugfs.exe.  The single-file build
normally carries one; if you are running the raw engine, pass -Debugfs <path>
or put debugfs.exe in tools\debugfs\ (see tools\debugfs\ in the repo).
"@
}

function Run-Debugfs([string]$debugfsExe, [string]$imgPath, [string[]]$cmds, [switch]$Write) {
    $script = New-TempFile 'bsr_dfs' '.txt'
    try {
        [IO.File]::WriteAllText($script, ($cmds -join "`n"), (New-Object Text.UTF8Encoding($false)))
        $arguments = @('-f', $script, $imgPath)
        if ($Write) { $arguments = @('-w') + $arguments }
        $result = Invoke-BsrNative $debugfsExe $arguments 120
        if ($result.ExitCode) { throw "debugfs failed ($($result.ExitCode)): $($result.Output)" }
        return $result.Output
    } finally { Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue }

}

$Script:TempDirectories = New-Object System.Collections.Generic.List[string]
$Script:TempFiles = New-Object System.Collections.Generic.List[string]
function New-TempFile([string]$prefix, [string]$ext) {
    $root = Join-Path $env:TEMP 'bsr_work'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    # Separate staging files for concurrent invocations; never reuse a previous carve.
    $f = Join-Path $root ($prefix + '_' + [guid]::NewGuid().ToString('N') + $ext)
    [void]$Script:TempFiles.Add($f)
    return $f
}

# Edit a plain ext4 image: install (remove=$false) or delete (remove=$true) the su.
# Verifies the result BEFORE returning so callers can refuse to write a bad image back.
function Edit-Ext4([string]$imgPath, [bool]$remove, [byte[]]$suBytes) {
    $dfs = Resolve-Debugfs
    $imgD = To-DebugfsPath $imgPath
    Say "[*] debugfs: $dfs"

    if ($remove) {
        Run-Debugfs $dfs $imgPath @('rm /android/system/xbin/su') -Write | Out-Null
        $stat = Run-Debugfs $dfs $imgPath @('stat /android/system/xbin/su')
        if ($stat -match '/android/system/xbin/su: File not found' -and
            $stat -notmatch '(?im)Inode:\s*\d') { Say "[+] su removed from ext4." Green; return $true }
        Say "[!] su still present after removal:`n$stat" Red; return $false
    }

    # install
    $suFile = New-TempFile 'su' ''
    [System.IO.File]::WriteAllBytes($suFile, $suBytes)
    $suD = To-DebugfsPath $suFile
    # NOTE: debugfs `write <src> <dst>` does NOT traverse <dst> as a path -- it
    # creates a file in the CURRENT directory whose name is the literal <dst>
    # string.  So we `cd` into the target dir and write the bare basename, then
    # set attributes on the bare basename (relative to cwd).  mkdir on dirs that
    # already exist (real Root.vhd) just prints "File exists" and is ignored.
    $cmds = @(
        'mkdir /android',
        'mkdir /android/system',
        'mkdir /android/system/xbin',
        'cd /android/system/xbin',
        'rm su',
        "write $(ConvertTo-BsrDebugfsPath $suFile) su",
        'sif su mode 0106755',
        'sif su uid 0',
        'sif su gid 0',
        'sif su links_count 1'
    )
    Run-Debugfs $dfs $imgPath $cmds -Write | Out-Null
    $stat = Run-Debugfs $dfs $imgPath @('stat /android/system/xbin/su')
    Remove-Item -LiteralPath $suFile -Force -ErrorAction SilentlyContinue
    Say "[*] verify:`n$stat"
    if (-not (Test-BsrDebugfsFile $stat '/android/system/xbin/su' $suBytes.Length 0xDED)) {
        Say '[!] su length, mode or ownership does not match. Not trusting this image.' Red; return $false
    }
    Say "[+] su installed: /android/system/xbin/su  mode 06755 (setuid root)  owner 0:0" Green
    return $true
}

# ===========================================================================
#  ROOT / UNROOT  --  attach Root.vhd, locate ext4, carve, edit, write back
# ===========================================================================
function Read-DeviceBytes([string]$device, [long]$offset, [int]$count) {
    return ,(Read-BsrDeviceBytes $device $offset $count)
}

function Copy-DeviceToFile([string]$device, [long]$start, [long]$length, [string]$outFile) {
    Copy-BsrDiskRegion $device $start $length $outFile
}

function Copy-FileToDevice([string]$inFile, [string]$device, [long]$start, [long]$length=0) {
    Write-BsrDiskRegion $inFile $device $start $length
}

function Invoke-VhdSu([bool]$remove) {
    if (-not $Vhd) { throw "Root/Unroot requires -Vhd <Root.vhd>." }
    if (-not (Test-Path -LiteralPath $Vhd)) { throw "Root.vhd not found: $Vhd" }
    $dfs = Resolve-Debugfs    # fail fast before we attach anything

    $suBytes = $null
    if (-not $remove) { $suBytes = Get-EmbeddedSu $SelfPath; Say "[*] Embedded su OK ($($suBytes.Length) bytes, sha256 verified)." Green }

    # optional safety backup of the whole Root.vhd (once)
    if (-not $remove -and -not $NoBackup) {
        $vbak = "$Vhd.bsrbak"
        if (-not (Test-Path -LiteralPath $vbak)) {
            try {
                $sz = (Get-Item -LiteralPath $Vhd).Length
                $drive = (Get-Item -LiteralPath $Vhd).PSDrive
                $free = (Get-PSDrive -Name $drive.Name).Free
                if ($free -gt ($sz * 1.1)) {
                    Say "[*] Backing up Root.vhd -> $vbak (one-time safety copy, $([math]::Round($sz/1GB,2)) GB)..."
                    Copy-BsrBackupOnce $Vhd $vbak
                    Say "[*] Backup done." Green
                }
                else { Say "[~] Not enough free space for a Root.vhd backup -- proceeding without one (NoRoot copy is your fallback)." Yellow }
            }
            catch { Say "[~] Could not create Root.vhd backup: $($_.Exception.Message)" Yellow }
        }
        else { Say "[*] Root.vhd backup already exists: $vbak" }
    }

    $attached = $false
    try {
        Say "[*] Attaching $Vhd (read/write)..."
        $mounted = Mount-BsrDisk $Vhd
        $attached = $true
        $dn = $null
        for ($try = 0; $try -lt 20; $try++) {
            $di = Get-DiskImage -ImagePath $Vhd -StorageType $mounted.StorageType -ErrorAction SilentlyContinue
            if ($di -and $di.Number -ne $null) { $dn = $di.Number; break }
            Start-Sleep -Milliseconds 250
        }
        if ($null -eq $dn) {
            $disk = Get-DiskImage -ImagePath $Vhd -StorageType $mounted.StorageType | Get-Disk -ErrorAction SilentlyContinue
            if ($disk) { $dn = $disk.Number }
        }
        if ($null -eq $dn) { throw "Could not determine the disk number of the attached VHD." }
        $physical = "\\.\PhysicalDrive$dn"
        Say "[*] Attached as disk $dn ($physical)."

        $tgt = Get-Ext4Target $dn $physical
        if ($null -eq $tgt) { throw "No ext4 partition (0xEF53 @ +0x438) found inside $Vhd." }
        Say ("[*] ext4 found: device={0} partOffset=0x{1:X} size={2} bytes" -f $tgt.Device, $tgt.Offset, $tgt.Length)

        $img = New-TempFile 'ext4' '.img'
        Say "[*] Carving ext4 region to $img ..."
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img

        $ok = Edit-Ext4 $img $remove $suBytes
        if (-not $ok) {
            Say "[!] ext4 edit/verify failed -- NOT writing anything back. Root.vhd is unchanged." Red
            return 1
        }

        Say "[*] Writing the modified ext4 region back into the VHD ..."
        Copy-FileToDevice $img $tgt.Device $tgt.Start $tgt.Length
        Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
        if ($remove) { Say "[+] Unrooted successfully! (su removed from Root.vhd)" Green }
        else { Say "[+] Rooted successfully! (su installed into Root.vhd)" Green }
        return 0
    }
    finally {
        if ($attached) {
            try { Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null; Say "[*] Detached $Vhd." }
            catch { throw "Failed to detach $Vhd -- detach it manually (Disk Management) before launching BlueStacks. $($_.Exception.Message)" }
        }
    }
}

# ===========================================================================
#  .bstk disk mode  --  faithful global regex_replace (derivation Â§4)
# ===========================================================================
function Backup-Once([string]$path) {
    $bak = "$path.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
        try { attrib -R $path 2>$null | Out-Null } catch { }
        Copy-BsrBackupOnce $path $bak
        Say "[*] Backup: $bak"
    }
}

function Invoke-Bstk([bool]$toReadonly) {
    if (-not $Bstk) { throw "DiskRW/DiskRO requires -Bstk <instance.bstk>." }
    if (-not (Test-Path -LiteralPath $Bstk)) { throw ".bstk not found: $Bstk" }
    $raw = [System.IO.File]::ReadAllText($Bstk)
    # guard exactly like the exe: only touch files that describe the BlueStacks disks
    if ($raw -notmatch 'location="fastboot\.vdi"' -and $raw -notmatch 'location="Root\.vhd"') {
        Say "[~] $Bstk does not look like a BlueStacks instance disk file -- leaving it untouched." Yellow
        return 1
    }
    Backup-Once $Bstk
    if ($toReadonly) { $new = $raw -replace 'type="Normal"', 'type="Readonly"' }     # R/O
    else { $new = $raw -replace 'type="Readonly"', 'type="Normal"' }   # R/W (case-insensitive: also matches ReadOnly)
    if ($new -eq $raw) { Say "[~] .bstk disk mode already set; no change." Yellow; return 0 }
    try { attrib -R $Bstk 2>$null | Out-Null } catch { }
    Write-BsrTextFile $Bstk $new
    if ($toReadonly) { Say "[+] Disk reverted to Readonly." Green } else { Say "[+] Disk set to R/W." Green }
    return 0
}

# ===========================================================================
#  bluestacks.conf root flags  (hybrid Â§6a -- works with Magisk + adb)
# ===========================================================================
# Modify an EXISTING key only.  Returns $true if found+set, $false if absent.
# We deliberately do NOT add missing keys: BlueStacks 5.22.x validates every conf
# property against its internal "iprop" schema and aborts with
#   "prop not found in iprop dir" / "FATAL: configuration init failed"
# if it sees an unknown key.  Adding one (e.g. bst.instance.<x>.enable_adb_access,
# which is not a valid key on this build) bricks startup.
function Set-ConfKey([System.Collections.Generic.List[string]]$lines, [string]$key, [string]$val) {
    $re = '^\s*' + [regex]::Escape($key) + '\s*='
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $re) { $lines[$i] = "$key=`"$val`""; $done = $true }
    }
    return $done
}

function Invoke-Conf([bool]$enable) {
    if (-not $Conf) { throw "ConfRoot/ConfUnroot requires -Conf <bluestacks.conf>." }
    if (-not $Instance) { throw "ConfRoot/ConfUnroot requires -Instance <name>." }
    if (-not (Test-Path -LiteralPath $Conf)) { throw "bluestacks.conf not found: $Conf" }
    Backup-Once $Conf
    $val = if ($enable) { '1' } else { '0' }
    try { attrib -R $Conf 2>$null | Out-Null } catch { }
    $values = [ordered]@{}
    $values["bst.instance.$Instance.enable_root_access"] = $val
    $values['bst.feature.rooting'] = $val
    $values['bst.enable_adb_access'] = $val
    $missing = @(Set-BsrConfValues $Conf $values)
    if ($missing.Count) { Say "[~] conf keys absent, left as-is: $($missing -join ', ')" Yellow }
    Say "[+] bluestacks.conf updated for '$Instance' (root flags = `"$val`", UTF-8 no BOM)." Green
    return 0
}

# ===========================================================================
#  VhdSelfTest  --  exercise the dangerous disk path (attach -> ext4 detect ->
#  carve -> write the SAME bytes back -> detach) on a throwaway VHD and prove
#  the region is byte-identical afterwards.  No debugfs, no su -- pure disk I/O.
# ===========================================================================
function Invoke-VhdSelfTest {
    if (-not $Vhd) { throw "VhdSelfTest requires -Vhd." }
    if (-not (Test-Path -LiteralPath $Vhd)) { throw "VHD not found: $Vhd" }
    $attached = $false
    try {
        $mounted = Mount-BsrDisk $Vhd
        $attached = $true
        $dn = $null
        for ($t = 0; $t -lt 20; $t++) { $di = Get-DiskImage -ImagePath $Vhd -StorageType $mounted.StorageType -EA SilentlyContinue; if ($di -and $di.Number -ne $null) { $dn = $di.Number; break }; Start-Sleep -Milliseconds 250 }
        if ($null -eq $dn) { throw "no disk number" }
        $physical = "\\.\PhysicalDrive$dn"
        $tgt = Get-Ext4Target $dn $physical
        if ($null -eq $tgt) { Say "[!] ext4 region not detected." Red; return 1 }
        Say ("[*] region: device={0} start=0x{1:X} len={2}" -f $tgt.Device, $tgt.Start, $tgt.Length)
        $img1 = New-TempFile 'st1' '.img'; $img2 = New-TempFile 'st2' '.img'
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img1
        $h1 = Get-BsrFileHash $img1
        Copy-FileToDevice $img1 $tgt.Device $tgt.Start $tgt.Length
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img2
        $h2 = Get-BsrFileHash $img2
        Remove-Item $img1, $img2 -Force -EA SilentlyContinue
        if ($h1 -eq $h2) { Say "[+] carve/write-back is byte-identical (sha256 $($h1.Substring(0,16))...)." Green; return 0 }
        Say "[!] MISMATCH after write-back: $h1 vs $h2" Red; return 1
    }
    finally { if ($attached) { Dismount-DiskImage -InputObject $mounted -EA Stop | Out-Null } }
}

# ===========================================================================
#  Resolve  --  discover instance / master / .bstk / conf / Root.vhd paths.
#  Emits ONLY  KEY=VALUE  lines on stdout (so a .cmd `for /f` can `set` them).
#  NOTE: must never Write-Host here -- it would pollute the captured output.
# ===========================================================================
# Normalize to the folder that actually owns bluestacks.conf. Inputs may point at the conf itself,
# the data root, Engine\, an instance below Engine\, or the install folder selected through option 8.
function Get-BaseDir([string]$dataDir, [string]$userDef, [string]$custom = $CustomPath,
                     [string]$preferredInstall = $InstallDir) {
    $customData = Get-DataRootFromPath $custom
    if ($customData) { return $customData }
    $customInstall = Get-InstallRootFromPath $custom
    if ($custom -and -not $customInstall) {
        throw "The saved custom folder is neither a BlueStacks install folder (HD-Player.exe + HD-Adb.exe) nor a data folder (bluestacks.conf). Use option 8 to replace it."
    }

    $records = @(Get-RegBlueStacksRecords)
    $wantedInstall = if ($customInstall) { $customInstall } else { Get-InstallRootFromPath $preferredInstall }
    if ($wantedInstall) {
        foreach ($record in $records) {
            $recordInstall = Get-InstallRootFromPath $record.InstallDir
            if ($recordInstall -and (Test-SamePath $recordInstall $wantedInstall)) {
                $recordData = Get-RecordDataRoot $record
                if ($recordData) { return $recordData }
            }
        }
    }

    foreach ($candidate in @($dataDir, $userDef)) {
        $root = Get-DataRootFromPath $candidate
        if ($root) { return $root }
    }
    foreach ($record in $records) {
        $root = Get-RecordDataRoot $record
        if ($root) { return $root }
    }
    throw "BlueStacks data folder was not found. Registry records contained no valid bluestacks.conf. Use option 8 to select the data folder or its bluestacks.conf."
}

function Invoke-Resolve {
    if (-not $Base) { throw "Resolve requires -Base (or BSR_BASE)." }
    $DataDir = Get-BaseDir $DataDir $UserDef $CustomPath $InstallDir
    $resolvedInstall = Resolve-InstallRoot $InstallDir $CustomPath $DataDir
    $requestedInstance = $Instance
    $instance = $null
    $rx = '^' + [regex]::Escape($Base) + '(_\d+)?$'

    # 1) candidates from MimMetaData.json
    $cands = @()
    $mim = Join-Path $DataDir 'Engine\UserData\MimMetaData.json'
    if (-not (Test-Path -LiteralPath $mim)) { $mim = Join-Path $DataDir 'UserData\MimMetaData.json' }
    if (Test-Path -LiteralPath $mim) {
        try {
            $m = Select-String -LiteralPath $mim -Pattern '"InstanceName"\s*:\s*"([^"]+)"' -AllMatches
            $cands = @($m.Matches | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match $rx } | Sort-Object -Unique)
        }
        catch { }
    }
    # 2) the most-recently-launched instance from Player.log (matches the per-instance UX)
    $log = Join-Path $DataDir 'Logs\Player.log'
    if (Test-Path -LiteralPath $log) {
        try {
            $tail = Get-Content -LiteralPath $log -Tail 6000 -ErrorAction SilentlyContinue
            $hit = $tail | Select-String -Pattern ('(?<![A-Za-z0-9_])' + [regex]::Escape($Base) + '(_\d+)?(?![A-Za-z0-9_])') -AllMatches |
                ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
                Where-Object { $_ -match $rx } | Select-Object -Last 1
            if ($hit) { $instance = $hit }
        }
        catch { }
    }
    # Prefer an instance whose .bstk actually EXISTS on disk -- Player.log may name a
    # since-deleted clone (e.g. Rvc64_2).  Order: log-most-recent, newest MimMetaData
    # candidates, then the bare base.  Fall back to the log/candidate name if none exist
    # (so the orchestrator can print a helpful "launch it once" message).
    $pref = New-Object System.Collections.Generic.List[string]
    if ($instance) { [void]$pref.Add($instance) }
    for ($k = $cands.Count - 1; $k -ge 0; $k--) { if ($cands[$k]) { [void]$pref.Add($cands[$k]) } }
    [void]$pref.Add($Base)
    $chosen = $null
    foreach ($cand in $pref) {
        if (-not $cand) { continue }
        if (Test-Path -LiteralPath (Join-Path $DataDir "Engine\$cand\$cand.bstk")) { $chosen = $cand; break }
    }
    if (-not $chosen) { $chosen = if ($instance) { $instance } elseif ($cands.Count -ge 1) { $cands[-1] } else { $Base } }
    if ($requestedInstance) {
        if ($requestedInstance -notmatch $rx) { throw "Instance '$requestedInstance' does not belong to '$Base'." }
        $chosen = $requestedInstance
    }
    $instance = $chosen

    # master = instance with a trailing _<n> stripped (clones share the master's Root.vhd)
    $master = if ($instance -match '^(.+)_\d+$') { $Matches[1] } else { $instance }

    $bstk = Join-Path $DataDir "Engine\$instance\$instance.bstk"
    $conf = Join-Path $DataDir 'bluestacks.conf'

    # Root.vhd: prefer the location declared in the .bstk; else master folder; else instance folder
    $vhd = $null
    if (Test-Path -LiteralPath $bstk) {
        try {
            $bt = [System.IO.File]::ReadAllText($bstk)
            $mm = [regex]::Match($bt, 'location="([^"]*[Rr]oot\.vhd)"')
            if ($mm.Success) {
                $loc = $mm.Groups[1].Value
                if ([System.IO.Path]::IsPathRooted($loc)) { $cand = $loc }
                else { $cand = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $bstk) $loc)) }
                if (Test-Path -LiteralPath $cand) { $vhd = $cand }
            }
        }
        catch { }
    }
    if (-not $vhd) {
        $cm = Join-Path $DataDir "Engine\$master\Root.vhd"
        $ci = Join-Path $DataDir "Engine\$instance\Root.vhd"
        if (Test-Path -LiteralPath $cm) { $vhd = $cm }
        elseif (Test-Path -LiteralPath $ci) { $vhd = $ci }
        else { $vhd = $cm }   # report the most-likely path even if missing
    }

    # instance adb port (for the online/adb root path); default 5555
    $adbPort = '5555'
    if (Test-Path -LiteralPath $conf) {
        try {
            $ct = [System.IO.File]::ReadAllText($conf)
            $esc = [regex]::Escape($instance)
            $pm = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.status\.adb_port\s*=\s*"?(\d+)"?')
            if (-not $pm.Success) { $pm = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.adb_port\s*=\s*"?(\d+)"?') }
            if ($pm.Success) { $adbPort = $pm.Groups[1].Value }
        }
        catch { }
    }

    Write-Output "BSR_DATADIR=$DataDir"
    Write-Output "BSR_INSTALL=$resolvedInstall"
    Write-Output "BSR_INSTANCE=$instance"
    Write-Output "BSR_MASTER=$master"
    Write-Output "BSR_BSTK=$bstk"
    Write-Output "BSR_CONF=$conf"
    Write-Output "BSR_VHD=$vhd"
    Write-Output "BSR_ADBPORT=$adbPort"
}

# ===========================================================================
#  ONLINE ROOT via BlueStacks' own adb (HD-Adb.exe)  --  PRIMARY path.
#
#  Once the disk is Normal + root/adb flags on + integrity bypassed, we boot the
#  instance and let ANDROID'S OWN KERNEL write its ext4: push the embedded su and
#  drop it into /system using BlueStacks' native su, then prove uid=0.  No Windows
#  ext4 tooling, no debugfs -- inherently version-proof.  Offline debugfs is the
#  fallback (Invoke-VhdSu) when the instance can't boot/root.
# ===========================================================================
function Resolve-Adb {
    if ($Adb -and (Test-Path -LiteralPath $Adb)) { return (Resolve-Path -LiteralPath $Adb).Path }
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-RuntimeInstallRoots)) { [void]$cands.Add((Join-Path $root 'HD-Adb.exe')) }
    foreach ($reg in @(Get-RegBlueStacksRecords)) {
        $root = Get-InstallRootFromPath $reg.InstallDir
        if ($root) { [void]$cands.Add((Join-Path $root 'HD-Adb.exe')) }
    }
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    $c = Get-Command 'HD-Adb.exe' -EA SilentlyContinue
    if ($c) { return $c.Source }
    throw "HD-Adb.exe not found. Pass -Adb <path to HD-Adb.exe> (or BSR_ADB)."
}

$Script:AdbExe = $null
$Script:Serial = $null

function AdbRaw([string[]]$a) {
    $result = Invoke-BsrNative $Script:AdbExe $a 30
    $script:LastAdbExitCode = $result.ExitCode
    return $result.Output
}
function AdbS([string[]]$a) { return AdbRaw (@('-s', $Script:Serial) + $a) }
function AdbShell([string]$cmd) { return AdbS @('shell', $cmd) }

# Map listening ports in our private band to 'ours' (a reusable HD-Adb.exe server) or 'other' (a non-adb
# app, or a foreign-version adb we must not fight). Absent = free. (Mirrors tools\bsr_magisk.ps1.)
function Get-AdbServerPortState { Get-BsrAdbServerPortState $Script:AdbExe }
function Resolve-AdbServerPort { Select-BsrAdbServerPort (Get-AdbServerPortState) }

# Connect to the instance's adb endpoint and wait until Android finishes booting.
function Connect-WaitBoot([int]$timeoutSec) {
    $port = if ($AdbPort) { $AdbPort } else { '5555' }
    $Script:Serial = "127.0.0.1:$port"
    # Isolate HD-Adb on its own server port so a different-version system adb (e.g. Android SDK
    # platform-tools) on the default 5037 can't kill our server mid-run (the version-mismatch churn
    # that makes getprop/shell calls fail and a booted instance look "not adb-reachable").
    $env:ANDROID_ADB_SERVER_PORT = Resolve-AdbServerPort
    AdbRaw @('start-server') | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $connected = $false
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $c = AdbRaw @('connect', $Script:Serial)
        if ($c -match '(?i)connected to') { $connected = $true }
        # A different online device is never evidence that the requested instance booted.
        $log = if ($Conf) { Join-Path (Split-Path -Parent $Conf) 'Logs\Player.log' } else { $null }
        $ids = @(Get-BsrInstanceProcesses $Instance $log | Select-Object -ExpandProperty Id)
        $owned = @(Get-BsrTcpListeners | Where-Object { $_.LocalPort -eq [int]$port -and $ids -contains $_.OwningProcess })
        $connected = $connected -and $owned.Count -gt 0
        if ($connected) {
            $b = (AdbShell 'getprop sys.boot_completed').Trim()
            if ($b -eq '1') {
                # give late services (su daemon) a moment
                Start-Sleep -Seconds 3
                return $true
            }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Get-HdPlayerInstanceCount([string]$name) {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -ErrorAction Stop |
            Where-Object { Test-HdPlayerInstance $_.CommandLine $name }).Count
    } catch {
        return 0
    }
}

function Launch-Instance {
    if ($NoLaunch) { Say "[*] -NoLaunch: assuming the instance is already running." ; return }
    if (-not $Player -or -not (Test-Path -LiteralPath $Player)) { Say "[~] HD-Player.exe not provided; not launching (will try to connect anyway)." Yellow; return }
    if (-not $Instance) { throw "AdbRoot requires -Instance to launch." }
    $running = Get-HdPlayerInstanceCount $Instance
    if ($running -gt 0) { Say "[*] HD-Player for '$Instance' already running; not launching a second copy." ; return }
    Say "[*] Booting instance '$Instance' ..."
    Start-BsrPlayer $Player $Instance | Out-Null
}

# Run a privileged shell script (pushed to the device) as root, trying the su
# styles BlueStacks may expose.  Returns the combined output; sets $ok if uid=0.
function Run-AsRoot([string]$deviceScript) {
    # opportunistically promote adbd (harmless if unsupported)
    AdbS @('root') | Out-Null
    Start-Sleep -Seconds 1
    Connect-WaitBoot 30 | Out-Null
    $variants = @("su -c 'sh $deviceScript'", "su 0 sh $deviceScript", "su root -c 'sh $deviceScript'", "sh $deviceScript")
    $best = ''
    foreach ($v in $variants) {
        $o = AdbShell $v
        $best = $o
        if ($o -match 'BSR_ROOT_OK') { return $o }
    }
    return $best
}

function Invoke-AdbSu([bool]$remove) {
    if (-not $Instance) { throw "AdbRoot/AdbUnroot requires -Instance." }
    $Script:AdbExe = Resolve-Adb
    Say "[*] adb: $($Script:AdbExe)"

    $suBytes = $null
    if (-not $remove) { $suBytes = Get-EmbeddedSu $SelfPath; Say "[*] Embedded su OK ($($suBytes.Length) bytes, sha256 verified)." Green }

    Launch-Instance
    Say "[*] Waiting for the instance to finish booting (adb 127.0.0.1:$(if($AdbPort){$AdbPort}else{'5555'})) ..."
    if (-not (Connect-WaitBoot 240)) {
        Say "[!] Instance did not become adb-reachable / booted in time." Red
        return 2   # signal: caller may fall back to offline debugfs
    }
    Say "[+] Booted. serial=$($Script:Serial)" Green

    # stage a device-side script (avoids all the su/sh quoting pitfalls)
    $work = Join-Path (Join-Path $env:TEMP 'bsr_work') 'adb'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $sh = Join-Path $work 'bsrdo.sh'

    if ($remove) {
        $body = @'
mount -o rw,remount / 2>/dev/null
mount -o rw,remount /system 2>/dev/null
mount -o rw,remount /system_root 2>/dev/null
rm -f /system/xbin/su /system/bin/su 2>/dev/null
sync
if [ ! -e /system/xbin/su ] && [ ! -e /system/bin/su ]; then echo BSR_ROOT_OK_REMOVED; fi
'@
    }
    else {
        $body = @'
mount -o rw,remount / 2>/dev/null
mount -o rw,remount /system 2>/dev/null
mount -o rw,remount /system_root 2>/dev/null
T=""
for d in /system/xbin /system/bin; do
  if [ -d "$d" ]; then
    cp /data/local/tmp/bsrsu "$d/su" && chmod 06755 "$d/su" && { chown 0:0 "$d/su" 2>/dev/null || chown 0.0 "$d/su"; } && T="$d/su"
  fi
done
sync
ls -l $T 2>/dev/null
if [ -n "$T" ]; then echo BSR_ROOT_OK_INSTALLED $T; fi
'@
    }
    # LF line-endings for the device shell
    [System.IO.File]::WriteAllText($sh, ($body -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    AdbS @('push', $sh, '/data/local/tmp/bsrdo.sh') | Out-Null

    if (-not $remove) {
        $suTmp = Join-Path $work 'bsrsu'
        [System.IO.File]::WriteAllBytes($suTmp, $suBytes)
        AdbS @('push', $suTmp, '/data/local/tmp/bsrsu') | Out-Null
        Remove-Item -LiteralPath $suTmp -Force -EA SilentlyContinue
    }

    $out = Run-AsRoot '/data/local/tmp/bsrdo.sh'
    AdbShell 'rm -f /data/local/tmp/bsrdo.sh /data/local/tmp/bsrsu' | Out-Null

    if ($remove) {
        if ($out -match 'BSR_ROOT_OK_REMOVED') { Say "[+] su removed from /system via adb." Green; return 0 }
        Say "[!] Could not confirm su removal via adb.`n$out" Red; return 1
    }

    if ($out -notmatch 'BSR_ROOT_OK_INSTALLED') {
        Say "[!] su install via adb did not confirm (need BlueStacks root/su enabled).`n$out" Red
        return 2   # let caller fall back to offline
    }
    Say "[*] su written:`n$out"
    # final proof: a NON-root adb shell calling our setuid su must come back uid=0
    $idOut = AdbShell '/system/xbin/su -c id 2>/dev/null || /system/bin/su -c id 2>/dev/null'
    if ($idOut -match 'uid=0') { Say "[+] Rooted online! /system/.../su grants uid=0:`n$idOut" Green; return 0 }
    Say "[~] su is in place but 'su -c id' did not report uid=0 (SELinux?). Output:`n$idOut" Yellow
    return 0   # file is installed; Magisk's system install can still proceed
}

function Invoke-AdbVerify {
    if (-not $Instance) { throw "AdbVerify requires -Instance." }
    $Script:AdbExe = Resolve-Adb
    if (-not (Connect-WaitBoot 240)) { Say "[!] not reachable/booted." Red; return 1 }
    $id = AdbShell '/system/xbin/su -c id 2>/dev/null || /system/bin/su -c id 2>/dev/null'
    $ls = AdbShell 'ls -l /system/xbin/su /system/bin/su 2>/dev/null'
    $mg = AdbShell 'magisk -V 2>/dev/null; magisk -c 2>/dev/null'
    Say "su id : $($id.Trim())"
    Say "su ls : $($ls.Trim())"
    Say "magisk: $($mg.Trim())"
    if ($id -match 'uid=0') { Say "[+] root verified (uid=0)." Green; return 0 }
    Say "[!] root NOT verified." Red; return 1
}

# ===========================================================================
#  dispatch
# ===========================================================================
try {
    switch ($Action) {
        'ExtractSu' {
            if (-not $OutFile) { throw "ExtractSu requires -OutFile." }
            $bytes = Get-EmbeddedSu $SelfPath
            [System.IO.File]::WriteAllBytes($OutFile, $bytes)
            Say "[+] su extracted to $OutFile ($($bytes.Length) bytes, sha256 verified)." Green
            exit 0
        }
        'TestExt4' {
            if (-not $Img) { throw "TestExt4 requires -Img <ext4 image>." }
            $suBytes = $null
            if (-not $Restore) { $suBytes = Get-EmbeddedSu $SelfPath }   # -Restore here means 'remove'
            $ok = Edit-Ext4 $Img ([bool]$Restore) $suBytes
            exit ([int](-not $ok))
        }
        'Patch' { exit (Invoke-Patch) }
        'Root' { exit (Invoke-VhdSu $false) }
        'Unroot' { exit (Invoke-VhdSu $true) }
        'AdbRoot' { exit (Invoke-AdbSu $false) }
        'AdbUnroot' { exit (Invoke-AdbSu $true) }
        'AdbVerify' { exit (Invoke-AdbVerify) }
        'DiskRW' { exit (Invoke-Bstk $false) }
        'DiskRO' { exit (Invoke-Bstk $true) }
        'ConfRoot' { exit (Invoke-Conf $true) }
        'ConfUnroot' { exit (Invoke-Conf $false) }
        'Resolve' { Invoke-Resolve; exit 0 }
        'BaseDir' { Write-Output (Get-BaseDir $DataDir $UserDef $CustomPath $InstallDir); exit 0 }
        'VhdSelfTest' { exit (Invoke-VhdSelfTest) }
    }
} catch {
    Say "[!] $($_.Exception.Message)" Red
    exit 1
} finally {
    foreach ($directory in $Script:TempDirectories) {
        $parent=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'bsr_work')).TrimEnd('\')+'\'
        $resolved=[IO.Path]::GetFullPath($directory)
        if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved) -match '^engine_[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($temporary in $Script:TempFiles) {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}
