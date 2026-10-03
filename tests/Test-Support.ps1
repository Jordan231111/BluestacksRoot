function Remove-BsrTestDirectory([string]$Path) {
    $resolved=[IO.Path]::GetFullPath($Path)
    $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
       [IO.Path]::GetFileName($resolved) -notmatch '^bsr_[a-z0-9_]+_[a-f0-9]+$'){
        throw "Refusing cleanup outside the test workspace: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
