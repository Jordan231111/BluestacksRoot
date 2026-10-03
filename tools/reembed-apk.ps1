<# Replace the RAW base64 APK block, preserving every other byte. A different
   APK also requires updating its pinned SHA-256 in bsr_magisk.ps1 and the
   embedded-sync test, then running reembed.ps1. External APK overrides do not. #>
[CmdletBinding()]
param(
    [string]$Cmd,
    [Parameter(Mandatory=$true)][string]$Apk,
    [ValidateRange(4,65536)][int]$Wrap=4096
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'bsr_build.ps1')
trap { Write-Host (Redact-UserPath $_.Exception.Message) -ForegroundColor Red; exit 1 }
if(-not $Cmd){$Cmd=Join-Path $PSScriptRoot '..\blueStackRoot.cmd'}
$Cmd=(Resolve-Path -LiteralPath $Cmd).Path
$Apk=(Resolve-Path -LiteralPath $Apk).Path
$apkBytes=[IO.File]::ReadAllBytes($Apk)
$sourceHash=Get-BsrBytesHash $apkBytes
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($Apk)
try{
    foreach($name in (Get-BsrMagiskFileMap).Keys){
        $entry=$zip.GetEntry($name)
        if(-not $entry -or $entry.Length -le 0){throw "APK missing expected member: $name"}
    }
}finally{$zip.Dispose()}
$base64=[Convert]::ToBase64String($apkBytes)
$content=New-Object Text.StringBuilder
for($offset=0;$offset -lt $base64.Length;$offset+=$Wrap){
    [void]$content.Append($base64,$offset,[Math]::Min($Wrap,$base64.Length-$offset)).Append("`r`n")
}
$bytes=[IO.File]::ReadAllBytes($Cmd)
$result=Set-BsrEmbeddedBlock $bytes 'APK' ([Text.Encoding]::ASCII.GetBytes($content.ToString()))
$decoded=[Convert]::FromBase64String((Get-BsrEmbeddedText $result 'APK'))
if($decoded.Length -ne $apkBytes.Length -or (Get-BsrBytesHash $decoded) -cne $sourceHash){throw 'Embedded APK failed its SHA-256 round-trip check'}
Write-BsrBuild $Cmd $result
Write-Host "Re-embedded APK: $($apkBytes.Length) bytes, SHA-256 $sourceHash. Other blocks unchanged." -ForegroundColor Green
