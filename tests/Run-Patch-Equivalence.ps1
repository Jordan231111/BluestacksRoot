<#
  Run-Patch-Equivalence.ps1 -- proves the OPTIMIZED HD-Player integrity patch is byte-for-byte
  identical to the original byte-by-byte implementation, and measures the speedup.

  WHY THIS EXISTS
  ---------------
  Invoke-Patch (tools\bsr_engine.ps1) used to (a) scan the whole ~27 MB file byte-by-byte in
  interpreted PowerShell -- 6 full passes for the anchor strings + one pass over .text for the
  CALL;TEST;JZ candidates -- and (b) rewrite the entire file to change 2 bytes. The optimization
  replaces the scan loops with native [Array]::IndexOf jumps and the whole-file write with a
  FileStream seek + 2-byte write per site. Only StringRvas, the candidate scan, and the write
  changed; RawToRva, NearAnchor, and the site-selection logic are untouched.

  This test holds a FROZEN COPY of the ORIGINAL algorithm (the "*_OLD" functions + Predict-Patch
  below) as an oracle. It then:
    Layer 1 (unit)  : asserts the frozen-OLD scanners and the NEW (IndexOf) scanners return
                      identical results over a battery of crafted byte buffers AND the real
                      HD-Player.exe if installed.
    Layer 2 (e2e)   : runs the REAL engine 'Patch' (child process, exactly as blueStackRoot.cmd
                      does) over crafted PEs + a copy of the real HD-Player.exe, and asserts the
                      engine changed EXACTLY the bytes the frozen oracle predicts and nothing else.
    Bench           : prints BEFORE (frozen-OLD) vs AFTER (NEW) scan timing.

  The real HD-Player.exe is NEVER modified -- it is copied to %TEMP% first. On a box with no
  BlueStacks (e.g. GitHub CI) the real-file sections auto-skip; the synthetic coverage still runs.

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Patch-Equivalence.ps1
         ... -RealExe "D:\BlueStacks_nxt\HD-Player.exe"   ... -BenchTextMB 4   ... -SkipBench
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [string]$RealExe,
    [int]$BenchTextMB = 3,
    [switch]$SkipBench
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $Engine) { $Engine = Join-Path $repo 'tools\bsr_engine.ps1' }
if (-not (Test-Path -LiteralPath $Engine)) { throw "engine not found: $Engine" }
$Engine = (Resolve-Path -LiteralPath $Engine).Path
if (-not $RealExe) { $RealExe = Join-Path $env:ProgramFiles 'BlueStacks_nxt\HD-Player.exe' }

$work = Join-Path $env:TEMP ("bsr_patcheq_" + $PID)
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Sk($m) { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray; $script:skip++ }
function Check($cond, $m) { if ($cond) { Ok $m } else { No $m } }

# ---- byte writers ----
function Set-U16([byte[]]$b, [int]$o, [int]$v) { $b[$o] = $v -band 0xFF; $b[$o + 1] = ($v -shr 8) -band 0xFF }
function Set-U32([byte[]]$b, [int]$o, [long]$v) { for ($k = 0; $k -lt 4; $k++) { $b[$o + $k] = ($v -shr (8 * $k)) -band 0xFF } }
function Set-U64([byte[]]$b, [int]$o, [uint64]$v) { for ($k = 0; $k -lt 8; $k++) { $b[$o + $k] = [byte](($v -shr (8 * $k)) -band 0xFF) } }
function Set-Str([byte[]]$b, [int]$o, [string]$s) { $by = [Text.Encoding]::ASCII.GetBytes($s); [Array]::Copy($by, 0, $b, $o, $by.Length) }

# anchor string constants -- MUST match tools\bsr_engine.ps1 Invoke-Patch
$PrimaryStr = @('Verified the disk integrity!', 'Failed to verify the disk integrity!')
$FallbackStr = @('plrDiskCheckThreadEntry',
    'Shutting down: disk file have been illegally tampered with!',
    'Failed to verify the file', 'In warmup mode: Stopping player.')

# =====================================================================
#  FROZEN ORACLE -- a byte-for-byte copy of the ORIGINAL algorithm.
#  Do NOT "optimize" these; they are the reference the engine must match.
# =====================================================================
function PE-Parse([byte[]]$b) {
    $e = [BitConverter]::ToInt32($b, 0x3C)
    $numSec = [BitConverter]::ToUInt16($b, $e + 6)
    $sizeOpt = [BitConverter]::ToUInt16($b, $e + 20)
    $opt = $e + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $imageBase = if ($magic -eq 0x20B) { [BitConverter]::ToUInt64($b, $opt + 24) } else { [BitConverter]::ToUInt32($b, $opt + 28) }
    $secTable = $opt + $sizeOpt
    $sections = @(); $textVA = $null; $textRaw = $null; $textRawSize = $null
    for ($i = 0; $i -lt $numSec; $i++) {
        $s = $secTable + ($i * 40)
        $name = ([Text.Encoding]::ASCII.GetString($b, $s, 8)).TrimEnd([char]0)
        $va = [BitConverter]::ToUInt32($b, $s + 12); $rs = [BitConverter]::ToUInt32($b, $s + 16); $pr = [BitConverter]::ToUInt32($b, $s + 20)
        $sections += [pscustomobject]@{ Name = $name; VA = $va; RawSize = $rs; RawPtr = $pr }
        if ($name -eq '.text') { $textVA = [int]$va; $textRaw = [int]$pr; $textRawSize = [int]$rs }
    }
    return [pscustomobject]@{ Sections = $sections; TextVA = $textVA; TextRaw = $textRaw; TextRawSize = $textRawSize; ImageBase = $imageBase }
}
function RawToRva([int]$raw, $sections) {
    foreach ($s in $sections) { if ($raw -ge $s.RawPtr -and $raw -lt ($s.RawPtr + $s.RawSize)) { return [int]($s.VA + ($raw - $s.RawPtr)) } }
    return -1
}
function StringRvas_OLD([byte[]]$b, [string]$text, $sections) {
    $needle = [Text.Encoding]::ASCII.GetBytes($text)
    $hits = New-Object System.Collections.Generic.List[int]
    $max = $b.Length - $needle.Length - 1
    for ($i = 0; $i -le $max; $i++) {
        if ($b[$i] -ne $needle[0]) { continue }
        $ok = $true
        for ($k = 1; $k -lt $needle.Length; $k++) { if ($b[$i + $k] -ne $needle[$k]) { $ok = $false; break } }
        if ($ok -and $b[$i + $needle.Length] -eq 0) { $rva = RawToRva $i $sections; if ($rva -ge 0) { [void]$hits.Add($rva) } }
    }
    return $hits
}
function Cands_OLD([byte[]]$b, [int]$textStart, [int]$textEnd) {
    $c = New-Object System.Collections.Generic.List[int]
    for ($t = $textStart; $t -lt $textEnd; $t++) {
        if ($b[$t] -eq 0x84 -and $b[$t + 1] -eq 0xC0 -and $b[$t - 5] -eq 0xE8 -and ($b[$t + 2] -eq 0x74 -or ($b[$t + 2] -eq 0x90 -and $b[$t + 3] -eq 0x90))) { [void]$c.Add($t) }
    }
    return $c
}
function NearAnchor_OLD([byte[]]$b, [int]$t, [int]$textVA, [int]$textRaw, [int]$window, $targetSet) {
    $lo = [Math]::Max($textRaw, $t - $window); $hi = $t + $window
    if ($hi -gt $b.Length - 7) { $hi = $b.Length - 7 }
    for ($p = $lo; $p -lt $hi; $p++) {
        $rex = $b[$p]
        if ($rex -ne 0x48 -and $rex -ne 0x4C -and $rex -ne 0x49 -and $rex -ne 0x4D) { continue }
        if ($b[$p + 1] -ne 0x8D) { continue }
        if (($b[$p + 2] -band 0xC7) -ne 0x05) { continue }
        $disp = [BitConverter]::ToInt32($b, $p + 3)
        $target = $textVA + (($p + 7) - $textRaw) + $disp
        if ($targetSet.Contains($target)) { return $true }
    }
    return $false
}
# Predict the exact (exit code, post-patch bytes) the original Invoke-Patch would produce.
function Predict-Patch([byte[]]$b, [bool]$force, [bool]$dryRun) {
    $pe = PE-Parse $b
    $primarySet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($s in $PrimaryStr) { foreach ($r in (StringRvas_OLD $b $s $pe.Sections)) { [void]$primarySet.Add($r) } }
    $fallbackSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($r in $primarySet) { [void]$fallbackSet.Add($r) }
    foreach ($s in $FallbackStr) { foreach ($r in (StringRvas_OLD $b $s $pe.Sections)) { [void]$fallbackSet.Add($r) } }
    $textStart = $pe.TextRaw + 5; $textEnd = $pe.TextRaw + $pe.TextRawSize - 3
    if ($textEnd -gt $b.Length - 3) { $textEnd = $b.Length - 3 }
    $cands = Cands_OLD $b $textStart $textEnd
    if ($cands.Count -eq 0) { return [pscustomobject]@{ Exit = 1; Bytes = $b.Clone(); ToApply = @(); Sites = @() } }
    $sites = New-Object System.Collections.Generic.List[int]
    if ($primarySet.Count -gt 0) { foreach ($c in $cands) { if (NearAnchor_OLD $b $c $pe.TextVA $pe.TextRaw 0xE0 $primarySet) { [void]$sites.Add($c) } } }
    if ($sites.Count -eq 0 -and $fallbackSet.Count -gt 0) { foreach ($c in $cands) { if (NearAnchor_OLD $b $c $pe.TextVA $pe.TextRaw 0x700 $fallbackSet) { [void]$sites.Add($c) } } }
    if ($sites.Count -eq 0) {
        if ($cands.Count -eq 1 -and $force) { [void]$sites.Add($cands[0]) }
        else { return [pscustomobject]@{ Exit = 1; Bytes = $b.Clone(); ToApply = @(); Sites = @() } }
    }
    $toApply = @(); foreach ($t in $sites) { if ($b[$t + 2] -eq 0x74) { $toApply += $t } }
    $exp = $b.Clone()
    if (-not $dryRun) { foreach ($t in $toApply) { $exp[$t + 2] = 0x90; $exp[$t + 3] = 0x90 } }
    return [pscustomobject]@{ Exit = 0; Bytes = $exp; ToApply = $toApply; Sites = @($sites) }
}

# =====================================================================
#  NEW scanners -- MUST be kept textually identical to tools\bsr_engine.ps1.
#  Layer-2 (real engine) is the authoritative cross-check; these power the
#  fast Layer-1 micro-equivalence + the bench.
# =====================================================================
function StringRvas_NEW([byte[]]$b, [string]$text, $sections) {
    $needle = [Text.Encoding]::ASCII.GetBytes($text)
    $hits = New-Object System.Collections.Generic.List[int]
    $max = $b.Length - $needle.Length - 1
    $first = $needle[0]; $nlen = $needle.Length
    $i = [Array]::IndexOf($b, $first, 0)
    while ($i -ge 0 -and $i -le $max) {
        $ok = $true
        for ($k = 1; $k -lt $nlen; $k++) { if ($b[$i + $k] -ne $needle[$k]) { $ok = $false; break } }
        if ($ok -and $b[$i + $nlen] -eq 0) { $rva = RawToRva $i $sections; if ($rva -ge 0) { [void]$hits.Add($rva) } }
        $i = [Array]::IndexOf($b, $first, $i + 1)
    }
    return $hits
}
function Cands_NEW([byte[]]$b, [int]$textStart, [int]$textEnd) {
    $c = New-Object System.Collections.Generic.List[int]
    if ($textStart -lt $textEnd) {
        $t = [Array]::IndexOf($b, [byte]0x84, $textStart, $textEnd - $textStart)
        while ($t -ge 0) {
            if ($b[$t + 1] -eq 0xC0 -and $b[$t - 5] -eq 0xE8 -and ($b[$t + 2] -eq 0x74 -or ($b[$t + 2] -eq 0x90 -and $b[$t + 3] -eq 0x90))) { [void]$c.Add($t) }
            if ($t + 1 -ge $textEnd) { break }
            $t = [Array]::IndexOf($b, [byte]0x84, $t + 1, $textEnd - ($t + 1))
        }
    }
    return $c
}

# =====================================================================
#  synthetic PE builder (flexible; faithful PE32+ headers so the engine parses it)
# =====================================================================
function New-PE {
    param(
        [string]$Anchor = 'Verified the disk integrity!',
        [int]$ValidSites = 1, [switch]$Noise, [switch]$PreNopFirst,
        [int]$TextSize = 0x200, [int]$DecoyBytes = 0, [switch]$AnchorInHeaderGap
    )
    $textRaw = 0x200; $rdataRaw = $textRaw + $TextSize; $rdataSize = 0x400
    $b = New-Object byte[] ($rdataRaw + $rdataSize)
    Set-Str $b 0 'MZ'; Set-U32 $b 0x3C 0x80; Set-Str $b 0x80 "PE`0`0"
    Set-U16 $b 0x84 0x8664; Set-U16 $b 0x86 2; Set-U16 $b 0x94 0xF0; Set-U16 $b 0x98 0x20B
    Set-U64 $b 0xB0 0x140000000
    $textVA = 0x1000; $rdataVA = 0x1000 + [Math]::Max($TextSize, 0x1000)
    Set-Str $b 0x188 '.text'; Set-U32 $b 0x190 $TextSize; Set-U32 $b 0x194 $textVA; Set-U32 $b 0x198 $TextSize; Set-U32 $b 0x19C $textRaw
    Set-Str $b 0x1B0 '.rdata'; Set-U32 $b 0x1B8 $rdataSize; Set-U32 $b 0x1BC $rdataVA; Set-U32 $b 0x1C0 $rdataSize; Set-U32 $b 0x1C4 $rdataRaw
    $anchorRaw = $rdataRaw + 0x20
    Set-Str $b $anchorRaw $Anchor; $b[$anchorRaw + $Anchor.Length] = 0
    $anchorRVA = $rdataVA + ($anchorRaw - $rdataRaw)
    if ($AnchorInHeaderGap) { Set-Str $b 0x100 $Anchor; $b[0x100 + $Anchor.Length] = 0 }   # RVA -1 -> must be ignored
    for ($i = 0; $i -lt $DecoyBytes; $i++) { $off = $textRaw + 0x120 + (($i * 7) % [Math]::Max(1, $TextSize - 0x140)); if ($off -lt $rdataRaw) { $b[$off] = 0x84 } }
    $rex = @(0x48, 0x4C, 0x49, 0x4D)
    for ($k = 0; $k -lt $ValidSites; $k++) {
        $base = 0x10 + $k * 0x30; $rawLea = $textRaw + $base; $rawPat = $rawLea + 0x10
        $leaRVA = $textVA + ($rawLea - $textRaw); $disp = $anchorRVA - ($leaRVA + 7)
        $b[$rawLea] = $rex[$k % 4]; $b[$rawLea + 1] = 0x8D; $b[$rawLea + 2] = 0x0D; Set-U32 $b ($rawLea + 3) $disp
        $b[$rawPat] = 0xE8; Set-U32 $b ($rawPat + 1) 0
        $b[$rawPat + 5] = 0x84; $b[$rawPat + 6] = 0xC0
        if ($PreNopFirst -and $k -eq 0) { $b[$rawPat + 7] = 0x90; $b[$rawPat + 8] = 0x90 } else { $b[$rawPat + 7] = 0x74; $b[$rawPat + 8] = 0x10 }
    }
    if ($Noise) { $np = $rdataRaw - 0x40; $b[$np] = 0xE8; Set-U32 $b ($np + 1) 0; $b[$np + 5] = 0x84; $b[$np + 6] = 0xC0; $b[$np + 7] = 0x74; $b[$np + 8] = 0x10 }
    return , $b
}

function Run-Engine([string[]]$engArgs) {
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Engine) + $engArgs
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & powershell.exe @allArgs 2>&1 | Out-String } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function BytesEqual([byte[]]$x, [byte[]]$y) {
    if ($x.Length -ne $y.Length) { return $false }
    for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
    return $true
}
function ListEq($a, $b) { return ((@($a) -join ',') -eq (@($b) -join ',')) }

# Run BOTH scanners over a buffer and assert identical results for every anchor + candidates.
function Assert-ScannerEquivalence([byte[]]$b, [string]$label) {
    $pe = PE-Parse $b
    $allSame = $true
    foreach ($s in ($PrimaryStr + $FallbackStr)) {
        $o = @(StringRvas_OLD $b $s $pe.Sections); $n = @(StringRvas_NEW $b $s $pe.Sections)
        if (-not (ListEq $o $n)) { $allSame = $false; No "scanner '$label' string '$s': OLD=[$($o -join ',')] NEW=[$($n -join ',')]" }
    }
    $textStart = $pe.TextRaw + 5; $textEnd = $pe.TextRaw + $pe.TextRawSize - 3
    if ($textEnd -gt $b.Length - 3) { $textEnd = $b.Length - 3 }
    $co = @(Cands_OLD $b $textStart $textEnd); $cn = @(Cands_NEW $b $textStart $textEnd)
    if (-not (ListEq $co $cn)) { $allSame = $false; No "scanner '$label' candidates: OLD=$($co.Count) NEW=$($cn.Count)" }
    if ($allSame) { Ok "scanner equivalence: $label (strings x$(($PrimaryStr + $FallbackStr).Count) + $($co.Count) candidates identical)" }
}

# Run the real engine on a PE and assert it produced EXACTLY the oracle-predicted result.
function Assert-EngineMatchesOracle([byte[]]$pe, [string]$label, [switch]$Force, [switch]$DryRun, [switch]$NoBackup) {
    $f = Join-Path $work ('eng_' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.exe')
    [IO.File]::WriteAllBytes($f, $pe)
    $pred = Predict-Patch $pe ([bool]$Force) ([bool]$DryRun)
    $args = @('-Action', 'Patch', '-Exe', $f)
    if ($Force) { $args += '-Force' }
    if ($DryRun) { $args += '-DryRun' }
    if ($NoBackup) { $args += '-NoBackup' }
    $r = Run-Engine $args
    $after = [IO.File]::ReadAllBytes($f)
    $bytesOk = BytesEqual $after $pred.Bytes
    $codeOk = ($r.Code -eq $pred.Exit)
    Check ($bytesOk -and $codeOk) ("engine==oracle: $label (exit exp=$($pred.Exit) got=$($r.Code); patched $($pred.ToApply.Count) site(s); bytes match=$bytesOk)")
    if (-not $bytesOk -or -not $codeOk) { Write-Host "      engine out: $($r.Out.Trim())" -ForegroundColor DarkGray }
}

try {
    # =================================================================
    Section "Layer 1 -- scanner micro-equivalence (frozen-OLD vs IndexOf-NEW)"
    Assert-ScannerEquivalence (New-PE -ValidSites 1) 'single primary site'
    Assert-ScannerEquivalence (New-PE -ValidSites 3) 'three primary sites'
    Assert-ScannerEquivalence (New-PE -ValidSites 1 -Noise) 'site + noise'
    Assert-ScannerEquivalence (New-PE -ValidSites 0 -Noise) 'noise only'
    Assert-ScannerEquivalence (New-PE -ValidSites 1 -PreNopFirst) 'already-patched (90 90)'
    Assert-ScannerEquivalence (New-PE -ValidSites 2 -PreNopFirst) 'mixed already + fresh'
    Assert-ScannerEquivalence (New-PE -Anchor 'plrDiskCheckThreadEntry' -ValidSites 1) 'fallback anchor'
    Assert-ScannerEquivalence (New-PE -ValidSites 1 -AnchorInHeaderGap) 'anchor copy in header gap (RVA -1)'
    Assert-ScannerEquivalence (New-PE -ValidSites 2 -Noise -DecoyBytes 4000 -TextSize 0x40000) 'decoy-heavy large .text'
    # buffers that stress the first-byte fast-path (many needle[0] hits, no full match)
    $bV = New-PE -ValidSites 1; for ($i = $bV.Length - 0x300; $i -lt $bV.Length - 0x80; $i++) { $bV[$i] = 0x56 }  # 'V' flood in .rdata tail
    Assert-ScannerEquivalence $bV "first-byte flood ('V' x many, no match)"

    # =================================================================
    Section "Layer 2 -- real engine 'Patch' == frozen oracle (end-to-end, child process)"
    Assert-EngineMatchesOracle (New-PE -ValidSites 1) 'single validated site -> patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 3) 'three validated sites -> all patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 1 -Noise) 'validated + noise -> only validated patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 0 -Noise) 'noise only -> refused, file unchanged'
    Assert-EngineMatchesOracle (New-PE -ValidSites 0 -Noise) -Force 'noise only + Force -> lone candidate patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 1 -PreNopFirst) 'already-patched -> no change'
    Assert-EngineMatchesOracle (New-PE -ValidSites 2 -PreNopFirst) 'mixed already + fresh -> only fresh patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 1) -DryRun 'DryRun -> no change'
    Assert-EngineMatchesOracle (New-PE -Anchor 'plrDiskCheckThreadEntry' -ValidSites 1) 'fallback-anchor path -> patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 1 -AnchorInHeaderGap) 'header-gap anchor ignored, real site patched'
    Assert-EngineMatchesOracle (New-PE -ValidSites 2 -Noise -DecoyBytes 4000 -TextSize 0x40000) 'large/decoy PE -> both sites patched'

    # =================================================================
    Section "Real HD-Player.exe (copied to TEMP; never the installed binary)"
    if (Test-Path -LiteralPath $RealExe) {
        $b = [IO.File]::ReadAllBytes($RealExe)
        Assert-ScannerEquivalence $b ("real HD-Player.exe ({0:N0} bytes)" -f $b.Length)
        Assert-EngineMatchesOracle $b -NoBackup ("real HD-Player.exe as-is ({0:N0} bytes)" -f $b.Length)
        # Exercise the actual 2-byte write at full file scale: un-patch the real validated site(s)
        # (JZ 90 90 -> 74 ??), then prove the engine re-patches EXACTLY those bytes and nothing else.
        $sites = @((Predict-Patch $b $false $false).Sites)
        if ($sites.Count -gt 0) {
            $un = $b.Clone(); foreach ($t in $sites) { $un[$t + 2] = 0x74; $un[$t + 3] = 0x10 }
            Assert-EngineMatchesOracle $un -NoBackup ("real HD-Player.exe re-patch $($sites.Count) site(s) @ $(($sites | ForEach-Object { '0x{0:X}' -f $_ }) -join ',') (full-scale seek-write)")
        }
        else { Sk "real HD-Player.exe: no validated site found to exercise the write path" }
    }
    else { Sk "real HD-Player.exe not found at $RealExe (set -RealExe or install BlueStacks)" }

    # =================================================================
    if (-not $SkipBench) {
        Section "Bench -- BEFORE (frozen-OLD byte loops) vs AFTER (IndexOf)"
        $benchTargets = @()
        $synthSize = [int]($BenchTextMB * 1MB)
        $benchTargets += , @("synthetic .text ~$BenchTextMB MB", (New-PE -ValidSites 1 -DecoyBytes 20000 -TextSize $synthSize))
        if (Test-Path -LiteralPath $RealExe) { $benchTargets += , @('real HD-Player.exe', ([IO.File]::ReadAllBytes($RealExe))) }
        foreach ($bt in $benchTargets) {
            $name = $bt[0]; $bb = $bt[1]; $pe = PE-Parse $bb
            $ts = $pe.TextRaw + 5; $te = $pe.TextRaw + $pe.TextRawSize - 3; if ($te -gt $bb.Length - 3) { $te = $bb.Length - 3 }
            $swO = [Diagnostics.Stopwatch]::StartNew()
            foreach ($s in ($PrimaryStr + $FallbackStr)) { [void](StringRvas_OLD $bb $s $pe.Sections) }
            [void](Cands_OLD $bb $ts $te); $swO.Stop()
            $swN = [Diagnostics.Stopwatch]::StartNew()
            foreach ($s in ($PrimaryStr + $FallbackStr)) { [void](StringRvas_NEW $bb $s $pe.Sections) }
            [void](Cands_NEW $bb $ts $te); $swN.Stop()
            $spd = if ($swN.Elapsed.TotalMilliseconds -gt 0) { $swO.Elapsed.TotalMilliseconds / $swN.Elapsed.TotalMilliseconds } else { 0 }
            Write-Host ("  {0,-26} BEFORE {1,9:N1} ms   AFTER {2,7:N1} ms   speedup ~{3:N0}x" -f $name, $swO.Elapsed.TotalMilliseconds, $swN.Elapsed.TotalMilliseconds, $spd) -ForegroundColor Yellow
        }
    }
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("  PASS={0}  FAIL={1}  SKIP={2}" -f $script:pass, $script:fail, $script:skip) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit ([int]($script:fail -gt 0))
