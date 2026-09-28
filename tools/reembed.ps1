<#
  reembed.ps1 -- embed the current engine, Magisk orchestrator, and shared host helpers in
  blueStackRoot.cmd; also refresh the helpers in debug.cmd. Splice at the byte level so the
  su / debugfs / APK payload blocks stay unchanged. Normalize batch line endings and verify.
#>
[CmdletBinding()]
param(
    [string]$Cmd,
    [string]$Engine,
    [string]$Magisk,
    [string]$HostHelpers,
    [string]$Diagnostic
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

if (-not $Cmd)    { $Cmd    = Join-Path $Here '..\blueStackRoot.cmd' }
if (-not $Engine) { $Engine = Join-Path $Here 'bsr_engine.ps1' }
if (-not $Magisk) { $Magisk = Join-Path $Here 'bsr_magisk.ps1' }
if (-not $HostHelpers) { $HostHelpers = Join-Path $Here 'bsr_host.ps1' }
if (-not $Diagnostic) { $Diagnostic = Join-Path $Here '..\debug.cmd' }
$Cmd = (Resolve-Path $Cmd).Path; $Engine = (Resolve-Path $Engine).Path; $Magisk = (Resolve-Path $Magisk).Path

function Find-Bytes([byte[]]$h, [byte[]]$n, [int]$start = 0) {
    $i = [Array]::IndexOf($h, $n[0], $start)
    while ($i -ge 0 -and $i -le $h.Length - $n.Length) {
        $ok = $true
        for ($k = 0; $k -lt $n.Length; $k++) { if ($h[$i + $k] -ne $n[$k]) { $ok = $false; break } }
        if ($ok) { return $i }
        $i = [Array]::IndexOf($h, $n[0], $i + 1)
    }
    return -1
}
function Splice-Block([byte[]]$bytes, [string]$tok, [string]$file, [switch]$CommentBlock) {
    $enc = [Text.Encoding]::ASCII
    $beg = $enc.GetBytes("__BSR_${tok}_BEGIN__"); $end = $enc.GetBytes("__BSR_${tok}_END__")
    $bi = Find-Bytes $bytes $beg
    if ($bi -lt 0) {
        if ($tok -ne 'HOST') { throw "BEGIN marker for $tok not found" }
        $wrapper = if ($CommentBlock) { "`r`n<#`r`n" } else { "`r`n" }
        $wrapper += "__BSR_${tok}_BEGIN__`r`n__BSR_${tok}_END__`r`n"
        if ($CommentBlock) { $wrapper += "#>`r`n" }
        $bytes = [byte[]]($bytes + $enc.GetBytes($wrapper))
        $bi = Find-Bytes $bytes $beg
    }
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
$bytes = Splice-Block $bytes 'HOST' $HostHelpers
# cmd.exe's parenthesized blocks require consistent CRLF. Normalize only the
# batch header; never run a text/EOL conversion over the embedded binary blobs.
$headerEnd = Find-Bytes $bytes ([Text.Encoding]::ASCII.GetBytes('__BSR_ENGINE_' + 'BEGIN__'))
$header = [Text.Encoding]::UTF8.GetString($bytes, 0, $headerEnd) -replace '\r?\n', "`r`n"
$headerBytes = [Text.Encoding]::UTF8.GetBytes($header)
$joined = New-Object byte[] ($headerBytes.Length + $bytes.Length - $headerEnd)
[Array]::Copy($headerBytes, 0, $joined, 0, $headerBytes.Length)
[Array]::Copy($bytes, $headerEnd, $joined, $headerBytes.Length, $bytes.Length - $headerEnd)
$bytes = $joined
[IO.File]::WriteAllBytes($Cmd, $bytes)
$debugBytes = Splice-Block ([IO.File]::ReadAllBytes($Diagnostic)) 'HOST' $HostHelpers -CommentBlock
[byte[]]$debugBytes = [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($debugBytes) -replace '\r?\n', "`r`n"))
[IO.File]::WriteAllBytes($Diagnostic, $debugBytes)
Say ("re-embedded: {0} -> {1} bytes" -f $orig, $bytes.Length)

# ---- verify: extract each block back out and compare to the source (ignoring trailing EOL) ----
function Extract([string]$text, [string]$tok) {
    $b = "__BSR_${tok}_BEGIN__"; $e = "__BSR_${tok}_END__"
    $i = $text.IndexOf($b); $j = $text.IndexOf($e)
    $i = $text.IndexOf([char]10, $i) + 1
    return $text.Substring($i, $j - $i)
}
$t = [IO.File]::ReadAllText($Cmd)
$bad = $false
foreach ($p in @(@('ENGINE', $Engine), @('MAGISK', $Magisk), @('HOST', $HostHelpers))) {
    $emb = (Extract $t $p[0]).TrimEnd("`r", "`n")
    $src = ([IO.File]::ReadAllText($p[1])).TrimEnd("`r", "`n")
    if ($emb -ceq $src) { Say "  [OK] embedded $($p[0]) matches tools source ($($src.Length) chars)" Green }
    else { Say "  [MISMATCH] embedded $($p[0]) != source" Red; $bad = $true }
}
$debugHost = ((Extract ([IO.File]::ReadAllText($Diagnostic)) 'HOST') -replace "`r`n", "`n").TrimEnd("`n")
if ($debugHost -cne (([IO.File]::ReadAllText($HostHelpers)) -replace "`r`n", "`n").TrimEnd("`n")) { Say '  [MISMATCH] diagnostic HOST != source' Red; $bad = $true }
else { Say '  [OK] diagnostic HOST matches tools source' Green }
exit ([int]$bad)
