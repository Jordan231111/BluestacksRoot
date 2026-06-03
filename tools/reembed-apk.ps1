<#
  reembed-apk.ps1 -- replace the embedded Magisk APK inside blueStackRoot.cmd with a new APK file.

  The APK lives between the __BSR_APK_BEGIN__ / __BSR_APK_END__ marker lines as RAW base64 (the engine's
  Ensure-MagiskApk in bsr_magisk.ps1 base64-DECODES it directly -- it is NOT gzipped, because an APK is
  already a compressed ZIP and gzip would not shrink it). This splices the new base64 in at the BYTE level
  so every other embedded blob (engine, magisk orchestrator, su, debugfs) is left byte-for-byte untouched,
  then VERIFIES by extracting the block back out, decoding it, and comparing its SHA-256 + length to the
  source APK -- the proof the swap is exact.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\reembed-apk.ps1 -Apk "<path to .apk>"
#>
[CmdletBinding()]
param(
    [string]$Cmd,
    [Parameter(Mandatory = $true)][string]$Apk,
    [int]$Wrap = 4096
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Redact-UserPath($value) {
    if ($null -eq $value) { return $value }
    $s = [string]$value
    $s = $s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])', '${1}xxxxx'
    $s = $s -replace '(?i)(/Users/)([^/]+)(?=$|/)', '${1}xxxxx'
    $s
}
function Say([string]$m, [string]$c = 'Gray') { Write-Host (Redact-UserPath $m) -ForegroundColor $c }
trap {
    Say "[!] $($_.Exception.Message)" Red
    exit 1
}

if (-not $Cmd) { $Cmd = Join-Path $Here '..\blueStackRoot.cmd' }
$Cmd = (Resolve-Path $Cmd).Path
$Apk = (Resolve-Path $Apk).Path

function Find-Bytes([byte[]]$h, [byte[]]$n, [int]$start = 0) {
    for ($i = $start; $i -le $h.Length - $n.Length; $i++) {
        $ok = $true
        for ($k = 0; $k -lt $n.Length; $k++) { if ($h[$i + $k] -ne $n[$k]) { $ok = $false; break } }
        if ($ok) { return $i }
    }
    return -1
}
function Sha256Hex([byte[]]$b) { (([System.Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') }

# --- read source APK, hash it, base64 + wrap (CRLF, matching the rest of the .cmd) ---
$apkBytes = [System.IO.File]::ReadAllBytes($Apk)
$srcSha = Sha256Hex $apkBytes
$b64 = [Convert]::ToBase64String($apkBytes)
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $b64.Length; $i += $Wrap) {
    [void]$sb.Append($b64.Substring($i, [Math]::Min($Wrap, $b64.Length - $i)))
    [void]$sb.Append("`r`n")   # one CRLF after each line -> exactly one CRLF before the END marker
}
$newContent = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())

# --- byte-level splice between __BSR_APK_BEGIN__ / __BSR_APK_END__ ---
$bytes = [System.IO.File]::ReadAllBytes($Cmd)
$orig = $bytes.Length
$enc = [System.Text.Encoding]::ASCII
$beg = $enc.GetBytes('__BSR_APK_BEGIN__'); $end = $enc.GetBytes('__BSR_APK_END__')
$bi = Find-Bytes $bytes $beg; if ($bi -lt 0) { throw '__BSR_APK_BEGIN__ marker not found' }
$nl = $bi; while ($nl -lt $bytes.Length -and $bytes[$nl] -ne 10) { $nl++ }   # LF that ends the BEGIN line
$contentStart = $nl + 1
$ei = Find-Bytes $bytes $end $contentStart; if ($ei -lt 0) { throw '__BSR_APK_END__ marker not found' }
$out = New-Object byte[] ($contentStart + $newContent.Length + ($bytes.Length - $ei))
[Array]::Copy($bytes, 0, $out, 0, $contentStart)
[Array]::Copy($newContent, 0, $out, $contentStart, $newContent.Length)
[Array]::Copy($bytes, $ei, $out, $contentStart + $newContent.Length, $bytes.Length - $ei)
[System.IO.File]::WriteAllBytes($Cmd, $out)
Say ("re-embedded APK: {0:N0} -> {1:N0} bytes (delta {2:N0})" -f $orig, $out.Length, ($out.Length - $orig))

# --- verify: extract the block back out, strip non-base64, decode, compare SHA-256 + length ---
$t = [System.IO.File]::ReadAllText($Cmd)
$b = '__BSR_APK_' + 'BEGIN__'; $e = '__BSR_APK_' + 'END__'
$i = $t.IndexOf($b); $j = $t.IndexOf($e)
$i = $t.IndexOf([char]10, $i) + 1
$emb = ($t.Substring($i, $j - $i) -replace '[^A-Za-z0-9+/=]', '')
$dec = [Convert]::FromBase64String($emb)
$embSha = Sha256Hex $dec
Say ("source APK : {0:N0} bytes  sha256 {1}" -f $apkBytes.Length, $srcSha)
Say ("embedded   : {0:N0} bytes  sha256 {1}" -f $dec.Length, $embSha)
if ($dec.Length -eq $apkBytes.Length -and $embSha -ceq $srcSha) {
    Say '  [OK] embedded APK round-trips to the source APK (SHA-256 + length match).' Green
    exit 0
}
Say '  [FAIL] embedded APK does NOT match the source APK.' Red
exit 1
