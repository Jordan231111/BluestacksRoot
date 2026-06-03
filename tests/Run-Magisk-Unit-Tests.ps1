<#
  Run-Magisk-Unit-Tests.ps1 -- heavy unit tests for bsr_magisk.ps1 pure logic.

  Safe for CI/dev boxes: dot-sources the orchestrator only. It does not boot BlueStacks,
  mount VHDs, run debugfs, or call adb. The focus is edge cases that previously slipped
  through broad smoke tests: PowerShell array shape, candidate-port ordering, log
  redaction, command-line matching, retry classifiers, and su inventory parsing.

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Magisk-Unit-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Magisk
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Magisk) { $Magisk = (Resolve-Path (Join-Path $Here '..\tools\bsr_magisk.ps1')).Path }

$script:pass = 0
$script:fail = 0
$script:made = New-Object System.Collections.Generic.List[string]

function Section([string]$name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Ok([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) {
        $script:pass++
        Write-Host "  [PASS] $name" -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host "  [FAIL] $name $detail" -ForegroundColor Red
    }
}
function Eq([string]$name, $expected, $actual) {
    Ok $name ("$expected" -eq "$actual") "(expected '$expected', got '$actual')"
}
function ArrEq([string]$name, [string[]]$expected, $actual) {
    $arr = @($actual)
    $same = ($arr.Count -eq $expected.Count)
    if ($same) {
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ("$($arr[$i])" -ne "$($expected[$i])") { $same = $false; break }
        }
    }
    Ok $name $same "(expected '$($expected -join ',')', got '$($arr -join ',')')"
}
function IsFlatStringArray([object[]]$items) {
    foreach ($item in @($items)) {
        if ($item -is [array]) { return $false }
        if (-not ($item -is [string])) { return $false }
        if ("$item" -match '\s') { return $false }
        if ("$item" -match 'System\.Object') { return $false }
    }
    return $true
}
function New-FakeConf([string]$instance, [hashtable]$keys) {
    $root = Join-Path $env:TEMP ("bsr_mag_unit_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:made.Add($root)
    $lines = @('bst.enable_adb_access="1"')
    foreach ($k in $keys.Keys) { $lines += ('bst.instance.' + $instance + '.' + $k + '="' + $keys[$k] + '"') }
    $conf = Join-Path $root 'bluestacks.conf'
    [IO.File]::WriteAllText($conf, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    return $conf
}
function Cands([string]$instance, [hashtable]$keys, $live) {
    $script:Conf = New-FakeConf $instance $keys
    $script:Instance = $instance
    $script:LiveAdbPortProbe = { $live }.GetNewClosure()
    @(Get-AdbPortCandidates)
}
function Expected-Cands([hashtable]$keys, [string[]]$live) {
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('status.adb_port', 'adb_port')) {
        if ($keys.ContainsKey($k)) {
            $v = "$($keys[$k])"
            if (-not $seen.ContainsKey($v)) { $seen[$v] = $true; [void]$out.Add($v) }
        }
    }
    foreach ($v in @($live)) {
        $s = "$v"
        if (-not $seen.ContainsKey($s)) { $seen[$s] = $true; [void]$out.Add($s) }
    }
    if (-not $seen.ContainsKey('5555')) { [void]$out.Add('5555') }
    $out
}

# Dot-source only after test helpers are ready; the dispatch guard prevents boot/write actions.
. $Magisk

try {
    Section 'Redact-UserPath'
    $redactCases = @(
        @('win basic', 'C:\Users\Alice\Documents\log.txt', 'C:\Users\xxxxx\Documents\log.txt'),
        @('win slash', 'C:/Users/Alice/AppData/Local/Temp/log.txt', 'C:/Users/xxxxx/AppData/Local/Temp/log.txt'),
        @('win spaces', 'C:\Users\Alice Bob\Desktop\x.txt', 'C:\Users\xxxxx\Desktop\x.txt'),
        @('win hyphen', 'D:\Users\alice-bob\.cache\x', 'D:\Users\xxxxx\.cache\x'),
        @('unix basic', '/Users/Alice/Library/Logs/x.log', '/Users/xxxxx/Library/Logs/x.log'),
        @('two paths', 'a C:\Users\Alice\one b C:\Users\Bob\two', 'a C:\Users\xxxxx\one b C:\Users\xxxxx\two'),
        @('programdata unchanged', 'C:\ProgramData\BlueStacks_nxt\bluestacks.conf', 'C:\ProgramData\BlueStacks_nxt\bluestacks.conf'),
        @('program files unchanged', 'C:\Program Files\BlueStacks_nxt\HD-Player.exe', 'C:\Program Files\BlueStacks_nxt\HD-Player.exe')
    )
    foreach ($c in $redactCases) { Eq "redact: $($c[0])" $c[2] (Redact-UserPath $c[1]) }
    Ok 'redact: null stays null' ($null -eq (Redact-UserPath $null))

    Section 'Path Helpers'
    Eq 'Clean-Path: null' '' "$(Clean-Path $null)"
    Eq 'Clean-Path: strips quotes/trailing slash' 'C:\Program Files\BlueStacks_nxt' (Clean-Path '"C:\Program Files\BlueStacks_nxt\"')
    Eq 'Clean-Path: trims spaces' 'D:\BlueStacks' (Clean-Path '  D:\BlueStacks\  ')
    Eq 'Fwd: backslashes become slashes' 'C:/Users/xxxxx/a/b' (Fwd 'C:\Users\xxxxx\a\b')

    Section 'DataRoot Resolution'
    Eq 'DataRoot: DataDir plain' 'D:\BS' (Get-DataRoot ([pscustomobject]@{ DataDir = 'D:\BS'; UserDefinedDir = 'E:\Other' }))
    Eq 'DataRoot: DataDir strips Engine' 'D:\BS' (Get-DataRoot ([pscustomobject]@{ DataDir = 'D:\BS\Engine'; UserDefinedDir = $null }))
    Eq 'DataRoot: DataDir strips Engine trailing slash' 'D:\BS' (Get-DataRoot ([pscustomobject]@{ DataDir = 'D:\BS\Engine\'; UserDefinedDir = $null }))
    Eq 'DataRoot: UserDefinedDir fallback' 'E:\UserDefined' (Get-DataRoot ([pscustomobject]@{ DataDir = $null; UserDefinedDir = 'E:\UserDefined\' }))
    Eq 'DataRoot: null registry ProgramData fallback' (Join-Path $env:ProgramData 'BlueStacks_nxt') (Get-DataRoot $null)

    Section 'ADB Candidate Ports - Fixed Cases'
    ArrEq 'cands: status only + fallback' @('5585', '5555') (Cands 'Rvc64' @{ 'status.adb_port' = '5585' } @())
    ArrEq 'cands: adb only + fallback' @('5595', '5555') (Cands 'Rvc64' @{ 'adb_port' = '5595' } @())
    ArrEq 'cands: status wins before adb' @('5555', '5595') (Cands 'Rvc64' @{ 'status.adb_port' = '5555'; 'adb_port' = '5595' } @())
    ArrEq 'cands: status, adb, live, fallback order' @('5645', '5646', '5655', '5555') (Cands 'Rvc64_9' @{ 'status.adb_port' = '5645'; 'adb_port' = '5646' } @('5655'))
    ArrEq 'cands: live-only rescue before fallback' @('5646', '5555') (Cands 'Rvc64' @{} @('5646'))
    ArrEq 'cands: all duplicates collapse' @('5555') (Cands 'Rvc64' @{ 'status.adb_port' = '5555'; 'adb_port' = '5555' } @('5555', '5555'))
    ArrEq 'cands: live duplicates preserve first unique order' @('5557', '5558', '5555') (Cands 'Rvc64' @{} @('5557', '5557', '5558', '5555'))
    ArrEq 'cands: instance name with regex chars is escaped' @('5678', '5555') (Cands 'Rvc64_1+test' @{ 'status.adb_port' = '5678' } @())

    Section 'ADB Candidate Ports - Shape Regression'
    $shapeCases = @(
        @{ Name = 'one conf'; Keys = @{ 'status.adb_port' = '5555' }; Live = @() },
        @{ Name = 'two conf'; Keys = @{ 'status.adb_port' = '5555'; 'adb_port' = '5557' }; Live = @() },
        @{ Name = 'conf plus live'; Keys = @{ 'status.adb_port' = '5555' }; Live = @('5557') },
        @{ Name = 'many live'; Keys = @{}; Live = @('5556', '5557', '5558') }
    )
    foreach ($case in $shapeCases) {
        $ports = @(Cands 'Rvc64' $case.Keys $case.Live)
        Ok "cands shape: $($case.Name) is flat strings" (IsFlatStringArray $ports)
        $serials = @()
        foreach ($p in @(Cands 'Rvc64' $case.Keys $case.Live)) { $serials += "127.0.0.1:$p" }
        Ok "cands shape: $($case.Name) serials have no joined ports" (($serials -join '|') -notmatch '\d+\s+\d+' -and ($serials -join '|') -notmatch 'System\.Object')
    }

    Section 'ADB Candidate Ports - Exhaustive Matrix'
    $statusVals = @($null, '5555', '5557', '5585')
    $adbVals = @($null, '5555', '5557', '5595')
    $liveSets = @(
        @(),
        @('5555'),
        @('5557'),
        @('5557', '5558'),
        @('5585', '5595', '5555')
    )
    $matrix = 0
    foreach ($st in $statusVals) {
        foreach ($ap in $adbVals) {
            foreach ($lv in $liveSets) {
                $keys = @{}
                if ($st) { $keys['status.adb_port'] = $st }
                if ($ap) { $keys['adb_port'] = $ap }
                $actual = @(Cands 'Rvc64' $keys $lv)
                $expected = @(Expected-Cands $keys $lv)
                $matrix++
                ArrEq ("matrix cands #{0}: st={1} adb={2} live={3}" -f $matrix, $(if($st){$st}else{'-'}) , $(if($ap){$ap}else{'-'}) , ($lv -join '+')) $expected $actual
                Ok ("matrix shape #{0}: flat/no spaces" -f $matrix) (IsFlatStringArray $actual)
            }
        }
    }

    Section 'ADB Server Port Selection'
    $savedPort = $env:ANDROID_ADB_SERVER_PORT
    try {
        Remove-Item Env:\ANDROID_ADB_SERVER_PORT -ErrorAction SilentlyContinue
        $serverCases = @(
            @{ Name='all free'; State=@{}; Expected='15037' },
            @{ Name='15037 other'; State=@{15037='other'}; Expected='15038' },
            @{ Name='two others'; State=@{15037='other';15038='other'}; Expected='15039' },
            @{ Name='ours reused'; State=@{15037='ours'}; Expected='15037' },
            @{ Name='free before ours wins'; State=@{15037='other';15039='ours'}; Expected='15038' },
            @{ Name='all occupied fallback'; State=@{}; Expected='15037'; Fill=$true }
        )
        foreach ($case in $serverCases) {
            $state = $case.State
            if ($case.Fill) { $state = @{}; foreach ($p in 15037..15057) { $state[$p] = 'other' } }
            $script:AdbServerPortProbe = { $state }.GetNewClosure()
            Eq "adb-server: $($case.Name)" $case.Expected (Resolve-AdbServerPort)
        }
        $script:AdbServerPortProbe = { @{} }
        $env:ANDROID_ADB_SERVER_PORT = '5037'
        Eq 'adb-server: inherited 5037 ignored' '15037' (Resolve-AdbServerPort)
        $env:ANDROID_ADB_SERVER_PORT = '15040'
        Eq 'adb-server: private override honoured' '15040' (Resolve-AdbServerPort)
    } finally {
        $script:AdbServerPortProbe = $null
        Remove-Item Env:\ANDROID_ADB_SERVER_PORT -ErrorAction SilentlyContinue
        if ($savedPort) { $env:ANDROID_ADB_SERVER_PORT = $savedPort }
    }

    Section 'HD-Player Instance Matcher'
    $cmdCases = @(
        @('space exact', '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance Rvc64', 'Rvc64', $true),
        @('quoted exact', '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance "Rvc64"', 'Rvc64', $true),
        @('equals exact', '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance=Rvc64', 'Rvc64', $true),
        @('case insensitive', 'HD-Player.exe --INSTANCE rvc64', 'Rvc64', $true),
        @('clone exact', 'HD-Player.exe --instance Rvc64_1', 'Rvc64_1', $true),
        @('clone not base', 'HD-Player.exe --instance Rvc64_1', 'Rvc64', $false),
        @('prefix not enough', 'HD-Player.exe --instance Rvc64Extra', 'Rvc64', $false),
        @('wrong switch', 'HD-Player.exe --instanceName Rvc64', 'Rvc64', $false),
        @('other instance', 'HD-Player.exe --instance Pie64', 'Rvc64', $false),
        @('missing commandline', '', 'Rvc64', $false),
        @('missing name', 'HD-Player.exe --instance Rvc64', '', $false)
    )
    foreach ($c in $cmdCases) { Ok "hdplayer: $($c[0])" ((Test-HdPlayerInstance $c[1] $c[2]) -eq $c[3]) }

    Section 'AdbOk Transport Classifier'
    $adbCases = @(
        @('plain success', 'uid=0(root) gid=0(root)', $true),
        @('empty success', '', $true),
        @('not found quoted', "error: device '127.0.0.1:5555' not found", $false),
        @('not found unquoted', 'error: device 127.0.0.1:5555 not found', $false),
        @('no devices', 'error: no devices/emulators found', $false),
        @('offline', 'error: device offline', $false),
        @('closed', 'error: closed', $false),
        @('daemon text ok', '* daemon started successfully *', $true)
    )
    foreach ($c in $adbCases) { Ok "adbok: $($c[0])" ((AdbOk $c[1]) -eq $c[2]) }

    Section 'Parse-AdbState (get-state classifier)'
    Eq 'state: device' 'device' (Parse-AdbState "device`n")
    Eq 'state: offline' 'offline' (Parse-AdbState 'offline')
    Eq 'state: skips daemon-start noise' 'device' (Parse-AdbState "* daemon not running; starting now on tcp:15037 *`n* daemon started successfully *`ndevice")
    Eq 'state: not-found line preserved' "error: device '127.0.0.1:5555' not found" (Parse-AdbState "error: device '127.0.0.1:5555' not found")
    Eq 'state: empty -> empty' '' (Parse-AdbState '')
    Ok 'state: offline is not device' ((Parse-AdbState 'offline') -ne 'device')

    Section 'Player.log boot/liveness signals'
    $plReady    = '2026-06-03 15:11:46.616-0400 5988 13764 PLR    Rvc64 [Ready] I: HomeActivity shown'
    $plStarting = '2026-06-03 15:11:10.000-0400 5988 2360  SER    Rvc64 [StartingAndroid] I: GUEST booting'
    $plOther    = '2026-06-03 15:11:46.616-0400 5988 13764 PLR    Tiramisu64_9 [Ready] I: shown'
    $plClone    = '2026-06-03 15:11:46.616-0400 5988 13764 PLR    Rvc64_9 [Ready] I: shown'
    function Probe([string]$txt) { $script:PlayerLogProbe = { $txt }.GetNewClosure() }
    Probe $plReady;    Ok 'plog: [Ready] -> ready'           (Test-PlayerLogReady 'Rvc64'); Ok 'plog: [Ready] -> alive' (Test-PlayerLogAlive 'Rvc64')
    Probe $plStarting; Ok 'plog: [StartingAndroid] not ready' (-not (Test-PlayerLogReady 'Rvc64')); Ok 'plog: [StartingAndroid] alive' (Test-PlayerLogAlive 'Rvc64')
    Probe $plOther;    Ok 'plog: other instance not ready'   (-not (Test-PlayerLogReady 'Rvc64')); Ok 'plog: other instance not alive' (-not (Test-PlayerLogAlive 'Rvc64'))
    Probe $plClone;    Ok 'plog: clone tag not base ready'   (-not (Test-PlayerLogReady 'Rvc64'))
    Probe '';          Ok 'plog: empty not ready'            (-not (Test-PlayerLogReady 'Rvc64')); Ok 'plog: empty not alive' (-not (Test-PlayerLogAlive 'Rvc64'))
    $script:PlayerLogProbe = $null

    Section 'Compact-Line'
    Eq 'compact: newline collapse' 'a | b | c' (Compact-Line "a`r`nb`nc" 80)
    Eq 'compact: no truncate at max' 'abcdef' (Compact-Line 'abcdef' 6)
    Eq 'compact: truncates with ellipsis' 'abcdefg...' (Compact-Line 'abcdefghijklmnop' 10)
    Eq 'compact: trims whitespace' 'hello' (Compact-Line '  hello  ' 20)

    Section 'Find-StraySu'
    $suCases = @(
        @('clean magisk links', "/system/bin/su|link|./magisk`n/sbin/su|link|/sbin/.magisk/busybox/magisk", ''),
        @('xbin file', "/system/bin/su|link|./magisk`n/system/xbin/su|file|", '/system/xbin/su'),
        @('bad symlink', "/system/xbin/su|link|/data/local/tmp/su", '/system/xbin/su'),
        @('two real files', "/system/xbin/su|file|`n/vendor/bin/su|file|", '/system/xbin/su,/vendor/bin/su'),
        @('malformed ignored', "garbage`n|||`n/system/bin/su|link|./magisk", ''),
        @('empty', '', '')
    )
    foreach ($c in $suCases) { Eq "stray: $($c[0])" $c[2] ((Find-StraySu $c[1]) -join ',') }

    Section 'Extract-Block + self-read memoization'
    # Build a fake single-file .cmd carrying three embedded blocks, then prove Extract-Block returns
    # each block's content AND reads the (large) self file only ONCE total across the three calls.
    $mk = { param($tok) "__BSR_${tok}_" + 'BEGIN__' }   # build markers by concat (no literal token here)
    $fakeCmdLines = @(
        'rem head',
        (& $mk 'DFS'), 'DFS-PAYLOAD-AAA', ('__BSR_DFS_' + 'END__'),
        (& $mk 'BSRSU'), 'BSRSU-PAYLOAD-BBB', ('__BSR_BSRSU_' + 'END__'),
        (& $mk 'APK'), 'APK-PAYLOAD-CCC', ('__BSR_APK_' + 'END__'),
        'rem tail'
    )
    $fakeRoot = Join-Path $env:TEMP ("bsr_mag_self_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
    $script:made.Add($fakeRoot)
    $fakeCmd = Join-Path $fakeRoot 'blueStackRoot.cmd'
    [IO.File]::WriteAllText($fakeCmd, (($fakeCmdLines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $script:SelfCmdTextCache = @{}; $script:SelfReadCount = 0
    $dfs = (Extract-Block $fakeCmd 'DFS' 'DFS').Trim()
    $su = (Extract-Block $fakeCmd 'BSRSU' 'BSRSU').Trim()
    $apk = (Extract-Block $fakeCmd 'APK' 'APK').Trim()
    Eq 'extract: DFS block content' 'DFS-PAYLOAD-AAA' $dfs
    Eq 'extract: BSRSU block content' 'BSRSU-PAYLOAD-BBB' $su
    Eq 'extract: APK block content' 'APK-PAYLOAD-CCC' $apk
    Eq 'extract: self .cmd read ONCE for 3 extractions (memoized)' 1 $script:SelfReadCount
    Ok 'extract: cached text == fresh ReadAllText' ($script:SelfCmdTextCache[$fakeCmd] -eq ([IO.File]::ReadAllText($fakeCmd)))
    Ok 'extract: missing marker -> $null' ($null -eq (Extract-Block $fakeCmd 'NOPE' 'NOPE'))

    Section 'Set-ConfKey (modify-only, UTF-8 no BOM)'
    $confRoot = Join-Path $env:TEMP ("bsr_mag_conf_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $confRoot -Force | Out-Null
    $script:made.Add($confRoot)
    $confPath = Join-Path $confRoot 'bluestacks.conf'
    $seed = @('bst.feature.rooting="0"', 'bst.instance.Rvc64_1+x.enable_root_access="0"')  # +/. = regex-special key
    [IO.File]::WriteAllText($confPath, (($seed -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $script:Conf = $confPath
    Set-ConfKey 'bst.feature.rooting' '1'
    Set-ConfKey 'bst.instance.Rvc64_1+x.enable_root_access' '1'   # exercises [regex]::Escape on the key
    Set-ConfKey 'bst.does.not.exist' '1'                          # absent key -> must NOT be added
    $confTxt = [IO.File]::ReadAllText($confPath)
    Ok 'confkey: existing flag flipped to 1' ($confTxt -match 'bst\.feature\.rooting="1"')
    Ok 'confkey: regex-special instance key flipped' ($confTxt -match 'Rvc64_1\+x\.enable_root_access="1"')
    Ok 'confkey: absent key not added' ($confTxt -notmatch 'bst\.does\.not\.exist')
    $cb = [IO.File]::ReadAllBytes($confPath)
    Ok 'confkey: no UTF-8 BOM' (-not ($cb.Length -ge 3 -and $cb[0] -eq 0xEF -and $cb[1] -eq 0xBB -and $cb[2] -eq 0xBF))

} finally {
    $script:LiveAdbPortProbe = $null
    $script:AdbServerPortProbe = $null
    $script:PlayerLogProbe = $null
    foreach ($d in $script:made) { try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit ([int]($script:fail -gt 0))
