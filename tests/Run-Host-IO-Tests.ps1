<# Regression tests for issues #31/#32. Default mode is safe, mocked host I/O.
   -Integration additionally creates and mounts disposable Windows VHD/VHDX files;
   it never opens BlueStacks disks, changes security settings, or runs HD-Player. #>
[CmdletBinding()]
param([switch]$Integration)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Repo = Split-Path -Parent $PSScriptRoot
$HostSource = Join-Path $Repo 'tools\bsr_host.ps1'
$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$condition) {
    if ($condition) { $script:pass++; Write-Host "[PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "[FAIL] $name" -ForegroundColor Red }
}
function Expect-Error([string]$name, [scriptblock]$body, [string]$pattern) {
    $caught = $null
    try { & $body | Out-Null } catch { $caught = $_ }
    Check $name ($null -ne $caught -and $caught.Exception.Message -match $pattern)
    return $caught
}
function Import-Function([string]$file, [string]$name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Function $name not found in $file" }
    return $fn.Extent.Text
}
$work = Join-Path $env:TEMP ('bsr_host_tests_' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
try {
    . $HostSource
    foreach ($file in @('tools\bsr_host.ps1','tools\bsr_engine.ps1','tools\bsr_magisk.ps1','tools\reembed.ps1','debug.cmd')) {
        $text = [IO.File]::ReadAllText((Join-Path $Repo $file))
        if ($file -eq 'debug.cmd') { $text = $text.Substring($text.IndexOf('#__BSR_DEBUG_PS__')) }
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
        Check "PowerShell parser: $file" ($errors.Count -eq 0)
        if ($errors.Count) { Write-Host ($errors | Out-String) }
    }
    $canonical = ([IO.File]::ReadAllText($HostSource) -replace '\r\n', "`n").TrimEnd("`n")
    foreach ($file in @('tools\bsr_engine.ps1','tools\bsr_magisk.ps1','debug.cmd')) {
        $text = [IO.File]::ReadAllText((Join-Path $Repo $file)) -replace '\r\n', "`n"
        $m = [regex]::Match($text, '(?ms)^# BSR_HOST_HELPERS_BEGIN\n(.*?)\n# BSR_HOST_HELPERS_END$')
        Check "Host helper embedded exactly: $file" ($m.Success -and $m.Groups[1].Value -ceq $canonical)
    }
    $folder = Join-Path $work ('custom [disk] ' + [char]0x03A9)
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $vhdx = Join-Path $folder 'Root.vhd'
    $bytes = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($bytes, 0)
    [IO.File]::WriteAllBytes($vhdx, $bytes)
    Check 'VHDX content with .vhd filename' ((Get-BsrDiskStorageType $vhdx) -ceq 'VHDX')
    $vhd = Join-Path $folder 'other.vhdx'
    $bytes = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('conectix').CopyTo($bytes, $bytes.Length - 512)
    [IO.File]::WriteAllBytes($vhd, $bytes)
    Check 'VHD footer with .vhdx filename' ((Get-BsrDiskStorageType $vhd) -ceq 'VHD')
    foreach ($size in @(0, 7, 511)) {
        $short = Join-Path $work "short-$size.vhd"
        [IO.File]::WriteAllBytes($short, (New-Object byte[] $size))
        $null = Expect-Error "Reject truncated $size-byte image" { Get-BsrDiskStorageType $short } 'BSR_DISK_FORMAT.*truncated'
    }
    $unknown = Join-Path $work 'unknown.vhd'
    [IO.File]::WriteAllBytes($unknown, (New-Object byte[] 1024))
    $null = Expect-Error 'Unknown format not guessed from extension' { Get-BsrDiskStorageType $unknown } 'BSR_DISK_FORMAT'
    $vdi = Join-Path $work 'vdi.vhd'
    $bytes = New-Object byte[] 1024
    [BitConverter]::GetBytes([Convert]::ToUInt32('BEDA107F',16)).CopyTo($bytes,64)
    [IO.File]::WriteAllBytes($vdi,$bytes)
    $null = Expect-Error 'VDI gets an explicit unsupported-format error' { Get-BsrDiskStorageType $vdi } 'is VDI'
    foreach ($file in @($vhdx,$vhd,$unknown,$vdi)) {
        $f = [IO.File]::Open($file,'Open','ReadWrite','None'); $f.Dispose()
        Check "No leaked header handle: $([IO.Path]::GetFileName($file))" $true
    }
    $native = New-Object ComponentModel.Win32Exception(5, 'localized access denial')
    $outer = New-Object InvalidOperationException('outer', $native)
    $detail = Get-BsrExceptionDetail $outer
    Check 'Nested native code preserved independently of language' ($detail -match 'Win32=5' -and $detail -match 'localized access denial')
    Check 'HRESULT rendered as unsigned hex' ($detail -match 'HRESULT=0x[0-9A-F]{8}')
    $cimLike = New-Object Management.Automation.ErrorRecord($outer,'HRESULT 0xC03A0014,Mount-DiskImage',[Management.Automation.ErrorCategory]::NotSpecified,$vhdx)
    Check 'Native CIM HRESULT retained in ErrorId' ((Get-BsrExceptionDetail $cimLike) -match 'ErrorId=HRESULT 0xC03A0014')

    $script:mounts = 0; $script:detaches = 0; $script:attached = $false
    $script:queryThrows = $false; $script:mountThrows = $false; $script:lastMount = @{}
    function Get-DiskImage { [CmdletBinding()]param($ImagePath,$StorageType)
        if ($script:queryThrows) { throw 'provider cannot infer this extension' }
        [pscustomobject]@{Attached=$script:attached; Number=7}
    }
    function Mount-DiskImage { [CmdletBinding()]param($ImagePath,$StorageType,$Access,[switch]$NoDriveLetter,[switch]$PassThru)
        $script:mounts++; $script:lastMount = $PSBoundParameters
        if ($script:mountThrows) { throw (New-Object ComponentModel.Win32Exception(5,'disk access denied')) }
        [pscustomobject]@{Attached=$true;Number=7;StorageType=$StorageType}
    }
    function Dismount-DiskImage { [CmdletBinding()]param($InputObject) $script:detaches++; $script:detachedType=$InputObject.StorageType }
    Mount-BsrDiskImage $vhdx | Out-Null
    Check 'Mount explicitly selects VHDX' ($script:lastMount.StorageType -ceq 'VHDX')
    Check 'Mount passes literal full custom path' ($script:lastMount.ImagePath -ceq $vhdx)
    Check 'Mount is RW, no drive letter, terminating errors' ($script:lastMount.Access -eq 'ReadWrite' -and $script:lastMount.NoDriveLetter -and $script:lastMount.ErrorAction -eq 'Stop')
    Mount-BsrDiskImage $vhd -ReadOnly | Out-Null
    Check 'Read-only requests stay read-only' ($script:lastMount.Access -eq 'ReadOnly' -and $script:lastMount.StorageType -eq 'VHD')
    $script:queryThrows = $true
    Mount-BsrDiskImage $vhdx | Out-Null
    Check 'Wrong-extension query does not prevent explicit mount' ($script:lastMount.StorageType -eq 'VHDX')
    $script:queryThrows = $false; $script:attached = $true
    $before = $script:mounts
    $null = Expect-Error 'Already attached disk rejected' { Test-BsrDiskAttach $vhdx } 'BSR_DISK_IN_USE'
    Check 'Foreign mount neither mounted nor detached' ($script:mounts -eq $before -and $script:detaches -eq 0)
    $script:attached = $false; $script:mountThrows = $true
    $err = Expect-Error 'Native mount error is stage-tagged' { Test-BsrDiskAttach $vhdx } 'BSR_DISK_ATTACH'
    Check 'Mount failure includes native error and selected format' ($err.Exception.Message -match 'Win32=5' -and $err.Exception.Message -match 'as VHDX')
    Check 'Failed mount is never detached' ($script:detaches -eq 0)
    $script:mountThrows = $false
    Test-BsrDiskAttach $vhdx
    Check 'Successful preflight detaches its own mount once' ($script:detaches -eq 1)
    Check 'Detach uses the typed mount object, not the filename' ($script:detachedType -eq 'VHDX')
    $before = $script:mounts
    $null = Expect-Error 'Unsupported format rejected before native mount' { Mount-BsrDiskImage $vdi } 'BSR_DISK_FORMAT'
    Check 'No native mount for unsupported format' ($script:mounts -eq $before)

    $player = Join-Path $folder 'HD-Player.exe'
    [IO.File]::WriteAllBytes($player, (New-Object byte[] 1))
    $script:launches=0; $script:diagnostics=0; $script:launchDenied=$true
    $script:lastStart=@{}; $script:disposed=$false
    function Get-BsrPlayerDiagnostics($Player,$Since) { $script:diagnostics++; 'Mock read-only host diagnostics' }
    function Start-Process { [CmdletBinding()]param($FilePath,$WorkingDirectory,$ArgumentList,[switch]$PassThru)
        $script:launches++; $script:lastStart=$PSBoundParameters
        if ($script:launchDenied) {
            $errorRecord = New-Object Management.Automation.ErrorRecord((New-Object ComponentModel.Win32Exception(5,'localized launch denial')),'StartDenied',[Management.Automation.ErrorCategory]::PermissionDenied,$FilePath)
            $PSCmdlet.WriteError($errorRecord)
            return
        }
        $p = [pscustomobject]@{Id=123}
        $p | Add-Member ScriptMethod Dispose { $script:disposed=$true }
        $p
    }
    $ErrorActionPreference='Continue'
    $err = Expect-Error 'Rejected launch terminates even under Continue' { Start-BsrPlayer $player 'Rvc64' } 'BSR_PLAYER_LAUNCH'
    $ErrorActionPreference='Stop'
    Check 'Launch failure reports native code and diagnostics' ($err.Exception.Message -match 'Win32=5' -and $script:diagnostics -eq 1)
    Check 'Launch uses explicit install working directory' ($script:lastStart.WorkingDirectory -ceq $folder)
    Check 'Instance argument is quoted' ($script:lastStart.ArgumentList[1] -ceq '"Rvc64"')
    $script:launchDenied=$false
    Check 'Successful launch returns PID' ((Start-BsrPlayer $player 'Rvc64') -eq 123)
    Check 'Process handle is disposed' $script:disposed
    Check 'No failure diagnostics on successful launch' ($script:diagnostics -eq 1)
    $null = Expect-Error 'Invalid instance rejected' { Start-BsrPlayer $player 'bad"name' } 'Invalid instance'
    $null = Expect-Error 'Missing executable rejected' { Start-BsrPlayer (Join-Path $work 'missing.exe') 'Rvc64' } 'not found'

    function Say($m,$c) { }
    function Assert-BlueStacksHostTools { }
    function Initialize-AdbServer { }
    function Set-PlayerLogMark { $script:marked=$true }
    function Get-AdbPortCandidates { throw 'BUG: ADB polling was reached' }
    . ([scriptblock]::Create((Import-Function (Join-Path $Repo 'tools\bsr_magisk.ps1') 'Boot-And-Wait')))
    $Player=$player; $Instance='Rvc64'; $script:launchDenied=$true; $script:marked=$false
    $before=$script:launches
    $err=Expect-Error 'Boot-And-Wait fails before any ADB polling' { Boot-And-Wait 1 } 'BSR_PLAYER_LAUNCH'
    Check 'Boot rejection is not retried' ($script:launches -eq $before+1)
    Check 'Player log mark set before launch' $script:marked
    function Ensure-MagiskApk { }; function Ensure-BsrSu { }; function Ensure-Debugfs { }; function Kill-BlueStacks { }
    function Set-ConfKey { throw 'BUG: configuration was changed' }
    function Copy-Item { $script:backupAttempted=$true }
    function powershell.exe { throw 'BUG: executable patch was reached before preflight' }
    . ([scriptblock]::Create((Import-Function (Join-Path $Repo 'tools\bsr_magisk.ps1') 'Do-Prep')))
    $Vhd=$vhdx; $NoBackup=$false; $script:mountThrows=$true
    $script:backupAttempted=$false
    $null=Expect-Error 'Prep mount failure precedes patch/conf' { Do-Prep } 'BSR_DISK_ATTACH'
    Check 'Pristine backup attempted before RW attachment' $script:backupAttempted

    $debugText=[IO.File]::ReadAllText((Join-Path $Repo 'debug.cmd'))
    $launchSection=[regex]::Match($debugText,"(?s)try \{ Start-BsrPlayer.*?\r?\n\}\r?\n").Value
    Check 'Debug has explicit host-launch failure verdict' ($launchSection -match 'HOST_LAUNCH_FAILED' -and $launchSection -match 'exit 1')
    Check 'Debug CMD propagates PowerShell status' ($debugText -match 'exit /b %BSR_DEBUG_RC%')

    foreach($name in @('Get-DiskImage','Mount-DiskImage','Dismount-DiskImage','Start-Process','Copy-Item','powershell.exe')) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    . $HostSource
    if ($Integration) {
        foreach($format in @('vhd','vhdx')) {
            $created=Join-Path $work "real.$format"
            $scriptPath=Join-Path $work 'create-disk.txt'
            [IO.File]::WriteAllText($scriptPath,"create vdisk file=`"$created`" maximum=64 type=expandable`r`nexit`r`n",[Text.Encoding]::ASCII)
            $diskpartOutput=& diskpart.exe /s $scriptPath 2>&1 | Out-String
            Write-Host $diskpartOutput
            if(-not (Test-Path -LiteralPath $created)){throw 'DiskPart did not create the test image.'}
            $renamed=Join-Path $work ("Root-$format.vhd")
            Move-Item -LiteralPath $created -Destination $renamed
            Check "Real $format signature detected" ((Get-BsrDiskStorageType $renamed) -ieq $format)
            $owned=$false
            try {
                if($format -eq 'vhdx') {
                    $oldFailed=$false
                    try { Mount-DiskImage -ImagePath $renamed -Access ReadWrite -NoDriveLetter -ErrorAction Stop | Out-Null; $owned=$true }
                    catch { $oldFailed=$true; Write-Host ('Old extension-only mount: '+(Get-BsrExceptionDetail $_)) }
                    Check 'Reproduced old provider failure for VHDX named .vhd' $oldFailed
                    if($owned){Dismount-DiskImage -ImagePath $renamed -StorageType $format -ErrorAction Stop | Out-Null; $owned=$false}
                }
                $mounted=Mount-BsrDiskImage $renamed
                $owned=$true
                Check "Real $format mount succeeds through helper" ($mounted.Attached)
                $queried=Get-DiskImage -ImagePath $renamed -StorageType $mounted.StorageType -ErrorAction Stop
                Check "Real $format disk-number query keeps format" ($queried.Attached -and $null -ne $queried.Number)
            } finally {
                if($owned){Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null}
            }
        }
    }
} catch {
    $script:fail++
    Write-Host ($_ | Out-String) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("HOST I/O RESULTS: {0} passed; {1} failed; Integration={2}" -f $script:pass,$script:fail,$Integration)
exit ([int]($script:fail -gt 0))
