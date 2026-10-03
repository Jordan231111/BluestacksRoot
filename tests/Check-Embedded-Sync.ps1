# Validate everything needed by the self-contained .cmd on Windows PowerShell 5.1.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
$bytes=[IO.File]::ReadAllBytes((Join-Path $repo 'blueStackRoot.cmd'))
$fail=0
function Check($ok,$name){
    if($ok){Write-Host "[PASS] $name" -ForegroundColor Green}
    else{$script:fail++;Write-Host "[FAIL] $name" -ForegroundColor Red}
}
function Norm([string]$text){($text -replace "`r`n","`n").TrimEnd("`n")}
foreach($pair in @(@('ENGINE','bsr_engine.ps1'),@('MAGISK','bsr_magisk.ps1'),@('HOST','bsr_host.ps1'),@('LAUNCHER','bsr_launcher.ps1'))){
    try{
        $embedded=Get-BsrEmbeddedText $bytes $pair[0]
        Assert-BsrScript $embedded $pair[0]
        $source=[IO.File]::ReadAllText((Join-Path $repo ('tools\'+$pair[1])))
        Check ((Norm $embedded) -ceq (Norm $source)) "$($pair[0]) parses and matches its source"
    }catch{Check $false "$($pair[0]): $_"}
}
$diagnostic=[IO.File]::ReadAllBytes((Join-Path $repo 'debug.cmd'))
Check ((Norm (Get-BsrEmbeddedText $diagnostic 'HOST')) -ceq (Norm ([IO.File]::ReadAllText((Join-Path $repo 'tools\bsr_host.ps1'))))) 'diagnostic HOST matches its source'
$debugText=[Text.Encoding]::UTF8.GetString($diagnostic)
Assert-BsrScript ($debugText.Substring($debugText.IndexOf('#__BSR'+'_DEBUG_PS__'))) 'diagnostic'
# Independent pins catch corruption in every payload, including blocks unchanged by a source rebuild.
$hashes=[ordered]@{
    APK='fac319d2de262fcfff1684e13e1a5c61c486d2a773a7a8ffcfdbfe6f763a7fd4'
    DFS='008b6006e766d2591c8c7db7bf6d6a0a4b9cd6116b9a8e2737151828eb577632'
    BSRSU='c4901ed7deea2599753042201a3b79a0d265170ad3b6793535daf8801ad95974'
    SU='143f50a2a5abaf8dff979996e72f6b911262d5fc962b70a86b764e376528b9c1'
}
foreach($tag in $hashes.Keys){
    try{
        $payload=[Convert]::FromBase64String((Get-BsrEmbeddedText $bytes $tag))
        Check ((Get-BsrBytesHash $payload) -ceq $hashes[$tag]) "$tag payload SHA-256 matches"
        if($tag -eq 'BSRSU'){
            Check ((Get-BsrBytesHash (Expand-BsrGzip $payload)) -ceq (Get-BsrFileHash (Join-Path $repo 'tools\su_src\bsr_su'))) 'bootstrap payload matches the checked-in binary'
        }
    }catch{Check $false "$tag payload: $_"}
}
$headerEnd=(Get-BsrBlockBounds $bytes 'ENGINE').Begin
$header=[Text.Encoding]::UTF8.GetString($bytes,0,$headerEnd)
Check ($header -match 'DisableDelayedExpansion' -and $header -match 'exit /b %BSR_RC%' -and $header -notmatch '(?<!\r)\n' -and @($header -split "`r`n" | Where-Object {$_.Length -gt 8191}).Count -eq 0) 'batch bootstrap uses safe expansion, valid line endings and propagates the exit code'
Write-Host "RESULT: $fail embedded build failures"
exit ([int]($fail -gt 0))
