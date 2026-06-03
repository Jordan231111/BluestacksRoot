<#
  Run-Tests.ps1  --  unit / integration tests for the blueStackRoot engine.

  Safe to run on a dev box: it NEVER touches a real BlueStacks install, HD-Player.exe,
  or Root.vhd.  Everything runs against synthetic artifacts in a temp folder.

  Tiers:
    * always   : synthetic-PE integrity patch, .bstk regex, conf edit, su-blob round-trip
    * optional : ext4/debugfs install+remove (auto-skipped unless -Debugfs + -Mke2fs given)

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
    ... -Engine tools\bsr_engine.ps1 -Cmd blueStackRoot.cmd -Debugfs C:\tools\debugfs.exe -Mke2fs C:\tools\mke2fs.exe
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [string]$Cmd,
    [string]$Debugfs,
    [string]$Mke2fs
)

$ErrorActionPreference = 'Stop'

# resolve paths in the body ($PSScriptRoot is not reliable in param defaults)
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $Engine) { $Engine = Join-Path $repo 'tools\bsr_engine.ps1' }
if (-not $Cmd) { $Cmd = Join-Path $repo 'blueStackRoot.cmd' }
if (-not (Test-Path -LiteralPath $Engine)) { throw "engine not found: $Engine" }
$Engine = (Resolve-Path -LiteralPath $Engine).Path
function Redact-UserPath($value) {
    if ($null -eq $value) { return $value }
    $s = [string]$value
    $s = $s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])', '${1}xxxxx'
    $s = $s -replace '(?i)(/Users/)([^/]+)(?=$|/)', '${1}xxxxx'
    $s
}
Write-Host "engine: $(Redact-UserPath $Engine)" -ForegroundColor DarkGray
Write-Host "cmd:    $(Redact-UserPath $Cmd)" -ForegroundColor DarkGray
$work = Join-Path $env:TEMP ("bsr_tests_" + $PID)
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Sk($m) { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray; $script:skip++ }
function Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Check($cond, $m) { if ($cond) { Ok $m } else { No $m } }

function Run-Engine([string[]]$engArgs) {
    # invoke the engine in a child powershell, capture output + exit code.
    # child stderr (2>&1) must not throw in the parent, so relax EAP locally.
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Engine) + $engArgs
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & powershell.exe @allArgs 2>&1 | Out-String }
    finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# ---- byte helpers ----
function Set-U16([byte[]]$b, [int]$o, [int]$v) { $b[$o] = $v -band 0xFF; $b[$o + 1] = ($v -shr 8) -band 0xFF }
function Set-U32([byte[]]$b, [int]$o, [long]$v) { for ($k = 0; $k -lt 4; $k++) { $b[$o + $k] = ($v -shr (8 * $k)) -band 0xFF } }
function Set-U64([byte[]]$b, [int]$o, [uint64]$v) { for ($k = 0; $k -lt 8; $k++) { $b[$o + $k] = [byte](($v -shr (8 * $k)) -band 0xFF) } }
function Set-Str([byte[]]$b, [int]$o, [string]$s) { $by = [Text.Encoding]::ASCII.GetBytes($s); [Array]::Copy($by, 0, $b, $o, $by.Length) }

# ---- synthetic PE32+ builder ----
# Lays out N "valid" disk-integrity sites (RIP-LEA -> "Verified the disk integrity!" + CALL;TEST;JZ),
# plus optionally one "noise" CALL;TEST;JZ with NO nearby LEA (must NOT be patched).
function New-FakePE([int]$validSites = 1, [switch]$Noise, [switch]$PreNopFirst) {
    $b = New-Object byte[] 0x600
    Set-Str $b 0 'MZ'
    Set-U32 $b 0x3C 0x80                       # e_lfanew
    Set-Str $b 0x80 "PE`0`0"
    Set-U16 $b 0x84 0x8664                      # Machine x64
    Set-U16 $b 0x86 2                           # NumberOfSections
    Set-U16 $b 0x94 0xF0                        # SizeOfOptionalHeader
    Set-U16 $b 0x98 0x20B                       # Magic PE32+
    Set-U64 $b 0xB0 0x140000000                 # ImageBase (optHdr 0x98 + 24)
    # section table @ 0x188
    Set-Str $b 0x188 '.text'; Set-U32 $b 0x190 0x200; Set-U32 $b 0x194 0x1000; Set-U32 $b 0x198 0x200; Set-U32 $b 0x19C 0x200
    Set-Str $b 0x1B0 '.rdata'; Set-U32 $b 0x1B8 0x200; Set-U32 $b 0x1BC 0x2000; Set-U32 $b 0x1C0 0x200; Set-U32 $b 0x1C4 0x400
    # .rdata: the anchor string at VA 0x2000 (raw 0x400)
    Set-Str $b 0x400 'Verified the disk integrity!'
    $b[0x400 + 'Verified the disk integrity!'.Length] = 0
    # valid sites
    for ($k = 0; $k -lt $validSites; $k++) {
        $base = 0x10 + $k * 0x30                # .text offset
        $rawLea = 0x200 + $base
        $disp = 0x1000 - $base - 7              # -> target RVA 0x2000
        $b[$rawLea] = 0x48; $b[$rawLea + 1] = 0x8D; $b[$rawLea + 2] = 0x0D
        Set-U32 $b ($rawLea + 3) $disp
        $rawPat = 0x200 + $base + 0x10
        $b[$rawPat] = 0xE8; Set-U32 $b ($rawPat + 1) 0   # CALL rel32
        $b[$rawPat + 5] = 0x84; $b[$rawPat + 6] = 0xC0     # TEST AL,AL
        if ($PreNopFirst -and $k -eq 0) { $b[$rawPat + 7] = 0x90; $b[$rawPat + 8] = 0x90 }  # already patched
        else { $b[$rawPat + 7] = 0x74; $b[$rawPat + 8] = 0x10 }                              # JZ +0x10
    }
    if ($Noise) {
        $rawPat = 0x380                          # far from any LEA -> must not validate
        $b[$rawPat] = 0xE8; Set-U32 $b ($rawPat + 1) 0
        $b[$rawPat + 5] = 0x84; $b[$rawPat + 6] = 0xC0; $b[$rawPat + 7] = 0x74; $b[$rawPat + 8] = 0x10
    }
    return , $b
}

function Write-PE([byte[]]$b, [string]$name) { $p = Join-Path $work $name; [IO.File]::WriteAllBytes($p, $b); return $p }
function Read-PE([string]$p) { return [IO.File]::ReadAllBytes($p) }

# =====================================================================
Section "Integrity patch (synthetic PE)"

# 1) single validated site -> patched
$pe1Bytes = New-FakePE 1
$pe = Write-PE $pe1Bytes 'hd1.exe'
$r = Run-Engine @('-Action', 'Patch', '-Exe', $pe)
$bb = Read-PE $pe
Check ($r.Code -eq 0 -and $bb[0x227] -eq 0x90 -and $bb[0x228] -eq 0x90) "single site NOPped (74 10 -> 90 90)"
Check (Test-Path "$pe.bak") "backup .bak created"
# seek-write proof: the in-place patch changed EXACTLY the 2 JZ bytes and left every other byte intact
$diff = 0; for ($z = 0; $z -lt $pe1Bytes.Length; $z++) { if ($pe1Bytes[$z] -ne $bb[$z]) { $diff++ } }
Check ($diff -eq 2 -and $pe1Bytes[0x227] -ne $bb[0x227] -and $pe1Bytes[0x228] -ne $bb[0x228]) "patch changed EXACTLY 2 bytes (seek-write, no whole-file rewrite drift)"

# 2) idempotent: running again is a no-op success
$r2 = Run-Engine @('-Action', 'Patch', '-Exe', $pe)
Check ($r2.Code -eq 0 -and $r2.Out -match 'Already patched|Nothing to') "re-patch is idempotent"

# 3) restore from backup
$r3 = Run-Engine @('-Action', 'Patch', '-Exe', $pe, '-Restore')
$bb = Read-PE $pe
Check ($r3.Code -eq 0 -and $bb[0x227] -eq 0x74 -and $bb[0x228] -eq 0x10) "restore reverts to original bytes"

# 4) already-patched input is detected
$pe4 = Write-PE (New-FakePE 1 -PreNopFirst) 'hd4.exe'
$r4 = Run-Engine @('-Action', 'Patch', '-Exe', $pe4)
Check ($r4.Code -eq 0 -and $r4.Out -match 'Already patched') "pre-NOPped site recognised as already patched"

# 5) DryRun writes nothing
$pe5 = Write-PE (New-FakePE 1) 'hd5.exe'
$r5 = Run-Engine @('-Action', 'Patch', '-Exe', $pe5, '-DryRun')
$bb = Read-PE $pe5
Check ($r5.Code -eq 0 -and $bb[0x227] -eq 0x74 -and -not (Test-Path "$pe5.bak")) "DryRun leaves file + makes no backup"

# 6) multi-site: all validated sites patched (version drift / multiple checks)
$pe6 = Write-PE (New-FakePE 3) 'hd6.exe'
$r6 = Run-Engine @('-Action', 'Patch', '-Exe', $pe6)
$bb = Read-PE $pe6
$s0 = ($bb[0x227] -eq 0x90 -and $bb[0x228] -eq 0x90)
$s1 = ($bb[0x257] -eq 0x90 -and $bb[0x258] -eq 0x90)
$s2 = ($bb[0x287] -eq 0x90 -and $bb[0x288] -eq 0x90)
Check ($r6.Code -eq 0 -and $s0 -and $s1 -and $s2) "all 3 validated sites NOPped"

# 7) noise site (no anchor) is NOT patched, and with no valid site we refuse.
#    noise pattern starts at file 0x380: E8(.380) ..  84(.385) C0(.386) 74(.387) 10(.388)
$pe7 = Write-PE (New-FakePE 0 -Noise) 'hd7.exe'
$r7 = Run-Engine @('-Action', 'Patch', '-Exe', $pe7)
$bb = Read-PE $pe7
Check ($r7.Code -ne 0 -and $bb[0x387] -eq 0x74) "unvalidated lone candidate refused (no blind patch)"

# 8) noise alongside valid sites: only validated ones patched
$pe8 = Write-PE (New-FakePE 1 -Noise) 'hd8.exe'
$r8 = Run-Engine @('-Action', 'Patch', '-Exe', $pe8)
$bb = Read-PE $pe8
Check ($r8.Code -eq 0 -and $bb[0x227] -eq 0x90 -and $bb[0x387] -eq 0x74) "validated site patched, noise left intact"

# 9) -Force patches a lone unvalidated candidate (JZ at 0x387 -> 90 90)
$pe9 = Write-PE (New-FakePE 0 -Noise) 'hd9.exe'
$r9 = Run-Engine @('-Action', 'Patch', '-Exe', $pe9, '-Force')
$bb = Read-PE $pe9
Check ($r9.Code -eq 0 -and $bb[0x387] -eq 0x90 -and $bb[0x388] -eq 0x90) "-Force NOPs a single unvalidated candidate"

# =====================================================================
Section ".bstk disk mode (faithful global regex)"
$bstkText = @'
<BlueStacks>
  <Disk location="Root.vhd" type="Readonly" />
  <Disk location="fastboot.vdi" type="Normal" />
  <Disk location="extra.vhd" type="Readonly" />
</BlueStacks>
'@
$bstk = Join-Path $work 'inst.bstk'; Set-Content -LiteralPath $bstk -Value $bstkText -Encoding utf8
$r = Run-Engine @('-Action', 'DiskRW', '-Bstk', $bstk)
$t = Get-Content -LiteralPath $bstk -Raw
Check ($r.Code -eq 0 -and ($t -notmatch 'type="Readonly"') -and (([regex]::Matches($t, 'type="Normal"')).Count -eq 3)) "DiskRW: every Readonly -> Normal (global)"
$r = Run-Engine @('-Action', 'DiskRO', '-Bstk', $bstk)
$t = Get-Content -LiteralPath $bstk -Raw
Check ($r.Code -eq 0 -and ([regex]::Matches($t, 'type="Readonly"')).Count -eq 3 -and ($t -notmatch 'type="Normal"')) "DiskRO: every Normal -> Readonly (global)"
Check (Test-Path "$bstk.bak") ".bstk backup created"

# guard: a non-BlueStacks xml is left untouched
$bad = Join-Path $work 'bad.bstk'; Set-Content -LiteralPath $bad -Value '<x type="Readonly"/>' -Encoding utf8
$r = Run-Engine @('-Action', 'DiskRW', '-Bstk', $bad)
$t = Get-Content -LiteralPath $bad -Raw
Check ($r.Code -ne 0 -and $t -match 'type="Readonly"') "guard rejects non-BlueStacks .bstk"

# =====================================================================
Section "bluestacks.conf root flags"
$confText = @'
bst.feature.rooting="0"
bst.enable_adb_access="0"
bst.instance.Rvc64.enable_root_access="0"
bst.instance.Rvc64.display_name="Rooted"
bst.instance.Pie64.enable_root_access="0"
'@
$conf = Join-Path $work 'bluestacks.conf'; Set-Content -LiteralPath $conf -Value $confText -Encoding utf8
$r = Run-Engine @('-Action', 'ConfRoot', '-Conf', $conf, '-Instance', 'Rvc64')
$t = Get-Content -LiteralPath $conf -Raw
$c1 = $t -match 'bst\.instance\.Rvc64\.enable_root_access="1"'
$c2 = $t -match 'bst\.feature\.rooting="1"'
$c3 = $t -match 'bst\.enable_adb_access="1"'                        # GLOBAL adb enabled (valid key)
$c4 = $t -match 'bst\.instance\.Pie64\.enable_root_access="0"'      # OTHER instance untouched
# CRITICAL: must NOT invent the invalid per-instance adb key (it bricks BlueStacks startup)
$c5 = ($t -notmatch 'bst\.instance\.Rvc64\.enable_adb_access')
Check ($r.Code -eq 0 -and $c1 -and $c2 -and $c3 -and $c4 -and $c5) "ConfRoot sets root/rooting + GLOBAL adb, adds NO unknown keys"
# regression: the seed was written WITH a BOM; ConfRoot must output UTF-8 with NO BOM
# (a BOM makes BlueStacks fail "Failed to read configuration file").
$cbytes = [IO.File]::ReadAllBytes($conf)
$noBom = -not ($cbytes.Length -ge 3 -and $cbytes[0] -eq 0xEF -and $cbytes[1] -eq 0xBB -and $cbytes[2] -eq 0xBF)
Check $noBom "ConfRoot writes UTF-8 WITHOUT a BOM (BlueStacks-safe)"
$r = Run-Engine @('-Action', 'ConfUnroot', '-Conf', $conf, '-Instance', 'Rvc64')
$t = Get-Content -LiteralPath $conf -Raw
Check ($r.Code -eq 0 -and ($t -match 'bst\.instance\.Rvc64\.enable_root_access="0"') -and ($t -match 'bst\.feature\.rooting="0"')) "ConfUnroot reverts flags to 0"

# =====================================================================
Section "DataDir normalization (BaseDir) - version drift"
$bd = Join-Path $work 'bsroot'
New-Item -ItemType Directory "$bd\BlueStacks_nxt\Engine" -Force | Out-Null
Set-Content "$bd\BlueStacks_nxt\bluestacks.conf" 'x' -Encoding ascii
# newer BlueStacks: DataDir points INTO Engine -> must normalize to the parent
$r = Run-Engine @('-Action', 'BaseDir', '-DataDir', "$bd\BlueStacks_nxt\Engine")
Check ($r.Code -eq 0 -and ($r.Out.Trim() -ieq "$bd\BlueStacks_nxt")) "DataDir ...\Engine normalized to base (conf folder)"
# DataDir already the base
$r = Run-Engine @('-Action', 'BaseDir', '-DataDir', "$bd\BlueStacks_nxt")
Check ($r.Out.Trim() -ieq "$bd\BlueStacks_nxt") "DataDir already-base kept as-is"
# only UserDef known
$r = Run-Engine @('-Action', 'BaseDir', '-UserDef', "$bd\BlueStacks_nxt")
Check ($r.Out.Trim() -ieq "$bd\BlueStacks_nxt") "UserDefinedDir used when DataDir missing"

# =====================================================================
Section "Embedded su payload round-trip"
$hasBlob = (Test-Path -LiteralPath $Cmd) -and ((Get-Content -LiteralPath $Cmd -Raw) -match ('__BSR_SU_' + 'BEGIN__'))
if ($hasBlob) {
    $blob = Join-Path $work 'su.out'
    $r = Run-Engine @('-Action', 'ExtractSu', '-SelfPath', $Cmd, '-OutFile', $blob)
    if ($r.Code -eq 0 -and (Test-Path $blob)) {
        $blobBytes = [IO.File]::ReadAllBytes($blob)
        $sha = (([System.Security.Cryptography.SHA256]::Create().ComputeHash($blobBytes) | ForEach-Object { $_.ToString('X2') }) -join '')
        $expect = '185106357CFC0D1DB4B8EFB033DE863F437850437E0EF6B62630C05F291B4902'
        $len = (Get-Item $blob).Length
        $magic = [IO.File]::ReadAllBytes($blob)[0..3] -join ','
        Check ($sha -eq $expect) "su decodes to expected SHA-256 ($len bytes)"
        Check ($magic -eq '127,69,76,70') "su starts with ELF magic 7F 45 4C 46"
    }
    else { No "ExtractSu failed: $($r.Out)" }
}
else { Sk "su round-trip (blueStackRoot.cmd has no embedded su blob yet)" }

# =====================================================================
Section "cmd bootstrap: extract embedded engine and run it"
if ($hasBlob) {
    # replicate the .cmd :extract_engine one-liner against the built cmd
    $eng = Join-Path $work 'extracted_engine.ps1'
    $env:BSR_SELF = $Cmd; $env:BSR_ENGINE = $eng
    $extract = "`$ErrorActionPreference='Stop'; `$t=[IO.File]::ReadAllText(`$env:BSR_SELF); `$b='__BSR_ENGINE_'+'BEGIN__'; `$e='__BSR_ENGINE_'+'END__'; `$i=`$t.IndexOf(`$b); `$j=`$t.IndexOf(`$e); if(`$i -lt 0 -or `$j -le `$i){throw 'no engine'}; `$i=`$t.IndexOf([char]10,`$i)+1; [IO.File]::WriteAllText(`$env:BSR_ENGINE,`$t.Substring(`$i,`$j-`$i))"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $extract 2>&1 | Out-Null
    $extractedOk = (Test-Path $eng) -and ((Get-Content $eng -Raw) -match 'function Invoke-Patch') -and ((Get-Content $eng -Raw) -notmatch ('__BSR_ENGINE_' + 'END__'))
    Check $extractedOk "engine extracted cleanly from the .cmd (no markers leaked)"
    if ($extractedOk) {
        $pe = Write-PE (New-FakePE 1) 'boot.exe'
        $rb = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $eng -Action Patch -Exe $pe 2>&1 | Out-String
        $bb = Read-PE $pe
        Check ($bb[0x227] -eq 0x90 -and $bb[0x228] -eq 0x90) "extracted engine patches a PE (full bootstrap chain works)"
    }
}
else { Sk "cmd bootstrap (no embedded engine/su yet)" }

# =====================================================================
Section "ext4 install/remove via debugfs"
# auto-discover the repo's bundled debugfs + an mke2fs (so this tier runs by default)
if (-not $Debugfs) { $d = Join-Path $repo 'tools\debugfs\debugfs.exe'; if (Test-Path $d) { $Debugfs = $d } }
if (-not $Mke2fs) {
    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\mke2fs.exe'),
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools.backup\mke2fs.exe'))) {
        if (Test-Path $p) { $Mke2fs = $p; break }
    }
    if (-not $Mke2fs) { $c = Get-Command mke2fs.exe -EA SilentlyContinue; if ($c) { $Mke2fs = $c.Source } }
}

# debugfs always prints its banner to stderr -> never let that throw in the parent
function Debugfs-Stat([string]$exe, [string]$img, [string]$path) {
    $imgF = $img -replace '\\', '/'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& $exe -R "stat $path" $imgF 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
}
function New-Ext4([string]$img, [int]$mb) {
    & powershell.exe -NoProfile -Command "`$f=[IO.File]::Open('$img','Create'); `$f.SetLength(${mb}MB); `$f.Close()" | Out-Null
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Mke2fs -F -t ext4 -q $img 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }   # DEFAULT features incl metadata_csum
}

if ($Debugfs -and $Mke2fs -and (Test-Path $Debugfs) -and (Test-Path $Mke2fs) -and (Test-Path $Cmd) -and $hasBlob) {
    $img = Join-Path $work 'fs.img'

    # install via the engine's real Edit-Ext4 path, explicit bundled debugfs
    New-Ext4 $img 96
    $ri = Run-Engine @('-Action', 'TestExt4', '-Img', $img, '-SelfPath', $Cmd, '-Debugfs', $Debugfs)
    $stat = Debugfs-Stat $Debugfs $img '/android/system/xbin/su'
    Check ($ri.Code -eq 0 -and $stat -match '(?im)Mode:\s*0*6755') "su installed into ext4 (mode 06755 setuid) [explicit debugfs]"
    Check ($stat -match '(?im)User:\s*0\b' -and $stat -match '(?im)Group:\s*0\b') "su owned by uid 0 / gid 0"

    # remove via the engine
    $rr = Run-Engine @('-Action', 'TestExt4', '-Img', $img, '-SelfPath', $Cmd, '-Debugfs', $Debugfs, '-Restore')
    $stat2 = Debugfs-Stat $Debugfs $img '/android/system/xbin/su'
    Check ($rr.Code -eq 0 -and $stat2 -match 'File not found') "su removed from ext4"

    # install again with NO -Debugfs => engine must extract the EMBEDDED debugfs from the .cmd
    powershell.exe -NoProfile -Command "Remove-Item -Recurse -Force (Join-Path `$env:TEMP 'bsr_work\debugfs') -EA SilentlyContinue" | Out-Null
    New-Ext4 $img 96
    $re = Run-Engine @('-Action', 'TestExt4', '-Img', $img, '-SelfPath', $Cmd)
    Check ($re.Code -eq 0 -and $re.Out -match 'embedded debugfs') "engine extracts EMBEDDED debugfs from the .cmd and installs su"
}
else { Sk "ext4/debugfs test (need tools\debugfs\debugfs.exe + mke2fs + built cmd)" }

# =====================================================================
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
$sumColor = if ($script:fail) { 'Red' } else { 'Green' }
Write-Host ("  PASS={0}  FAIL={1}  SKIP={2}" -f $script:pass, $script:fail, $script:skip) -ForegroundColor $sumColor
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($script:fail -gt 0))
