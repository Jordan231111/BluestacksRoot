<#
  bsr_engine.ps1  --  blueStackRoot engine

  Pure-PowerShell, faithful re-implementation of the heavy lifting performed by
  BstkRooter.exe (Taaauu "BSTK Rooter" 1.0.1), derived byte-for-byte from
  recovered/BstkRooter/BstkRooter_FULL_DERIVATION.md.

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

  NOTHING here depends on BstkRooter.exe.  The su payload travels inside the .cmd.
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
$Base = EnvOr $Base 'BSR_BASE'
$Adb = EnvOr $Adb 'BSR_ADB'
$Player = EnvOr $Player 'BSR_PLAYER'
$AdbPort = EnvOr $AdbPort 'BSR_ADBPORT'
if (-not $Restore -and $env:BSR_RESTORE -eq '1') { $Restore = $true }
if (-not $NoBackup -and $env:BSR_NOBACKUP -eq '1') { $NoBackup = $true }
if (-not $NoLaunch -and $env:BSR_NOLAUNCH -eq '1') { $NoLaunch = $true }
if (-not $Force -and $env:BSR_FORCE -eq '1') { $Force = $true }

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# Registry discovery (NO hardcoded install/data paths): honour a custom BlueStacks location by reading
# InstallDir/DataDir/UserDefinedDir from the registry -- nxt (BlueStacks 5) then msi5 (MSI App Player),
# native and WOW6432Node views.  Must not Write-Host (callers like Resolve/BaseDir parse stdout).
function Get-RegBlueStacks {
    foreach ($k in @('HKLM:\SOFTWARE\BlueStacks_nxt', 'HKLM:\SOFTWARE\BlueStacks_msi5',
                     'HKLM:\SOFTWARE\WOW6432Node\BlueStacks_nxt', 'HKLM:\SOFTWARE\WOW6432Node\BlueStacks_msi5')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p -and ($p.InstallDir -or $p.DataDir -or $p.UserDefinedDir)) {
                return [pscustomobject]@{ InstallDir = $p.InstallDir; DataDir = $p.DataDir; UserDefinedDir = $p.UserDefinedDir }
            }
        } catch { }
    }
    return $null
}

# Expected SHA-256 of the decrypted su ELF (derivation §1).  Used as an integrity gate.
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
    $text = [System.IO.File]::ReadAllText($selfPath)
    $beg = '__BSR_SU_' + 'BEGIN__'
    $end = '__BSR_SU_' + 'END__'
    $i = $text.IndexOf($beg)
    $j = $text.IndexOf($end)
    if ($i -lt 0 -or $j -lt 0 -or $j -le $i) { throw "su payload markers not found in '$selfPath'." }
    $i += $beg.Length
    $b64 = $text.Substring($i, $j - $i)
    # strip all whitespace (line wraps, CR/LF, the marker's own EOL)
    $b64 = ($b64 -replace '[^A-Za-z0-9+/=]', '')
    if ($b64.Length -lt 64) { throw "su payload is empty -- run tools/embed-su.ps1 to populate it." }
    $gz = [Convert]::FromBase64String($b64)
    # gunzip via .NET GZipStream (matches the .NET GZipStream used to compress)
    $in = New-Object System.IO.MemoryStream(, $gz)
    $z = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    while (($n = $z.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
    $z.Close(); $in.Close()
    $bytes = $out.ToArray(); $out.Close()
    # integrity gate
    $sha = (Get-Sha256Hex $bytes)
    if ($sha -ne $Script:SuSha256) {
        throw "Embedded su FAILED integrity check.`n  expected $($Script:SuSha256)`n  got      $sha"
    }
    return $bytes
}

function Get-Sha256Hex([byte[]]$bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return (($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join '') }
    finally { $h.Dispose() }
}

# ---------------------------------------------------------------------------
# Embedded debugfs bundle (offline fallback) -- a base64'd .zip of the Cygwin
# debugfs.exe + its 10 DLLs, carried inside the .cmd between __BSR_DFS_* lines.
# Extracted once to %TEMP%\bsr_work\debugfs\ and reused.  Returns debugfs.exe
# path, or $null if no bundle is embedded.
# ---------------------------------------------------------------------------
function Expand-EmbeddedDebugfs([string]$selfPath) {
    $destDir = Join-Path (Join-Path $env:TEMP 'bsr_work') 'debugfs'
    $exe = Join-Path $destDir 'debugfs.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }   # already extracted this session
    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath)) { return $null }
    $text = [System.IO.File]::ReadAllText($selfPath)
    $beg = '__BSR_DFS_' + 'BEGIN__'; $end = '__BSR_DFS_' + 'END__'
    $i = $text.IndexOf($beg); $j = $text.IndexOf($end)
    if ($i -lt 0 -or $j -le $i) { return $null }   # no bundle embedded
    $i += $beg.Length
    $b64 = ($text.Substring($i, $j - $i) -replace '[^A-Za-z0-9+/=]', '')
    if ($b64.Length -lt 1024) { return $null }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $zipPath = Join-Path $destDir '_dfs.zip'
    [System.IO.File]::WriteAllBytes($zipPath, [Convert]::FromBase64String($b64))
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
    $za = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($e in $za.Entries) {
            if (-not $e.Name) { continue }   # directory entry
            $t = Join-Path $destDir $e.FullName
            $d = Split-Path -Parent $t
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
        }
    }
    finally { $za.Dispose() }
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
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
    for ($i = 0; $i -le $max; $i++) {
        if ($b[$i] -ne $needle[0]) { continue }
        $ok = $true
        for ($k = 1; $k -lt $needle.Length; $k++) { if ($b[$i + $k] -ne $needle[$k]) { $ok = $false; break } }
        if ($ok -and $b[$i + $needle.Length] -eq 0) {
            $rva = RawToRva $i $sections
            if ($rva -ge 0) { [void]$hits.Add($rva) }
        }
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
        Copy-Item -LiteralPath $bak -Destination $Exe -Force
        Say "[+] Restored $Exe from $bak" Green
        return 0
    }

    $b = [System.IO.File]::ReadAllBytes($Exe)
    Say "[*] Loaded $Exe ($($b.Length) bytes)"
    if ($b.Length -lt 0x200) { Say "[!] File too small for a PE." Red; return 1 }

    $e_lfanew = [BitConverter]::ToInt32($b, 0x3C)
    if ($e_lfanew -le 0 -or $e_lfanew + 0x40 -ge $b.Length -or $b[$e_lfanew] -ne 0x50 -or $b[$e_lfanew + 1] -ne 0x45) {
        Say "[!] Invalid PE header." Red; return 1
    }
    $numSections = [BitConverter]::ToUInt16($b, $e_lfanew + 6)
    $sizeOptHdr = [BitConverter]::ToUInt16($b, $e_lfanew + 20)
    $optHdr = $e_lfanew + 24
    $magic = [BitConverter]::ToUInt16($b, $optHdr)
    if ($magic -eq 0x20B) { $imageBase = [BitConverter]::ToUInt64($b, $optHdr + 24) }
    else { $imageBase = [BitConverter]::ToUInt32($b, $optHdr + 28) }

    $secTable = $optHdr + $sizeOptHdr
    $textRaw = $null; $textRawSize = $null; $textVA = $null
    $sections = @()
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secTable + ($i * 40)
        $name = ([System.Text.Encoding]::ASCII.GetString($b, $s, 8)).TrimEnd([char]0)
        $va = [BitConverter]::ToUInt32($b, $s + 12)
        $rs = [BitConverter]::ToUInt32($b, $s + 16)
        $pr = [BitConverter]::ToUInt32($b, $s + 20)
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
    for ($t = $textStart; $t -lt $textEnd; $t++) {
        if ($b[$t] -eq 0x84 -and $b[$t + 1] -eq 0xC0 -and $b[$t - 5] -eq 0xE8 -and
            ($b[$t + 2] -eq 0x74 -or ($b[$t + 2] -eq 0x90 -and $b[$t + 3] -eq 0x90))) {
            [void]$cands.Add($t)
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
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Exe -Destination $bak -Force; Say "[*] Backup created: $bak" }
        else { Say "[*] Backup already exists, skipping copy." }
    }
    foreach ($t in $toApply) {
        Say ("[*] Patching at 0x{0:X}: {1:X2} {2:X2} -> 90 90" -f ($t + 2), $b[$t + 2], $b[$t + 3]) Cyan
        $b[$t + 2] = 0x90; $b[$t + 3] = 0x90
    }
    try { [System.IO.File]::WriteAllBytes($Exe, $b) }
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
    Set-Content -LiteralPath $script -Value ($cmds -join "`n") -Encoding ascii -NoNewline
    $args = @()
    if ($Write) { $args += '-w' }
    $args += @('-f', $script, $imgPath)
    # debugfs prints its version banner (and many notices) to stderr on EVERY run.
    # Under ErrorActionPreference=Stop those stderr lines become terminating errors,
    # so drop to Continue for the native call and fold stderr into the captured text.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $debugfsExe @args 2>&1 | Out-String }
    finally { $ErrorActionPreference = $old }
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    return $out
}

$Script:TempFiles = New-Object System.Collections.Generic.List[string]
function New-TempFile([string]$prefix, [string]$ext) {
    $root = Join-Path $env:TEMP 'bsr_work'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    # no random (deterministic & resume-safe); caller ensures uniqueness by prefix
    $f = Join-Path $root ($prefix + $ext)
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
        # gone = stat no longer reports an inode for it
        if ($stat -notmatch '(?im)Inode:\s*\d') { Say "[+] su removed from ext4." Green; return $true }
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
        "write $suD su",
        'sif su mode 0106755',
        'sif su uid 0',
        'sif su gid 0',
        'sif su links_count 1'
    )
    Run-Debugfs $dfs $imgPath $cmds -Write | Out-Null
    $stat = Run-Debugfs $dfs $imgPath @('stat /android/system/xbin/su')
    Remove-Item -LiteralPath $suFile -Force -ErrorAction SilentlyContinue
    Say "[*] verify:`n$stat"
    if ($stat -notmatch '(?im)Inode:\s*\d') { Say "[!] su was not written into ext4." Red; return $false }
    # debugfs prints the permission bits only, e.g. "Mode:  06755" (NOT the full i_mode).
    # Parse the octal Mode and compare its low 12 bits to 0o6755 (= 0xDED): setuid+setgid+rwxr-xr-x.
    $okMode = $false
    $mm = [regex]::Match($stat, '(?im)Mode:\s*0*([0-7]{3,6})')
    if ($mm.Success) { try { $okMode = (([Convert]::ToInt32($mm.Groups[1].Value, 8)) -band 0xFFF) -eq 0xDED } catch { } }
    if (-not $okMode) { Say "[!] su present but mode is not 06755 (setuid/setgid). Not trusting this image." Red; return $false }
    Say "[+] su installed: /android/system/xbin/su  mode 06755 (setuid root)  owner 0:0" Green
    return $true
}

# ===========================================================================
#  ROOT / UNROOT  --  attach Root.vhd, locate ext4, carve, edit, write back
# ===========================================================================
function Read-DeviceBytes([string]$device, [long]$offset, [int]$count) {
    $fs = [System.IO.File]::Open($device, 'Open', 'Read', 'ReadWrite')
    try {
        # raw-device reads must be sector-aligned: read the 512-byte sector and slice
        $secBase = [long]([Math]::Floor($offset / 512) * 512)
        $delta = [int]($offset - $secBase)
        $need = [int]([Math]::Ceiling(($delta + $count) / 512.0) * 512)
        $buf = New-Object byte[] $need
        $fs.Position = $secBase
        [void]$fs.Read($buf, 0, $need)
        $res = New-Object byte[] $count
        [Array]::Copy($buf, $delta, $res, 0, $count)
        return $res
    } finally { $fs.Close() }
}

function Copy-DeviceToFile([string]$device, [long]$start, [long]$length, [string]$outFile) {
    $fs = [System.IO.File]::Open($device, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Position = $start
        $out = [System.IO.File]::Open($outFile, 'Create', 'Write', 'None')
        try {
            $buf = New-Object byte[] (16MB)
            [long]$remaining = $length
            while ($remaining -gt 0) {
                $want = [int][Math]::Min([long]$buf.Length, $remaining)
                $r = $fs.Read($buf, 0, $want)
                if ($r -le 0) { break }
                $out.Write($buf, 0, $r)
                $remaining -= $r
            }
        } finally { $out.Close() }
    } finally { $fs.Close() }
}

function Copy-FileToDevice([string]$inFile, [string]$device, [long]$start) {
    $fs = [System.IO.File]::Open($device, 'Open', 'ReadWrite', 'ReadWrite')
    try {
        $fs.Position = $start
        $in = [System.IO.File]::OpenRead($inFile)
        try {
            $buf = New-Object byte[] (16MB)
            while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                if (($r % 512) -ne 0) { $r += (512 - ($r % 512)) }  # safety pad (img is sector-multiple)
                $fs.Write($buf, 0, $r)
            }
            $fs.Flush()
        } finally { $in.Close() }
    } finally { $fs.Close() }
}

function Get-Ext4Target($diskNumber, $physical) {
    # Returns @{ Device; Start; Length } for the ext4 region, by probing +0x438 == 0xEF53.
    $parts = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object Offset)
    foreach ($p in $parts) {
        $dev = "\\.\Harddisk$($diskNumber)Partition$($p.PartitionNumber)"
        try {
            $m = Read-DeviceBytes $dev 0x438 2
            if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
                return @{ Device = $dev; Start = [long]0; Length = [long]$p.Size; Offset = [long]$p.Offset }
            }
        }
        catch { }  # partition device not openable -> skip
        # fallback: probe on the physical drive at the partition's absolute offset
        try {
            $m = Read-DeviceBytes $physical ([long]$p.Offset + 0x438) 2
            if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
                return @{ Device = $physical; Start = [long]$p.Offset; Length = [long]$p.Size; Offset = [long]$p.Offset }
            }
        }
        catch { }
    }
    # superfloppy: ext4 directly at disk offset 0
    try {
        $m = Read-DeviceBytes $physical 0x438 2
        if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) {
            $disk = Get-Disk -Number $diskNumber
            return @{ Device = $physical; Start = [long]0; Length = [long]$disk.Size; Offset = [long]0 }
        }
    }
    catch { }
    return $null
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
                    Copy-Item -LiteralPath $Vhd -Destination $vbak -Force
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
        Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null
        $attached = $true
        $dn = $null
        for ($try = 0; $try -lt 20; $try++) {
            $di = Get-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue
            if ($di -and $di.Number -ne $null) { $dn = $di.Number; break }
            Start-Sleep -Milliseconds 250
        }
        if ($null -eq $dn) {
            $disk = Get-DiskImage -ImagePath $Vhd | Get-Disk -ErrorAction SilentlyContinue
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
        Copy-FileToDevice $img $tgt.Device $tgt.Start
        Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
        if ($remove) { Say "[+] Unrooted successfully! (su removed from Root.vhd)" Green }
        else { Say "[+] Rooted successfully! (su installed into Root.vhd)" Green }
        return 0
    }
    finally {
        if ($attached) {
            try { Dismount-DiskImage -ImagePath $Vhd -ErrorAction Stop | Out-Null; Say "[*] Detached $Vhd." }
            catch { Say "[!] WARNING: failed to detach $Vhd -- detach it manually (Disk Management) before launching BlueStacks." Red }
        }
    }
}

# ===========================================================================
#  .bstk disk mode  --  faithful global regex_replace (derivation §4)
# ===========================================================================
function Backup-Once([string]$path) {
    $bak = "$path.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
        try { attrib -R $path 2>$null | Out-Null } catch { }
        Copy-Item -LiteralPath $path -Destination $bak -Force
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
    [System.IO.File]::WriteAllText($Bstk, $new, (New-Object System.Text.UTF8Encoding($false)))
    if ($toReadonly) { Say "[+] Disk reverted to Readonly." Green } else { Say "[+] Disk set to R/W." Green }
    return 0
}

# ===========================================================================
#  bluestacks.conf root flags  (hybrid §6a -- works with Magisk + adb)
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
    # CRITICAL: bluestacks.conf must stay UTF-8 *without* a BOM and keep its original
    # line endings.  PowerShell 5.1 'Set-Content -Encoding utf8' writes a BOM, which
    # makes BlueStacks fail with "Failed to read configuration file" -- so read raw,
    # edit lines, and write with UTF8Encoding($false) preserving the EOL style.
    $raw = [System.IO.File]::ReadAllText($Conf)
    $eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $endsNl = $raw.EndsWith("`n")
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($raw -split "`r`n|`n")) { $lines.Add($l) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    # Only valid, already-present keys (see Set-ConfKey).  Root = per-instance
    # enable_root_access + the global rooting feature; adb = the GLOBAL
    # bst.enable_adb_access (there is NO valid per-instance enable_adb_access key).
    $miss = New-Object System.Collections.Generic.List[string]
    if (-not (Set-ConfKey $lines "bst.instance.$Instance.enable_root_access" $val)) { $miss.Add("bst.instance.$Instance.enable_root_access") }
    if (-not (Set-ConfKey $lines 'bst.feature.rooting' $val)) { $miss.Add('bst.feature.rooting') }
    if (-not (Set-ConfKey $lines 'bst.enable_adb_access' $val)) { $miss.Add('bst.enable_adb_access') }
    if ($miss.Count -gt 0) { Say "[~] conf key(s) absent, left as-is (NOT added, would brick startup): $($miss -join ', ')" Yellow }
    try { attrib -R $Conf 2>$null | Out-Null } catch { }
    $outText = ($lines -join $eol); if ($endsNl) { $outText += $eol }
    [System.IO.File]::WriteAllText($Conf, $outText, (New-Object System.Text.UTF8Encoding($false)))
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
        Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null
        $attached = $true
        $dn = $null
        for ($t = 0; $t -lt 20; $t++) { $di = Get-DiskImage -ImagePath $Vhd -EA SilentlyContinue; if ($di -and $di.Number -ne $null) { $dn = $di.Number; break }; Start-Sleep -Milliseconds 250 }
        if ($null -eq $dn) { throw "no disk number" }
        $physical = "\\.\PhysicalDrive$dn"
        $tgt = Get-Ext4Target $dn $physical
        if ($null -eq $tgt) { Say "[!] ext4 region not detected." Red; return 1 }
        Say ("[*] region: device={0} start=0x{1:X} len={2}" -f $tgt.Device, $tgt.Start, $tgt.Length)
        $img1 = New-TempFile 'st1' '.img'; $img2 = New-TempFile 'st2' '.img'
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img1
        $h1 = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($img1))
        Copy-FileToDevice $img1 $tgt.Device $tgt.Start
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img2
        $h2 = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($img2))
        Remove-Item $img1, $img2 -Force -EA SilentlyContinue
        if ($h1 -eq $h2) { Say "[+] carve/write-back is byte-identical (sha256 $($h1.Substring(0,16))...)." Green; return 0 }
        Say "[!] MISMATCH after write-back: $h1 vs $h2" Red; return 1
    }
    finally { if ($attached) { try { Dismount-DiskImage -ImagePath $Vhd -EA Stop | Out-Null } catch { Say "[!] detach failed for $Vhd" Red } } }
}

# ===========================================================================
#  Resolve  --  discover instance / master / .bstk / conf / Root.vhd paths.
#  Emits ONLY  KEY=VALUE  lines on stdout (so a .cmd `for /f` can `set` them).
#  NOTE: must never Write-Host here -- it would pollute the captured output.
# ===========================================================================
# Normalize to the folder that actually holds bluestacks.conf + Engine\.
# Newer BlueStacks (e.g. 5.22.169) sets DataDir to ...\BlueStacks_nxt\Engine,
# while UserDefinedDir is the real base ...\BlueStacks_nxt -- handle both.
function Get-BaseDir([string]$dataDir, [string]$userDef) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($dataDir) {
        if ($dataDir -match '(?i)[\\/]engine[\\/]?$') { [void]$cands.Add(($dataDir -replace '(?i)[\\/]engine[\\/]?$', '')) }
        [void]$cands.Add($dataDir)
    }
    if ($userDef) { [void]$cands.Add($userDef) }
    # registry-declared data dir (honours a custom install) before the ProgramData fallback
    $reg = Get-RegBlueStacks
    if ($reg) {
        foreach ($d in @($reg.DataDir, $reg.UserDefinedDir)) {
            if ($d) {
                if ($d -match '(?i)[\\/]engine[\\/]?$') { [void]$cands.Add(($d -replace '(?i)[\\/]engine[\\/]?$', '')) }
                [void]$cands.Add($d)
            }
        }
    }
    [void]$cands.Add((Join-Path $env:ProgramData 'BlueStacks_nxt'))
    $pick = $null
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'bluestacks.conf'))) { $pick = $c; break } }
    if (-not $pick) { foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'Engine'))) { $pick = $c; break } } }
    if (-not $pick) { $pick = $cands[0] }
    return $pick.TrimEnd('\', '/')
}

function Invoke-Resolve {
    if (-not $DataDir -and -not $UserDef) { throw "Resolve requires -DataDir/-UserDef (or BSR_DATADIR/BSR_USERDEF)." }
    if (-not $Base) { throw "Resolve requires -Base (or BSR_BASE)." }
    $DataDir = Get-BaseDir $DataDir $UserDef     # normalize ...\Engine -> base
    $instance = $null
    $rx = '^' + [regex]::Escape($Base) + '(_\d+)?$'

    # 1) candidates from MimMetaData.json
    $cands = @()
    $mim = Join-Path $DataDir 'UserData\MimMetaData.json'
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
            $hit = $tail | Select-String -Pattern ([regex]::Escape($Base) + '(_\d+)?') -AllMatches |
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
    $reg = Get-RegBlueStacks                                   # registry InstallDir first (custom installs)
    if ($reg -and $reg.InstallDir) { [void]$cands.Add((Join-Path ($reg.InstallDir.TrimEnd('\', '/')) 'HD-Adb.exe')) }
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'BlueStacks_nxt\HD-Adb.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'BlueStacks_nxt\HD-Adb.exe'),
            (Join-Path $env:ProgramFiles 'BlueStacks_msi5\HD-Adb.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'BlueStacks_msi5\HD-Adb.exe'))) { [void]$cands.Add($p) }
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    foreach ($n in @('HD-Adb.exe', 'adb.exe')) { $c = Get-Command $n -EA SilentlyContinue; if ($c) { return $c.Source } }
    throw "HD-Adb.exe not found. Pass -Adb <path to HD-Adb.exe> (or BSR_ADB)."
}

$Script:AdbExe = $null
$Script:Serial = $null

function AdbRaw([string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& $Script:AdbExe @a 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
}
function AdbS([string[]]$a) { return AdbRaw (@('-s', $Script:Serial) + $a) }
function AdbShell([string]$cmd) { return AdbS @('shell', $cmd) }

# Connect to the instance's adb endpoint and wait until Android finishes booting.
function Connect-WaitBoot([int]$timeoutSec) {
    $port = if ($AdbPort) { $AdbPort } else { '5555' }
    $Script:Serial = "127.0.0.1:$port"
    # Isolate HD-Adb on its own server port so a different-version system adb (e.g. Android SDK
    # platform-tools) on the default 5037 can't kill our server mid-run (the version-mismatch churn
    # that makes getprop/shell calls fail and a booted instance look "not adb-reachable").
    if (-not $env:ANDROID_ADB_SERVER_PORT) { $env:ANDROID_ADB_SERVER_PORT = '15037' }
    AdbRaw @('start-server') | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $connected = $false
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $c = AdbRaw @('connect', $Script:Serial)
        if ($c -match '(?i)connected to') { $connected = $true }
        if (-not $connected) {
            # maybe it registered as emulator-XXXX instead
            $dev = AdbRaw @('devices')
            $m = [regex]::Match($dev, '(?im)^(emulator-\d+|127\.0\.0\.1:\d+)\s+device\s*$')
            if ($m.Success) { $Script:Serial = $m.Groups[1].Value; $connected = $true }
        }
        if ($connected) {
            $b = (AdbShell 'getprop sys.boot_completed').Trim()
            if ($b -match '1') {
                # give late services (su daemon) a moment
                Start-Sleep -Seconds 3
                return $true
            }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Launch-Instance {
    if ($NoLaunch) { Say "[*] -NoLaunch: assuming the instance is already running." ; return }
    if (-not $Player -or -not (Test-Path -LiteralPath $Player)) { Say "[~] HD-Player.exe not provided; not launching (will try to connect anyway)." Yellow; return }
    if (-not $Instance) { throw "AdbRoot requires -Instance to launch." }
    $running = @(Get-Process -Name 'HD-Player' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { Say "[*] HD-Player already running; not launching a second instance." ; return }
    Say "[*] Booting instance '$Instance' ..."
    Start-Process -FilePath $Player -ArgumentList @('--instance', $Instance) | Out-Null
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
    'BaseDir' { Write-Output (Get-BaseDir $DataDir $UserDef); exit 0 }
    'VhdSelfTest' { exit (Invoke-VhdSelfTest) }
}
