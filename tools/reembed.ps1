<#
  reembed.ps1 -- splice the current tools\bsr_engine.ps1 + tools\bsr_magisk.ps1 into blueStackRoot.cmd
  between their __BSR_ENGINE_* / __BSR_MAGISK_* marker lines, at the BYTE level so the large embedded
  su / debugfs / APK base64 blocks (and every other byte) are left untouched. Verifies after writing.
#>
[CmdletBinding()]
param(
    [string]$Cmd,
    [string]$Engine,
    [string]$Magisk
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Cmd)    { $Cmd    = Join-Path $Here '..\blueStackRoot.cmd' }
if (-not $Engine) { $Engine = Join-Path $Here 'bsr_engine.ps1' }
if (-not $Magisk) { $Magisk = Join-Path $Here 'bsr_magisk.ps1' }
$Cmd = (Resolve-Path $Cmd).Path; $Engine = (Resolve-Path $Engine).Path; $Magisk = (Resolve-Path $Magisk).Path

function Find-Bytes([byte[]]$h, [byte[]]$n, [int]$start = 0) {
    for ($i = $start; $i -le $h.Length - $n.Length; $i++) {
        $ok = $true
        for ($k = 0; $k -lt $n.Length; $k++) { if ($h[$i + $k] -ne $n[$k]) { $ok = $false; break } }
        if ($ok) { return $i }
    }
    return -1
}
function Splice-Block([byte[]]$bytes, [string]$tok, [string]$file) {
    $enc = [Text.Encoding]::ASCII
    $beg = $enc.GetBytes("__BSR_${tok}_BEGIN__"); $end = $enc.GetBytes("__BSR_${tok}_END__")
    $bi = Find-Bytes $bytes $beg; if ($bi -lt 0) { throw "BEGIN marker for $tok not found" }
    $nl = $bi; while ($nl -lt $bytes.Length -and $bytes[$nl] -ne 10) { $nl++ }   # newline after BEGIN line
    $contentStart = $nl + 1
    $ei = Find-Bytes $bytes $end $contentStart; if ($ei -lt 0) { throw "END marker for $tok not found" }
    $newRaw = [IO.File]::ReadAllBytes($file)
    $len = $newRaw.Length; while ($len -gt 0 -and ($newRaw[$len - 1] -eq 10 -or $newRaw[$len - 1] -eq 13)) { $len-- }
    $newContent = New-Object byte[] ($len + 2)
    [Array]::Copy($newRaw, 0, $newContent, 0, $len); $newContent[$len] = 13; $newContent[$len + 1] = 10  # exactly one CRLF before END
    $out = New-Object byte[] ($contentStart + $newContent.Length + ($bytes.Length - $ei))
    [Array]::Copy($bytes, 0, $out, 0, $contentStart)
    [Array]::Copy($newContent, 0, $out, $contentStart, $newContent.Length)
    [Array]::Copy($bytes, $ei, $out, $contentStart + $newContent.Length, $bytes.Length - $ei)
    return , $out
}

$bytes = [IO.File]::ReadAllBytes($Cmd)
$orig = $bytes.Length
$bytes = Splice-Block $bytes 'MAGISK' $Magisk    # splice the LATER block first so earlier offsets don't move
$bytes = Splice-Block $bytes 'ENGINE' $Engine
[IO.File]::WriteAllBytes($Cmd, $bytes)
Write-Host ("re-embedded: {0} -> {1} bytes" -f $orig, $bytes.Length)

# ---- verify: extract each block back out and compare to the source (ignoring trailing EOL) ----
function Extract([string]$text, [string]$tok) {
    $b = "__BSR_${tok}_BEGIN__"; $e = "__BSR_${tok}_END__"
    $i = $text.IndexOf($b); $j = $text.IndexOf($e)
    $i = $text.IndexOf([char]10, $i) + 1
    return $text.Substring($i, $j - $i)
}
$t = [IO.File]::ReadAllText($Cmd)
$bad = $false
foreach ($p in @(@('ENGINE', $Engine), @('MAGISK', $Magisk))) {
    $emb = (Extract $t $p[0]).TrimEnd("`r", "`n")
    $src = ([IO.File]::ReadAllText($p[1])).TrimEnd("`r", "`n")
    if ($emb -ceq $src) { Write-Host "  [OK] embedded $($p[0]) matches tools source ($($src.Length) chars)" -ForegroundColor Green }
    else { Write-Host "  [MISMATCH] embedded $($p[0]) != source" -ForegroundColor Red; $bad = $true }
}
exit ([int]$bad)
