<#
  build.ps1  --  assemble the single-file blueStackRoot.cmd

  Output  = tools\blueStackRoot.head.cmd   (batch orchestrator, hand-written)
          + __BSR_ENGINE_BEGIN__ .. tools\bsr_engine.ps1 .. __BSR_ENGINE_END__
          + __BSR_SU_BEGIN__ .. gzip+base64(su) .. __BSR_SU_END__

  The su is .NET-GZip compressed so the engine's GZipStream can decode it, and its
  SHA-256 is verified against the known decrypted-su hash before embedding.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1
#>
[CmdletBinding()]
param(
    [string]$Head,
    [string]$Engine,
    [string]$Su,
    [string]$DebugfsDir,
    [string]$Out,
    [int]$Wrap = 120
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$repo = Split-Path -Parent $here
if (-not $Head) { $Head = Join-Path $here 'blueStackRoot.head.cmd' }
if (-not $Engine) { $Engine = Join-Path $here 'bsr_engine.ps1' }
if (-not $Su) { $Su = Join-Path $repo 'recovered\BstkRooter\embedded_su_decrypted' }
if (-not $DebugfsDir) { $DebugfsDir = Join-Path $here 'debugfs' }
if (-not $Out) { $Out = Join-Path $repo 'blueStackRoot.cmd' }

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

foreach ($f in @($Head, $Engine, $Su)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing input: $f" } }

$expectSha = '185106357CFC0D1DB4B8EFB033DE863F437850437E0EF6B62630C05F291B4902'

function To-CRLF([string]$s) { ($s -replace "`r`n", "`n") -replace "`n", "`r`n" }

# --- su: verify, compress (.NET GZip), base64, wrap ---
$suBytes = [System.IO.File]::ReadAllBytes($Su)
$sha = (([System.Security.Cryptography.SHA256]::Create().ComputeHash($suBytes) | ForEach-Object { $_.ToString('X2') }) -join '')
if ($sha -ne $expectSha) { throw "su payload SHA-256 mismatch:`n  expected $expectSha`n  got      $sha`n  ($Su)" }
Say "su        : $($suBytes.Length) bytes  sha256 OK" Green

$ms = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$gz.Write($suBytes, 0, $suBytes.Length); $gz.Dispose()
$gzBytes = $ms.ToArray(); $ms.Dispose()
$b64 = [Convert]::ToBase64String($gzBytes)
Say "compressed: $($gzBytes.Length) bytes  ->  base64 $($b64.Length) chars" Gray

$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $b64.Length; $i += $Wrap) {
    $n = [Math]::Min($Wrap, $b64.Length - $i)
    [void]$sb.AppendLine($b64.Substring($i, $n))
}
$b64wrapped = $sb.ToString().TrimEnd("`r", "`n")

function Wrap-B64([string]$b64, [int]$w) {
    $s = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $b64.Length; $i += $w) {
        [void]$s.AppendLine($b64.Substring($i, [Math]::Min($w, $b64.Length - $i)))
    }
    return $s.ToString().TrimEnd("`r", "`n")
}

# --- debugfs bundle: zip the folder contents (flat), base64, wrap ---
$dfsB64crlf = $null
if (Test-Path -LiteralPath $DebugfsDir) {
    $need = @('debugfs.exe', 'cygwin1.dll')
    foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $DebugfsDir $n))) { throw "debugfs bundle incomplete: missing $n in $DebugfsDir" } }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmpZip = Join-Path $env:TEMP ("bsr_dfs_" + $PID + ".zip")
    if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force }
    # includeBaseDirectory=$false -> entries are bare file names (debugfs.exe, cyg*.dll)
    [System.IO.Compression.ZipFile]::CreateFromDirectory($DebugfsDir, $tmpZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $zb = [System.IO.File]::ReadAllBytes($tmpZip); Remove-Item -LiteralPath $tmpZip -Force
    $dfsB64 = [Convert]::ToBase64String($zb)
    $dfsB64crlf = To-CRLF (Wrap-B64 $dfsB64 $Wrap)
    Say "debugfs   : zip $($zb.Length) bytes  ->  base64 $($dfsB64.Length) chars (embedded)" Green
}
else {
    Say "debugfs   : $DebugfsDir not found -- building WITHOUT the embedded offline fallback." Yellow
}

# --- assemble ---
$headTxt = To-CRLF ([System.IO.File]::ReadAllText($Head))
$engTxt = To-CRLF ([System.IO.File]::ReadAllText($Engine))
$b64crlf = To-CRLF $b64wrapped

$nl = "`r`n"
$parts = New-Object System.Collections.Generic.List[string]
$parts.Add($headTxt.TrimEnd("`r", "`n"))
$parts.Add('__BSR_ENGINE_BEGIN__'); $parts.Add($engTxt.TrimEnd("`r", "`n")); $parts.Add('__BSR_ENGINE_END__')
$parts.Add('__BSR_SU_BEGIN__'); $parts.Add($b64crlf); $parts.Add('__BSR_SU_END__')
if ($dfsB64crlf) { $parts.Add('__BSR_DFS_BEGIN__'); $parts.Add($dfsB64crlf); $parts.Add('__BSR_DFS_END__') }
$parts.Add('')
$final = ($parts -join $nl)

# write without BOM (cmd dislikes a UTF-8 BOM on the first line)
[System.IO.File]::WriteAllText($Out, $final, (New-Object System.Text.UTF8Encoding($false)))
$sz = (Get-Item -LiteralPath $Out).Length
Say "wrote     : $Out  ($([math]::Round($sz/1MB,2)) MB)" Green
