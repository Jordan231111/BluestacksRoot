# Authoring helpers only. The distributed .cmd never needs this file.
. (Join-Path $PSScriptRoot 'bsr_host.ps1')

function Find-BsrMarker([byte[]]$Bytes, [string]$Marker, [int]$Start=0) {
    $needle=[Text.Encoding]::ASCII.GetBytes($Marker)
    $index=[Array]::IndexOf($Bytes,$needle[0],$Start)
    while($index -ge 0 -and $index -le $Bytes.Length-$needle.Length){
        $end=$index+$needle.Length
        $match=($index -eq 0 -or $Bytes[$index-1] -eq 10) -and
               ($end -eq $Bytes.Length -or $Bytes[$end] -eq 10 -or $Bytes[$end] -eq 13)
        if($match){
            for($j=1;$j -lt $needle.Length;$j++){
                if($Bytes[$index+$j] -ne $needle[$j]){$match=$false;break}
            }
        }
        if($match){return $index}
        $index=[Array]::IndexOf($Bytes,$needle[0],$index+1)
    }
    return -1
}

function Get-BsrBlockBounds([byte[]]$Bytes, [string]$Tag) {
    $begin="__BSR_${Tag}_BEGIN__"; $end="__BSR_${Tag}_END__"
    $first=Find-BsrMarker $Bytes $begin
    if($first -lt 0){throw "BEGIN marker for $Tag not found"}
    $last=Find-BsrMarker $Bytes $end ($first+$begin.Length)
    if($last -lt 0){throw "END marker for $Tag not found"}
    if((Find-BsrMarker $Bytes $begin ($first+1)) -ge 0 -or
       (Find-BsrMarker $Bytes $end ($last+1)) -ge 0 -or
       (Find-BsrMarker $Bytes $end) -ne $last){throw "Duplicate or out-of-order markers for $Tag"}
    $start=[Array]::IndexOf($Bytes,[byte]10,$first)+1
    if($start -le $first -or $start -gt $last){throw "Invalid marker line for $Tag"}
    @{Begin=$first;Start=$start;End=$last}
}

function Get-BsrEmbeddedText([byte[]]$Bytes, [string]$Tag) {
    $bounds=Get-BsrBlockBounds $Bytes $Tag
    [Text.Encoding]::UTF8.GetString($Bytes,$bounds.Start,$bounds.End-$bounds.Start)
}

function Set-BsrEmbeddedBlock([byte[]]$Bytes, [string]$Tag, [byte[]]$Content) {
    $bounds=Get-BsrBlockBounds $Bytes $Tag
    $result=New-Object byte[] ($bounds.Start+$Content.Length+$Bytes.Length-$bounds.End)
    [Array]::Copy($Bytes,0,$result,0,$bounds.Start)
    [Array]::Copy($Content,0,$result,$bounds.Start,$Content.Length)
    [Array]::Copy($Bytes,$bounds.End,$result,$bounds.Start+$Content.Length,$Bytes.Length-$bounds.End)
    return ,$result
}

function Assert-BsrScript([string]$Text, [string]$Name) {
    $tokens=$null; $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw "Invalid PowerShell in ${Name}: $($parseErrors[0].Message)"}
}

function Write-BsrBuild([string]$Path, [byte[]]$Bytes) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
        else{[IO.File]::Move($temporary,$Path)}
    }finally{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    }
}
