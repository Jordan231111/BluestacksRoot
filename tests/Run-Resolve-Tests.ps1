<#
  Run-Resolve-Tests.ps1 -- unit tests for PATH + ADB-PORT resolution (no BlueStacks, no admin).

  These cover the "nothing hardcoded" guarantees: a custom install/data location (resolved from the
  registry or passed in) and a non-default adb port (5555 is NOT assumed -- clones use 5585/5595/...).
  They exercise BOTH scripts so they stay consistent:
    * engine  bsr_engine.ps1   -Action BaseDir / Resolve   (run as a child process, like the .cmd does)
    * magisk  bsr_magisk.ps1   Get-AdbPortCandidates / Get-DataRoot   (dot-sourced; the dispatch guard
                                                                       keeps the pipeline from running)

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Resolve-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [string]$Magisk
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Engine) { $Engine = (Resolve-Path (Join-Path $Here '..\tools\bsr_engine.ps1')).Path }
if (-not $Magisk) { $Magisk = (Resolve-Path (Join-Path $Here '..\tools\bsr_magisk.ps1')).Path }
$script:pass = 0; $script:fail = 0
function Ok([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $name $detail" -ForegroundColor Red }
}
function Eq([string]$name, $expected, $actual) { Ok $name ("$expected" -eq "$actual") "(expected '$expected', got '$actual')" }

# Run the engine as a child process (exactly how blueStackRoot.cmd calls it).
function Eng([string[]]$a) { & powershell -NoProfile -ExecutionPolicy Bypass -File $Engine @a 2>&1 }

# Expand any 8.3 short path component (e.g. CI's C:\Users\RUNNER~1\... for 'runneradmin') to its long
# form. The engine resolves the on-disk Root.vhd, so it returns the long path; without this the expected
# string (built from $env:TEMP, which the runner reports short) would mismatch purely on 8.3 vs long.
Add-Type -ErrorAction SilentlyContinue -Name Native -Namespace BSR -MemberDefinition '
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetLongPathName(string lpszShortPath, System.Text.StringBuilder lpszLongPath, uint cchBuffer);'
function Long([string]$p) {
    if (-not $p) { return $p }
    try { $sb = New-Object System.Text.StringBuilder 1024; $n = [BSR.Native]::GetLongPathName($p, $sb, 1024); if ($n -gt 0 -and $n -lt 1024) { return $sb.ToString() } } catch { }
    return $p
}

# ---------------------------------------------------------------------------
# Build a throwaway BlueStacks-shaped DataDir at a NON-default (custom) location.
# ---------------------------------------------------------------------------
$script:Made = New-Object System.Collections.Generic.List[string]
function New-FakeData([string]$instance, [hashtable]$confKeys, [string]$tag = 'rtest') {
    $root = Join-Path $env:TEMP ("bsr_${tag}_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $eng = Join-Path $root "Engine\$instance"
    New-Item -ItemType Directory -Path $eng -Force | Out-Null
    $ud = Join-Path $root 'UserData'; New-Item -ItemType Directory -Path $ud -Force | Out-Null
    $script:Made.Add($root)
    $lines = @('bst.feature.rooting="0"', 'bst.enable_adb_access="1"')
    foreach ($k in $confKeys.Keys) { $lines += ('bst.instance.' + $instance + '.' + $k + '="' + $confKeys[$k] + '"') }
    [IO.File]::WriteAllText((Join-Path $root 'bluestacks.conf'), (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $ud 'MimMetaData.json'), ('{"Instances":[{"InstanceName":"' + $instance + '"}]}'))
    $bstk = '<?xml version="1.0"?><VirtualBox><Machine name="' + $instance + '"><MediaRegistry><HardDisks>' +
            '<HardDisk format="VHD" location="Root.vhd" type="Readonly"/></HardDisks></MediaRegistry></Machine></VirtualBox>'
    [IO.File]::WriteAllText((Join-Path $eng "$instance.bstk"), $bstk)
    [IO.File]::WriteAllBytes((Join-Path $eng 'Root.vhd'), (New-Object byte[] 64))
    return (Long $root)   # long-path form so expected paths match the engine's disk-resolved VHD path
}
function Resolve-Map([string]$dataDir, [string]$base) {
    $out = Eng @('-Action', 'Resolve', '-DataDir', $dataDir, '-Base', $base)
    $h = @{}; foreach ($l in $out) { if ("$l" -match '^(BSR_[A-Z]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
    return $h
}

Write-Host "`n=== PATH resolution (engine BaseDir / Resolve) ===" -ForegroundColor Cyan

# 1) custom data location, normal layout
$d1 = New-FakeData 'Pie64' @{ 'status.adb_port' = '5555' }
Eq 'BaseDir returns the custom data root (not a hardcoded ProgramData path)' $d1 (Eng @('-Action', 'BaseDir', '-DataDir', $d1) | Select-Object -Last 1)

# 2) DataDir reported as ...\Engine (newer BlueStacks) is normalized to the base
Eq 'BaseDir strips a trailing \Engine to the base folder' $d1 (Eng @('-Action', 'BaseDir', '-DataDir', (Join-Path $d1 'Engine')) | Select-Object -Last 1)

# 3) trailing backslash is tolerated
Eq 'BaseDir tolerates a trailing backslash' $d1 (Eng @('-Action', 'BaseDir', '-DataDir', ($d1 + '\')) | Select-Object -Last 1)

# 4) full Resolve maps conf/bstk/vhd under the custom location
$m1 = Resolve-Map $d1 'Pie64'
Eq 'Resolve: instance'  'Pie64' $m1['BSR_INSTANCE']
Eq 'Resolve: master'    'Pie64' $m1['BSR_MASTER']
Eq 'Resolve: conf path' (Join-Path $d1 'bluestacks.conf') $m1['BSR_CONF']
Eq 'Resolve: vhd path'  (Join-Path $d1 'Engine\Pie64\Root.vhd') $m1['BSR_VHD']
Ok 'Resolve: bstk under custom root' ($m1['BSR_BSTK'] -eq (Join-Path $d1 'Engine\Pie64\Pie64.bstk'))

# 5) a clone instance resolves its master (Rvc64_3 -> Rvc64) and keeps its own bstk/vhd
$m2 = Resolve-Map (New-FakeData 'Rvc64_3' @{ 'status.adb_port' = '5585' }) 'Rvc64'
Eq 'Resolve(clone): instance' 'Rvc64_3' $m2['BSR_INSTANCE']
Eq 'Resolve(clone): master'   'Rvc64'   $m2['BSR_MASTER']

Write-Host "`n=== ADB PORT resolution (engine Resolve -- NOT hardcoded 5555) ===" -ForegroundColor Cyan
Eq 'engine: status.adb_port wins'                  '5585' (Resolve-Map (New-FakeData 'Rvc64' @{ 'status.adb_port' = '5585' } 'p') 'Rvc64')['BSR_ADBPORT']
Eq 'engine: falls back to adb_port if no status'   '5595' (Resolve-Map (New-FakeData 'Rvc64' @{ 'adb_port' = '5595' } 'p') 'Rvc64')['BSR_ADBPORT']
Eq 'engine: defaults to 5555 when neither present' '5555' (Resolve-Map (New-FakeData 'Rvc64' @{} 'p') 'Rvc64')['BSR_ADBPORT']

Write-Host "`n=== ADB PORT candidates (orchestrator, dot-sourced) ===" -ForegroundColor Cyan
. $Magisk   # dispatch guard => nothing boots; functions become available
# Stub the live-bound-port scan so these conf-only cases are deterministic regardless of what is
# actually listening on the test host (the seam Get-LiveAdbPorts checks first).
$script:LiveAdbPortProbe = { @() }
function Cands([string]$dataDir, [string]$inst) {
    $script:Conf = Join-Path $dataDir 'bluestacks.conf'
    $script:Instance = $inst
    , (Get-AdbPortCandidates)
}
Eq 'cands: single 5555 (deduped against fallback)' '5555'      ((Cands (New-FakeData 'Pie64' @{ 'status.adb_port' = '5555' } 'c') 'Pie64') -join ',')
Eq 'cands: non-5555 first, 5555 fallback'          '5585,5555' ((Cands (New-FakeData 'Rvc64_3' @{ 'status.adb_port' = '5585' } 'c') 'Rvc64_3') -join ',')
Eq 'cands: adb_port used when status absent'        '5595,5555' ((Cands (New-FakeData 'Rvc64' @{ 'adb_port' = '5595' } 'c') 'Rvc64') -join ',')
# stale-status case (Rvc64_4 in the wild: status=5555 stale, adb_port=5595 real) -> BOTH tried
Eq 'cands: stale status + real adb_port both tried' '5555,5595' ((Cands (New-FakeData 'Rvc64_4' @{ 'status.adb_port' = '5555'; 'adb_port' = '5595' } 'c') 'Rvc64_4') -join ',')
Eq 'cands: no keys -> just the 5555 fallback'       '5555'      ((Cands (New-FakeData 'Foo' @{} 'c') 'Foo') -join ',')

Write-Host "`n=== ADB PORT candidates: live-bound-port merge (rescues a stale conf) ===" -ForegroundColor Cyan
# conf ports stay FIRST (authoritative when fresh); the live-bound port is appended; 5555 last.
$script:LiveAdbPortProbe = { @('5646') }
Eq 'cands: live bound port appended after conf'      '5645,5646,5555' ((Cands (New-FakeData 'Rvc64_9' @{ 'status.adb_port' = '5645' } 'c') 'Rvc64_9') -join ',')
# the real-world failure mode: conf records NEITHER the bound port -> live scan is the only rescue.
$script:LiveAdbPortProbe = { @('5646') }
Eq 'cands: live bound port used when conf has none'  '5646,5555'      ((Cands (New-FakeData 'Bar' @{} 'c') 'Bar') -join ',')
# a live port that equals a conf port must NOT be duplicated.
$script:LiveAdbPortProbe = { @('5645', '5646') }
Eq 'cands: dedup live vs conf (5645 not repeated)'   '5645,5646,5555' ((Cands (New-FakeData 'Rvc64_9' @{ 'status.adb_port' = '5645' } 'c') 'Rvc64_9') -join ',')
$script:LiveAdbPortProbe = { @() }   # reset so later sections are unaffected

Write-Host "`n=== adb server port: free-port probe (handles a port already in use) ===" -ForegroundColor Cyan
$savedPort = $env:ANDROID_ADB_SERVER_PORT
Remove-Item Env:\ANDROID_ADB_SERVER_PORT -ErrorAction SilentlyContinue
$script:AdbServerPortProbe = { @{} }                                   # nothing listening -> base port
Eq 'adb-port: all free -> base 15037'                 '15037' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = { @{ 15037 = 'other' } }                  # a stranger holds 15037
Eq 'adb-port: 15037 taken by a stranger -> 15038'     '15038' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = { @{ 15037 = 'other'; 15038 = 'other' } } # two strangers -> skip both
Eq 'adb-port: skips two taken ports -> 15039'         '15039' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = { @{ 15037 = 'ours' } }                   # our own HD-Adb server -> reuse it
Eq 'adb-port: our own HD-Adb server -> reuse 15037'   '15037' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = { @{ 15037 = 'other'; 15039 = 'ours' } }  # first FREE wins over a later reusable
Eq 'adb-port: stranger on 15037 -> first free 15038'  '15038' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = { @{} }
$env:ANDROID_ADB_SERVER_PORT = '5037'                                  # unsafe inherited default is ignored
Eq 'adb-port: inherited default 5037 is ignored'       '15037' (Resolve-AdbServerPort)
$env:ANDROID_ADB_SERVER_PORT = '15040'                                 # private-band override is honoured
Eq 'adb-port: private env override is respected'       '15040' (Resolve-AdbServerPort)
$script:AdbServerPortProbe = $null
Remove-Item Env:\ANDROID_ADB_SERVER_PORT -ErrorAction SilentlyContinue
if ($savedPort) { $env:ANDROID_ADB_SERVER_PORT = $savedPort }

Write-Host "`n=== HD-Player instance matching (Rvc64 scoped launch/wait) ===" -ForegroundColor Cyan
Ok 'hdplayer: spaced target arg matches' (Test-HdPlayerInstance '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance Rvc64' 'Rvc64')
Ok 'hdplayer: quoted target arg matches' (Test-HdPlayerInstance '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance "Rvc64"' 'Rvc64')
Ok 'hdplayer: equals target arg matches' (Test-HdPlayerInstance '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance=Rvc64' 'Rvc64')
Ok 'hdplayer: clone name is not a prefix match' (-not (Test-HdPlayerInstance '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance Rvc64_1' 'Rvc64'))
Ok 'hdplayer: another instance does not match' (-not (Test-HdPlayerInstance '"C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance Pie64' 'Rvc64'))

Write-Host "`n=== competing-su detection (Find-StraySu -- what Verify fails on) ===" -ForegroundColor Cyan
# Magisk's own su are symlinks to magisk; anything else is a competing root (Magisk "Abnormal State").
Eq 'stray: clean Magisk (all -> magisk) = none'         '' (((Find-StraySu "/system/bin/su|link|./magisk`n/sbin/su|link|./magisk")) -join ',')
Eq 'stray: the engine-su leak at /system/xbin/su'        '/system/xbin/su' (((Find-StraySu "/system/bin/su|link|./magisk`n/system/xbin/su|file|")) -join ',')
Eq 'stray: a symlink NOT to magisk is competing'         '/system/xbin/su' (((Find-StraySu "/system/xbin/su|link|/data/local/tmp/su")) -join ',')
Eq 'stray: real su in two dirs (both flagged)'           '/system/xbin/su,/vendor/bin/su' (((Find-StraySu "/system/bin/su|link|/system/bin/magisk`n/system/xbin/su|file|`n/vendor/bin/su|file|")) -join ',')
Eq 'stray: empty inventory = none'                       '' (((Find-StraySu '')) -join ',')
Eq 'stray: malformed lines ignored'                      '' (((Find-StraySu "garbage`n|||`n/system/bin/su|link|./magisk")) -join ',')
Eq 'stray: magisk in a deep path target = ours'          '' (((Find-StraySu "/system/bin/su|link|/sbin/.magisk/busybox/magisk")) -join ',')

Write-Host "`n=== DataRoot resolution (orchestrator Get-DataRoot, custom/registry) ===" -ForegroundColor Cyan
Eq 'DataRoot: ...\Engine is normalized to base'      'X:\Custom\BS'   (Get-DataRoot ([pscustomobject]@{ DataDir = 'X:\Custom\BS\Engine'; UserDefinedDir = $null }))
Eq 'DataRoot: plain data dir kept as-is'             'X:\Custom\Data' (Get-DataRoot ([pscustomobject]@{ DataDir = 'X:\Custom\Data'; UserDefinedDir = $null }))
Eq 'DataRoot: UserDefinedDir used when DataDir empty' 'D:\BS'         (Get-DataRoot ([pscustomobject]@{ DataDir = $null; UserDefinedDir = 'D:\BS' }))
Ok 'DataRoot: null registry -> env ProgramData fallback (no hardcoded C: literal)' ((Get-DataRoot $null) -eq (Join-Path $env:ProgramData 'BlueStacks_nxt'))

# ---- cleanup ----
foreach ($d in $script:Made) { try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit ([int]($script:fail -gt 0))
