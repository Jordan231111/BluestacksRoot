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

. (Join-Path $Here 'bsr_host.ps1')
function Say([string]$m, [string]$c = 'Gray') { Write-Host (Redact-UserPath $m) -ForegroundColor $c }
trap {
    Say "[!] $($_.Exception.Message)" Red
    exit 1
}

$Apk = (Resolve-Path -LiteralPath $Apk).Path
Expand-BsrMagiskApk $Apk $Dst -IncludeUninstaller
Say "[+] refreshed databin -> $Dst (11 files)" Green
