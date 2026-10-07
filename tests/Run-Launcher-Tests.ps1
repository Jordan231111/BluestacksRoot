# Console layout and locale regressions. No BlueStacks processes or disks are used.
[CmdletBinding()]
param([string]$Culture = 'en-US')
$ErrorActionPreference='Stop'
# Set the culture before the launcher regex is first compiled (Windows PowerShell
# caches -match patterns). CI invokes each culture in a fresh powershell.exe.
[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($Culture)
[Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo($Culture)
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
. (Join-Path $PSScriptRoot 'Test-Support.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_launcher_test_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Host "[PASS] $name"}else{$script:fail++;Write-Host "[FAIL] $name"}}
$originalSelf=$env:BSR_SELF
try {
    $env:BSR_SELF=Join-Path $repo 'blueStackRoot.cmd'
    . ([scriptblock]::Create((Get-BsrEmbeddedText ([IO.File]::ReadAllBytes($env:BSR_SELF)) 'LAUNCHER')))
    # Use the real resolver against a fixture, with no host registry/runtime input.
    $script:installDir=Join-Path $work 'Install [1]'
    $script:dataDir=Join-Path $work 'Data [1]'
    $script:customPath=$script:dataDir
    $userDef=''
    [void][IO.Directory]::CreateDirectory($script:installDir)
    [void][IO.Directory]::CreateDirectory((Join-Path $script:dataDir 'Engine\Pie64'))
    foreach($name in @('HD-Player.exe','HD-Adb.exe')){[IO.File]::WriteAllText((Join-Path $script:installDir $name),'fixture')}
    [IO.File]::WriteAllText((Join-Path $script:dataDir 'bluestacks.conf'),'bst.instance.Pie64.adb_port="5599"')
    [IO.File]::WriteAllText((Join-Path $script:dataDir 'Engine\Pie64\Pie64.bstk'),'<HardDisk location="Root.vhd"/>')
    [IO.File]::WriteAllText((Join-Path $script:dataDir 'Engine\Pie64\Root.vhd'),'fixture')
    $reason='';$paths=$null
    try {$paths=Resolve-LauncherPaths 'Pie64'} catch {$reason=$_.Exception.Message}
    Check ($paths -and $paths.BSR_INSTALL -ceq $script:installDir -and $paths.BSR_DATADIR -ceq $script:dataDir -and $paths.BSR_INSTANCE -ceq 'Pie64') "all resolver fields survive $Culture ($reason)"

    # Capture the actual colored output, checking both column boundaries and
    # retention of every action. Sizes are terminal cells, independent of DPI.
    $script:installDir='C:\Games\'+('Long install directory\'*8)
    $script:dataDir='C:\Users\PrivateName\'+('Long data directory\'*8)
    $expected=@('>> blueStackRoot <<','ROOT (apply)','UNROOT (undo)',
        '1  Android 9  Pie64','2  Android 11 Rvc64','3  Android 13 Tiramisu64',
        '4  Android 9  Pie64','5  Android 11 Rvc64','6  Android 13 Tiramisu64',
        '7  Full host scrub (pick version)','8  Set custom path','0  Exit',
        'Every version installs Magisk as the final root; undo removes it.')
    foreach($width in @(20,29,30,40,44,60,61,62,63,64,80,100,120,160,240)) {
        $lines=New-Object System.Collections.Generic.List[string]
        & {
            function Clear-Host {}
            function Write-Host($Object,$ForegroundColor){$lines.Add([string]$Object)}
            Show-LauncherMenu -Width $width -Height 60
        }
        $overflow=@($lines | Where-Object {$_.Length -ge $width})
        Check ($overflow.Count -eq 0) "menu fits $width columns with a spare column (longest=$((($lines | ForEach-Object {$_.Length}) | Measure-Object -Maximum).Maximum))"
        $text=($lines -join ' ') -replace '\s+',' '
        $missing=@($expected | Where-Object {$text -notlike ('*'+($_ -replace '\s+',' ')+'*')})
        Check ($missing.Count -eq 0 -and $text -notmatch 'PrivateName') "all actions and help remain readable at $width columns"
    }
    # Small windows / large fonts also reduce the available rows. Decorative
    # text may go, but every numbered action and the input prompt must fit.
    foreach($size in @(@(40,18),@(40,20),@(60,20),@(62,16),@(80,16),@(80,25),@(120,30),@(240,60))) {
        $lines=New-Object System.Collections.Generic.List[string]
        & {
            function Clear-Host {}
            function Write-Host($Object,$ForegroundColor){$lines.Add([string]$Object)}
            Show-LauncherMenu -Width $size[0] -Height $size[1]
        }
        $text=($lines -join ' ') -replace '\s+',' '
        $missing=@($expected[1..11] | Where-Object {$text -notlike ('*'+($_ -replace '\s+',' ')+'*')})
        Check ($lines.Count+1 -le $size[1] -and $missing.Count -eq 0 -and @($lines | Where-Object {$_.Length -ge $size[0]}).Count -eq 0) "menu and prompt fit $($size[0]) x $($size[1]) cells"
        if($size[0] -lt 62) {
            Check ($text.IndexOf('3 Android') -lt $text.IndexOf('UNROOT (undo)') -and $text.IndexOf('UNROOT (undo)') -lt $text.IndexOf('4 Android')) 'stacked root and undo headings label the correct actions'
        }
    }
} catch {$fail++;Write-Host "[FAIL] $_";Write-Host $_.ScriptStackTrace}
finally {
    $env:BSR_SELF=$originalSelf
    if($script:scriptsDir){Remove-BsrTestDirectory $script:scriptsDir}
    Remove-BsrTestDirectory $work
}
Write-Host "RESULT: $pass passed, $fail failed ($Culture)"
exit ([int]($fail -gt 0))
