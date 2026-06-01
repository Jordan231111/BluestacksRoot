<#
  Check-Embedded-Sync.ps1 -- CI guard for the single-file build.

  blueStackRoot.cmd carries the engine and the Magisk orchestrator embedded between marker lines.
  They are authored in tools\bsr_engine.ps1 / tools\bsr_magisk.ps1 and spliced in by tools\reembed.ps1.
  If someone edits a tools\*.ps1 without re-running reembed, the .cmd silently ships stale logic.

  This test extracts the embedded blocks exactly like the .cmd does at run time and compares them to
  the tools\ sources (newline-normalised).  Exit code 1 on any drift, 0 when in sync.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Check-Embedded-Sync.ps1
#>
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
$cmd  = Join-Path $repo 'blueStackRoot.cmd'
if (-not (Test-Path -LiteralPath $cmd)) { throw "blueStackRoot.cmd not found: $cmd" }
$t = [IO.File]::ReadAllText($cmd)

function Norm([string]$s) { ($s -replace "`r`n", "`n").TrimEnd("`n", " ", "`t") }
function Extract([string]$tag) {
    $b = '__BSR_' + $tag + '_' + 'BEGIN__'; $e = '__BSR_' + $tag + '_' + 'END__'
    $i = $t.IndexOf($b); $j = $t.IndexOf($e)
    if ($i -lt 0 -or $j -le $i) { throw "embedded block $tag not found in blueStackRoot.cmd" }
    $i = $t.IndexOf([char]10, $i) + 1
    return $t.Substring($i, $j - $i)
}

$fail = 0
foreach ($p in @(@('ENGINE', 'tools\bsr_engine.ps1'), @('MAGISK', 'tools\bsr_magisk.ps1'))) {
    $src = Join-Path $repo $p[1]
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "  [FAIL] source missing: $($p[1])" -ForegroundColor Red; $fail++; continue }
    $emb = Norm (Extract $p[0])
    $on  = Norm ([IO.File]::ReadAllText($src))
    if ($emb -eq $on) {
        Write-Host ("  [PASS] {0,-7} embedded == {1} ({2} chars)" -f $p[0], $p[1], $emb.Length) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0,-7} embedded != {1} (embedded {2}, source {3} chars) -- run tools\reembed.ps1" -f $p[0], $p[1], $emb.Length, $on.Length) -ForegroundColor Red
        $fail++
    }
}

# --- embedded Magisk APK: decode the base64 blob and verify its SHA-256 (guards against APK drift;
#     the APK is re-embedded by tools\reembed-apk.ps1, which round-trips this same hash). ---
$ApkSha256 = 'e01648059a412fd9946a99801260dfde81c99def2512f161657faf404a280e05'
try {
    $apkB64 = (Extract 'APK') -replace '[^A-Za-z0-9+/=]', ''
    $apkBytes = [Convert]::FromBase64String($apkB64)
    $apkSha = (([System.Security.Cryptography.SHA256]::Create().ComputeHash($apkBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    if ($apkSha -ceq $ApkSha256) {
        Write-Host ("  [PASS] {0,-7} embedded APK sha256 == {1} ({2:N0} bytes)" -f 'APK', $ApkSha256, $apkBytes.Length) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] {0,-7} embedded APK sha256 {1} != expected -- re-run tools\reembed-apk.ps1" -f 'APK', $apkSha) -ForegroundColor Red
        $fail++
    }
}
catch {
    Write-Host ("  [FAIL] {0,-7} could not decode embedded APK: {1}" -f 'APK', $_.Exception.Message) -ForegroundColor Red
    $fail++
}

Write-Host ""
if ($fail) { Write-Host "RESULT: embedded blocks OUT OF SYNC ($fail) -- re-run tools\reembed.ps1 / reembed-apk.ps1 and commit blueStackRoot.cmd" -ForegroundColor Red; exit 1 }
Write-Host "RESULT: embedded blocks in sync with tools\ sources" -ForegroundColor Green
exit 0
