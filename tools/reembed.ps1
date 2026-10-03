<# Refresh the single-file launchers from tools sources. Validate both builds in
   memory, then publish each atomically; binary payload blocks stay unchanged. #>
[CmdletBinding()]
param(
    [string]$Cmd, [string]$Engine, [string]$Magisk,
    [string]$HostHelpers, [string]$Diagnostic, [string]$Launcher
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'bsr_build.ps1')
trap { Write-Host (Redact-UserPath $_.Exception.Message) -ForegroundColor Red; exit 1 }
if(-not $Cmd){$Cmd=Join-Path $PSScriptRoot '..\blueStackRoot.cmd'}
if(-not $Engine){$Engine=Join-Path $PSScriptRoot 'bsr_engine.ps1'}
if(-not $Magisk){$Magisk=Join-Path $PSScriptRoot 'bsr_magisk.ps1'}
if(-not $HostHelpers){$HostHelpers=Join-Path $PSScriptRoot 'bsr_host.ps1'}
if(-not $Diagnostic){$Diagnostic=Join-Path $PSScriptRoot '..\debug.cmd'}
if(-not $Launcher){$Launcher=Join-Path $PSScriptRoot 'bsr_launcher.ps1'}
$Cmd=(Resolve-Path -LiteralPath $Cmd).Path
$Diagnostic=(Resolve-Path -LiteralPath $Diagnostic).Path
$bytes=[IO.File]::ReadAllBytes($Cmd)
$original=$bytes.Length
$sources=[ordered]@{ENGINE=$Engine;MAGISK=$Magisk;HOST=$HostHelpers;LAUNCHER=$Launcher}
foreach($tag in $sources.Keys){
    $source=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $sources[$tag]).Path).TrimEnd("`r","`n")
    Assert-BsrScript $source $sources[$tag]
    $bytes=Set-BsrEmbeddedBlock $bytes $tag ([Text.Encoding]::UTF8.GetBytes($source+"`r`n"))
    if((Get-BsrEmbeddedText $bytes $tag).TrimEnd("`r","`n") -cne $source){throw "Embedded $tag differs from its source"}
}
# cmd.exe requires CRLF in the batch header; leave all payload bytes alone.
$headerEnd=(Get-BsrBlockBounds $bytes 'ENGINE').Begin
$header=[Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($bytes,0,$headerEnd) -replace '\r?\n',"`r`n"))
$joined=New-Object byte[] ($header.Length+$bytes.Length-$headerEnd)
[Array]::Copy($header,0,$joined,0,$header.Length)
[Array]::Copy($bytes,$headerEnd,$joined,$header.Length,$bytes.Length-$headerEnd)
$bytes=$joined
$hostText=[IO.File]::ReadAllText($HostHelpers).TrimEnd("`r","`n")
$debugBytes=Set-BsrEmbeddedBlock ([IO.File]::ReadAllBytes($Diagnostic)) 'HOST' ([Text.Encoding]::UTF8.GetBytes($hostText+"`r`n"))
$debugText=[Text.Encoding]::UTF8.GetString($debugBytes) -replace '\r?\n',"`r`n"
$debugBytes=[Text.Encoding]::UTF8.GetBytes($debugText)
if(((Get-BsrEmbeddedText $debugBytes 'HOST') -replace "`r`n","`n").TrimEnd("`n") -cne ($hostText -replace "`r`n","`n")){throw 'Diagnostic HOST differs from its source'}
Write-BsrBuild $Cmd $bytes
Write-BsrBuild $Diagnostic $debugBytes
Write-Host "Re-embedded: $original -> $($bytes.Length) bytes; all four scripts and diagnostic HOST match their sources." -ForegroundColor Green
