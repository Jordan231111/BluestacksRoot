<#
  extract-databin.ps1 -- (re)extract the reference Magisk "databin" file set from a Magisk APK into
  tools\magisk_databin\.

  This folder is a REFERENCE copy of what gets installed: at run time bsr_magisk.ps1's Extract-MagiskApk
  pulls the same lib/$ABI + assets/*.sh members straight out of the bundled APK. Re-run this whenever the
  bundled APK changes so the committed reference stays in sync with what the tool actually deploys.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\extract-databin.ps1 -Apk "<path to .apk>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [string]$Dst
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Dst) { $Dst = Join-Path $Here 'magisk_databin' }

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

$Apk = (Resolve-Path $Apk).Path
Add-Type -AssemblyName System.IO.Compression.FileSystem

# APK member path -> output filename. The x86_64 binary set + magisk32 from x86, plus the asset scripts.
# This mirrors Extract-MagiskApk in bsr_magisk.ps1 (which omits uninstaller.sh; kept here as a reference).
$map = [ordered]@{
    'lib/x86_64/libbusybox.so'      = 'busybox'
    'lib/x86_64/libmagisk64.so'     = 'magisk64'
    'lib/x86_64/libmagiskboot.so'   = 'magiskboot'
    'lib/x86_64/libmagiskinit.so'   = 'magiskinit'
    'lib/x86_64/libmagiskpolicy.so' = 'magiskpolicy'
    'lib/x86/libmagisk32.so'        = 'magisk32'
    'assets/stub.apk'               = 'stub.apk'
    'assets/util_functions.sh'      = 'util_functions.sh'
    'assets/boot_patch.sh'          = 'boot_patch.sh'
    'assets/addon.d.sh'             = 'addon.d.sh'
    'assets/uninstaller.sh'         = 'uninstaller.sh'
}
New-Item -ItemType Directory -Path $Dst -Force | Out-Null
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    foreach ($k in $map.Keys) {
        $e = $zip.GetEntry($k)
        if (-not $e) { throw "APK missing expected member: $k" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dst $map[$k]), $true)
        Say ("  {0,-16} <- {1}  ({2:N0} bytes)" -f $map[$k], $k, $e.Length)
    }
}
finally { $zip.Dispose() }
Say ("[+] refreshed databin -> {0} ({1} files)" -f $Dst, $map.Count) Green
