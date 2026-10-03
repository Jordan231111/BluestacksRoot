# Embedded entry point for blueStackRoot.cmd. No repository files are required.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$selfPath = $env:BSR_SELF
$homeDir = Split-Path -Parent $selfPath
$selfText = [IO.File]::ReadAllText($selfPath)

function Get-LauncherBlock([string]$Name) {
    $begin = '__BSR_' + $Name + '_BEGIN__'
    $end = '__BSR_' + $Name + '_END__'
    $pattern = '(?m)^' + [regex]::Escape($begin) + '\r?$'
    $match = [regex]::Match($selfText, $pattern)
    if (-not $match.Success) { throw "Embedded $Name block is missing. Re-download the complete blueStackRoot.cmd." }
    $start = $selfText.IndexOf([char]10, $match.Index) + 1
    $stop = $selfText.IndexOf($end, $start, [StringComparison]::Ordinal)
    if ($start -le 0 -or $stop -le $start) { throw "Embedded $Name block is incomplete." }
    return $selfText.Substring($start, $stop - $start)
}
. ([scriptblock]::Create((Get-LauncherBlock 'HOST')))

function Say([string]$Message, [string]$Color='Gray') { Write-Host (Redact-UserPath $Message) -ForegroundColor $Color }

$configPath = Join-Path $homeDir 'bluestacksconfig.txt'
$script:customPath = if (Test-Path -LiteralPath $configPath) { ([IO.File]::ReadAllText($configPath)).Trim() } else { '' }
$script:installDir = ''; $script:dataDir = ''; $userDef = ''
$records = @(Get-RegBlueStacksRecords)
if ($records.Count) {
    $script:installDir = $records[0].InstallDir
    $script:dataDir = $records[0].DataDir
    $userDef = $records[0].UserDefinedDir
}
$customInstall = Get-InstallRootFromPath $customPath
$customData = Get-DataRootFromPath $customPath
if ($customInstall) { $script:installDir = $customInstall }
if ($customData) { $script:dataDir = $customData }
$script:scriptsDir = $null
$script:enginePath = $null
$script:magiskPath = $null
$addedExclusions = New-Object System.Collections.Generic.List[string]

function Initialize-LauncherScripts {
    if ($script:enginePath -and (Test-Path -LiteralPath $script:enginePath)) { return }
    $script:scriptsDir = Join-Path ([IO.Path]::GetTempPath()) ('bsr_launcher_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:scriptsDir)
    foreach ($name in @('ENGINE','MAGISK')) {
        $code = Get-LauncherBlock $name
        $tokens=$null; $parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors) { throw "Embedded $name script is damaged: $($parseErrors[0].Message)" }
        $path = Join-Path $script:scriptsDir ('bsr_' + $name.ToLowerInvariant() + '.ps1')
        # Windows PowerShell 5.1 uses ANSI for BOM-less -File input.
        [IO.File]::WriteAllText($path, $code, (New-Object Text.UTF8Encoding($true)))
    }
    $script:enginePath = Join-Path $script:scriptsDir 'bsr_engine.ps1'
    $script:magiskPath = Join-Path $script:scriptsDir 'bsr_magisk.ps1'
}

function Resolve-LauncherPaths([string]$Base) {
    Initialize-LauncherScripts
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:enginePath,'-Action','Resolve','-Base',$Base,'-SelfPath',$selfPath)
    foreach ($pair in @(@('-InstallDir',$script:installDir),@('-DataDir',$script:dataDir),@('-UserDef',$userDef),@('-CustomPath',$script:customPath))) {
        if ($pair[1]) { $arguments += $pair }
    }
    $result = Invoke-BsrNative 'powershell.exe' $arguments 120
    if ($result.ExitCode) { throw $result.Output }
    $paths = @{}
    foreach ($line in ($result.Output -split '\r?\n')) {
        if ($line -match '^(BSR_[A-Z]+)=(.*)$') { $paths[$Matches[1]]=$Matches[2] }
    }
    foreach ($key in @('BSR_BSTK','BSR_CONF','BSR_VHD','BSR_INSTALL')) {
        if (-not $paths[$key] -or -not (Test-Path -LiteralPath $paths[$key])) {
            throw "BlueStacks path is missing: $key=$($paths[$key]). Launch the intended instance once, close it, and retry."
        }
    }
    if ($paths['BSR_INSTANCE'] -notmatch '^[A-Za-z0-9_]+$') { throw 'Invalid resolved instance identifier.' }
    $script:installDir = $paths['BSR_INSTALL']; $script:dataDir = $paths['BSR_DATADIR']
    return $paths
}

function Add-LauncherExclusions([string]$DataRoot) {
    try {
        $current = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        foreach ($path in @($homeDir,$DataRoot,(Join-Path $env:TEMP 'bsr_work'))) {
            if ($path -and $current -notcontains $path -and $addedExclusions -notcontains $path) {
                Add-MpPreference -ExclusionPath $path -ErrorAction Stop
                $addedExclusions.Add($path)
            }
        }
    } catch { } # Defender can be absent or centrally managed.
}

function Show-LauncherMenu {
    try { Clear-Host; $width=[Console]::WindowWidth } catch { $width=80 }
    if ($width -lt 30) { $width=80 }
    $boxWidth=[Math]::Min(82,[Math]::Max(44,$width-2))
    $pad=' '*[Math]::Max(0,[int](($width-$boxWidth)/2))
    function Rule { Write-Host ($pad+([string][char]0x2500)*$boxWidth) -ForegroundColor DarkCyan }
    function Cut($value) {
        if (-not $value) { return '(not detected)' }
        $value=Redact-UserPath $value
        $limit=$boxWidth-12
        if ($value.Length -gt $limit) { return '...'+$value.Substring($value.Length-($limit-3)) }
        return $value
    }
    function Row($left,$right='') {
        if ($width -ge 62 -and $right) { Write-Host ($pad+'  '+$left.PadRight(28)+$right) -ForegroundColor Gray }
        else { Write-Host ($pad+'  '+$left) -ForegroundColor Gray; if($right){Write-Host ($pad+'  '+$right) -ForegroundColor Gray} }
    }
    Write-Host ''
    Write-Host ($pad+'  >> blueStackRoot <<') -ForegroundColor Cyan
    Write-Host ($pad+'  Made with '+[char]0x2665+' by Nyxane') -ForegroundColor DarkGray
    Rule
    Row ('DataDir : '+(Cut $script:dataDir))
    Row ('Install : '+(Cut $script:installDir))
    Row 'Root    : Magisk Delta (Kitsune) - automated'
    Rule
    Row 'ROOT (apply)' 'UNROOT (undo)'
    Row '1  Android 9  Pie64' '4  Android 9  Pie64'
    Row '2  Android 11 Rvc64' '5  Android 11 Rvc64'
    Row '3  Android 13 Tiramisu64' '6  Android 13 Tiramisu64'
    Row '7  Full host scrub (pick version)'
    Rule
    Row '8  Set custom path' '0  Exit'
    Rule
    Row 'Every version installs Magisk as the final root; undo removes it.'
    Write-Host ''
}

function Invoke-LauncherAction([string]$Base, [switch]$Undo, [switch]$Full) {
    $paths = Resolve-LauncherPaths $Base
    Add-LauncherExclusions $paths['BSR_DATADIR']
    $action = if ($Undo) { 'Undo' } else { 'Auto' }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:magiskPath,'-Action',$action,
        '-SelfCmd',$selfPath,'-Engine',$script:enginePath,'-Instance',$paths['BSR_INSTANCE'],
        '-Vhd',$paths['BSR_VHD'],'-Conf',$paths['BSR_CONF'],'-Install',$paths['BSR_INSTALL'])
    if ($Full) { $arguments += '-Full' }
    if (-not $Undo) {
        foreach ($directory in @($homeDir,(Join-Path $homeDir 'Working Example & Fix'),(Join-Path $homeDir 'tools'))) {
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            $apk = Get-ChildItem -LiteralPath $directory -Filter 'Magisk*.apk' -File | Sort-Object Name | Select-Object -First 1
            if ($apk) { $arguments += @('-MagiskApk',$apk.FullName); break }
        }
    }
    Say "$action Magisk: $($paths['BSR_INSTANCE'])" Cyan
    # Inherit the console so live pipeline progress remains visible. Exact Windows
    # argv quoting is shared with the captured native runner.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='powershell.exe'
    $info.Arguments=($arguments | ForEach-Object { Quote-BsrNativeArgument $_ }) -join ' '
    $info.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); $code=$process.ExitCode } finally { $process.Dispose() }
    if ($code) { throw "Magisk $action failed (exit $code). Follow the specific error above. For host launch or mount errors, run debug.cmd." }
    Say "Magisk $action completed. Review the verification output above." Green
}

# The guard supports fixture tests without showing a menu or launching an instance.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        while ($true) {
            Show-LauncherMenu
            $choice=Read-Host '  Enter option > '
            if ($null -eq $choice -or $choice -eq '0' -or ([Console]::IsInputRedirected -and $choice -eq '')) { break }
            try {
                switch -Exact ($choice.Trim()) {
                    '1' { Invoke-LauncherAction 'Pie64' }
                    '2' { Invoke-LauncherAction 'Rvc64' }
                    '3' { Invoke-LauncherAction 'Tiramisu64' }
                    '4' { Invoke-LauncherAction 'Pie64' -Undo }
                    '5' { Invoke-LauncherAction 'Rvc64' -Undo }
                    '6' { Invoke-LauncherAction 'Tiramisu64' -Undo }
                    '7' {
                        Say 'Full host scrub restores the shared master disk and HD-Player. It affects every instance using that master.' Yellow
                        $version=Read-Host '1 Android 9 / 2 Android 11 / 3 Android 13 (Enter to cancel)'
                        $base=@{'1'='Pie64';'2'='Rvc64';'3'='Tiramisu64'}[$version]
                        if ($base) { Invoke-LauncherAction $base -Undo -Full }
                    }
                    '8' {
                        $path=Read-Host 'BlueStacks install folder (HD-Player.exe + HD-Adb.exe) or data folder (bluestacks.conf)'
                        if ($path) {
                            $newInstall=Get-InstallRootFromPath $path; $newData=Get-DataRootFromPath $path
                            if (-not $newInstall -and -not $newData) { throw 'That path is not a BlueStacks install or data folder.' }
                            $script:customPath=Normalize-DiscoveryPath $path
                            Write-BsrTextFile $configPath $script:customPath
                            if ($newInstall) { $script:installDir=$newInstall }
                            if ($newData) { $script:dataDir=$newData }
                            Say 'Saved to bluestacksconfig.txt.' Green
                        }
                    }
                    default { Say 'Invalid option -- type a number shown in the menu.' Yellow; continue }
                }
            } catch { Say "[!] $($_.Exception.Message)" Red }
            [void](Read-Host 'Press Enter to return to the menu')
        }
    } finally {
        foreach ($path in $addedExclusions) { try { Remove-MpPreference -ExclusionPath $path -ErrorAction Stop } catch { } }
        if ($scriptsDir) {
            $resolved=[IO.Path]::GetFullPath($scriptsDir)
            $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
            if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolved) -match '^bsr_launcher_[a-f0-9]{32}$') {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
