<#
  Patch-HDPlayerIntegrity.ps1

  Pure-PowerShell, ZERO-dependency reimplementation of the HD-Player.exe disk-integrity
  patch performed by BstkRooter.exe (function 0x1400203f0, "Fix Illegally Tampered").

  It replaces Bypass_Integrity_Check_Semantic.py so you no longer need
  python + pefile + capstone (the unreliable part).

  WHAT IT DOES (exactly what BstkRooter.exe does):
    1. Backs up HD-Player.exe -> HD-Player.exe.bak  (only if .bak does not already exist).
    2. Loads the whole file, locates the .text section from the PE headers.
    3. Searches .text for the byte pattern:
            E8 ?? ?? ?? ??   84 C0   74 ??
            (CALL rel32)     (TEST AL,AL)  (JZ rel8)
       i.e. byte[t]=0x84, byte[t+1]=0xC0, byte[t+2]=0x74, byte[t-5]=0xE8
       where t = offset of the TEST instruction.
    4. If >1 match, disambiguates by looking for a RIP-relative LEA to
       "Verified the disk integrity!" or "Failed to verify the disk integrity!"
       within +/-0xC8 bytes of the candidate (BstkRooter's "validated with verify/fail string").
    5. NOPs the conditional jump:  byte[t+2] and byte[t+3]  ->  0x90 0x90.
    6. Writes the whole file back.

  This is BstkRooter's "Strategy 4 (full .text scan) + validation". Strategies 1-3 only
  narrow the search window around the anchor strings; the byte pattern and the NOP are identical,
  so the full scan + validation below reaches the same site.

  USAGE:
    powershell -ExecutionPolicy Bypass -File Patch-HDPlayerIntegrity.ps1
    powershell -ExecutionPolicy Bypass -File Patch-HDPlayerIntegrity.ps1 -Exe "D:\BlueStacks_nxt\HD-Player.exe"
    powershell -ExecutionPolicy Bypass -File Patch-HDPlayerIntegrity.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File Patch-HDPlayerIntegrity.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$Exe = "$env:ProgramFiles\BlueStacks_nxt\HD-Player.exe",
    [switch]$Restore,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Status([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Status "[!] HD-Player.exe not found: $Exe" Red
    Write-Status "    Pass the correct path with -Exe `"<InstallDir>\HD-Player.exe`"" Yellow
    exit 1
}

$bak = "$Exe.bak"

if ($Restore) {
    if (-not (Test-Path -LiteralPath $bak)) { Write-Status "[!] No backup to restore: $bak" Red; exit 1 }
    Copy-Item -LiteralPath $bak -Destination $Exe -Force
    Write-Status "[+] Restored $Exe from $bak" Green
    exit 0
}

# Stop the emulator so the file is writable (BstkRooter kills these first).
foreach ($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','BlueStacksHelper') {
    Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- Load file & parse the PE just enough to find .text and ImageBase ----
$b = [System.IO.File]::ReadAllBytes($Exe)
Write-Status "[*] Loaded $Exe ($($b.Length) bytes)" Gray
if ($b.Length -lt 0x200) { Write-Status "[!] File too small for PE." Red; exit 1 }

$e_lfanew = [BitConverter]::ToInt32($b, 0x3C)
if ($b[$e_lfanew] -ne 0x50 -or $b[$e_lfanew+1] -ne 0x45) { Write-Status "[!] Invalid PE header." Red; exit 1 }  # 'P','E'

$numSections = [BitConverter]::ToUInt16($b, $e_lfanew + 6)
$sizeOptHdr  = [BitConverter]::ToUInt16($b, $e_lfanew + 20)
$optHdr      = $e_lfanew + 24
$magic       = [BitConverter]::ToUInt16($b, $optHdr)              # 0x20B = PE32+
if ($magic -eq 0x20B) { $imageBase = [BitConverter]::ToUInt64($b, $optHdr + 24) }
else                  { $imageBase = [BitConverter]::ToUInt32($b, $optHdr + 28) }

$secTable = $optHdr + $sizeOptHdr
$textVA = $null; $textRaw = $null; $textRawSize = $null
$sections = @()
for ($i = 0; $i -lt $numSections; $i++) {
    $s    = $secTable + ($i * 40)
    $name = ([System.Text.Encoding]::ASCII.GetString($b, $s, 8)).TrimEnd([char]0)
    $va   = [BitConverter]::ToUInt32($b, $s + 12)
    $rs   = [BitConverter]::ToUInt32($b, $s + 16)
    $pr   = [BitConverter]::ToUInt32($b, $s + 20)
    $sections += [pscustomobject]@{ Name=$name; VA=$va; RawSize=$rs; RawPtr=$pr }
    if ($name -eq '.text') { $textVA = $va; $textRaw = $pr; $textRawSize = $rs }
}
if ($null -eq $textRaw) { Write-Status "[!] .text section not found." Red; exit 1 }

# raw file offset -> RVA (search across sections)
function RawToRva([int]$raw, $sections) {
    foreach ($s in $sections) {
        if ($raw -ge $s.RawPtr -and $raw -lt ($s.RawPtr + $s.RawSize)) { return [int]($s.VA + ($raw - $s.RawPtr)) }
    }
    return -1
}
# find ascii string (NUL-terminated) raw offset, then its RVA
function StringRva([byte[]]$b, [string]$text, $sections) {
    $needle = [System.Text.Encoding]::ASCII.GetBytes($text + "`0")
    for ($i = 0; $i -le $b.Length - $needle.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($b[$i+$j] -ne $needle[$j]) { $ok = $false; break } }
        if ($ok) { return (RawToRva $i $sections) }
    }
    return -1
}

$verifyRva = StringRva $b "Verified the disk integrity!" $sections
$failRva   = StringRva $b "Failed to verify the disk integrity!" $sections

# ---- Strategy 4: scan .text for  E8 ?? ?? ?? ??  84 C0  74 ??  ----
$textStart = [int]$textRaw
$textEnd   = [int]($textRaw + $textRawSize)
$candidates = New-Object System.Collections.Generic.List[int]
for ($t = $textStart + 5; $t -lt $textEnd - 3; $t++) {
    if ($b[$t] -eq 0x84 -and $b[$t+1] -eq 0xC0 -and $b[$t+2] -eq 0x74 -and $b[$t-5] -eq 0xE8) {
        [void]$candidates.Add($t)   # t = offset of TEST AL,AL
    }
}
Write-Status "[*] Found $($candidates.Count) candidate site(s) (CALL; TEST AL,AL; JZ)" Gray

if ($candidates.Count -eq 0) { Write-Status "[!] Patch site not found. (BlueStacks version may differ.)" Red; exit 1 }

# Does a RIP-relative LEA to the verify/fail string sit within +/-0xC8 of $t ?
function NearVerifyString([byte[]]$b, [int]$t, [int]$textVA, [int]$textRaw, [int]$verifyRva, [int]$failRva) {
    $lo = [Math]::Max($textRaw, $t - 0xC8); $hi = $t + 0xC8
    for ($p = $lo; $p -lt $hi - 6; $p++) {
        $rex = $b[$p]
        if ($rex -ne 0x48 -and $rex -ne 0x4C -and $rex -ne 0x49 -and $rex -ne 0x4D) { continue }
        if ($b[$p+1] -ne 0x8D) { continue }                         # LEA opcode
        if (($b[$p+2] -band 0xC7) -ne 0x05) { continue }            # mod=00, rm=101 => [rip+disp32]
        $disp = [BitConverter]::ToInt32($b, $p+3)
        $insnRva = $textVA + (($p + 7) - $textRaw)                   # RVA of the byte AFTER the 7-byte LEA
        $target  = $insnRva + $disp
        if ($target -eq $verifyRva -or $target -eq $failRva) { return $true }
    }
    return $false
}

$site = $null; $how = ''
if ($candidates.Count -eq 1) {
    $site = $candidates[0]; $how = '.text scan (unique match)'
} else {
    foreach ($c in $candidates) {
        if (NearVerifyString $b $c $textVA $textRaw $verifyRva $failRva) { $site = $c; $how = '.text scan (validated with verify/fail string)'; break }
    }
    if ($null -eq $site) { Write-Status "[!] Multiple candidates, none validated. Aborting to stay safe." Red; exit 1 }
}

$rvaSite = RawToRva $site $sections
$va = $imageBase + $rvaSite
Write-Status ("[+] Patch site at file 0x{0:X} (VA 0x{1:X}) via {2}: {3:X2} {4:X2} {5:X2} {6:X2}" -f `
    $site, $va, $how, $b[$site], $b[$site+1], $b[$site+2], $b[$site+3]) Green

# already patched?
if ($b[$site+2] -eq 0x90 -and $b[$site+3] -eq 0x90) { Write-Status "[~] Already patched. Nothing to do." Yellow; exit 0 }

Write-Status ("[*] Patching at 0x{0:X}: {1:X2} {2:X2} -> 90 90" -f ($site+2), $b[$site+2], $b[$site+3]) Cyan
if ($DryRun) { Write-Status "[+] Dry run - no file written." Yellow; exit 0 }

# backup (.bak), only create once - faithful to BstkRooter
if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Exe -Destination $bak -Force; Write-Status "[*] Backup created: $bak" Gray }
else { Write-Status "[*] Backup already exists, skipping copy." Gray }

$b[$site+2] = 0x90
$b[$site+3] = 0x90
try { [System.IO.File]::WriteAllBytes($Exe, $b) }
catch { Write-Status "[!] Failed to patch - run as Administrator / close the emulator first." Red; exit 1 }

Write-Status "[+] Patched successfully!" Green
exit 0
