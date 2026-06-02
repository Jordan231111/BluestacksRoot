<#
  Run-Live-E2E.ps1  --  REAL end-to-end proof against a LIVE BlueStacks instance, through the
  SHIPPED Magisk pipeline (the same `-Action Auto` the .cmd runs). It proves Magisk ends up as the
  SOLE root with NO competing su -- i.e. it would FAIL on the "Abnormal State -- a su binary not from
  Magisk has been detected" regression -- and that this survives a reboot.

  !!  THIS MODIFIES A REAL INSTANCE.  Use a THROWAWAY CLONE you created in the Multi-Instance Manager.
  !!  Do NOT point it at an instance you care about.  Run with -Revert afterwards (Magisk Undo).

  History note: a previous version of this harness rooted via the engine's *legacy classic-su* path
  (`-Action AdbRoot`), which installs a setuid /system/xbin/su -- a competing root that makes Magisk
  report "Abnormal State". That was the wrong thing to test (it is not what the tool ships) and it
  left that su behind on the shared master. This version drives the actual Magisk pipeline and asserts
  the no-competing-su invariant instead.

  What it does (default):
    1. resolve paths for -Instance (engine Resolve)
    2. run  bsr_magisk.ps1 -Action Auto  (Prep -> Data -> Clean -> Finalize -> Verify), self-extracting
       the embedded debugfs / bootstrap su / Magisk APK from the .cmd -- exactly the shipped path
    3. ASSERT the pipeline reached "VERIFY PASS" and reported NO competing su
    4. independently re-check over adb: uid=0, /system/bin/su -> magisk, NO /system/xbin/su,
       `magisk -c` is the kitsune build, the manager package is installed; screenshot the app
    5. reboot and re-assert uid=0 + still NO /system/xbin/su (persistence)

  Usage (Administrator):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Live-E2E.ps1 -Instance Tiramisu64_9
    ...                                                                        -Revert -Instance Tiramisu64_9
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Instance,
    [string]$Cmd,
    [string]$Engine,
    [string]$Adb,
    [string]$Player,
    [string]$InstallDir,
    [string]$DataDir,
    [string]$Shots,
    [int]$BootTimeout = 300,
    [switch]$Revert
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $Cmd) { $Cmd = Join-Path $repo 'blueStackRoot.cmd' }
if (-not $Engine) { $Engine = Join-Path $repo 'tools\bsr_engine.ps1' }
$Magisk = Join-Path $repo 'tools\bsr_magisk.ps1'
if (-not $Shots) { $Shots = Join-Path $here 'live-shots' }
if (-not (Test-Path $Shots)) { New-Item -ItemType Directory -Path $Shots -Force | Out-Null }
$PKG = 'io.github.huskydg.magisk'   # the bundled Kitsune Mask package (NOT com.topjohnwu.magisk)

# ---- registry discovery (nxt then msi5) ----
function Reg1($k, $n) { try { (Get-ItemProperty -Path $k -Name $n -EA Stop).$n } catch { $null } }
if (-not $InstallDir -or -not $DataDir) {
    foreach ($k in @('HKLM:\SOFTWARE\BlueStacks_nxt', 'HKLM:\SOFTWARE\BlueStacks_msi5')) {
        if (Test-Path $k) {
            if (-not $InstallDir) { $InstallDir = Reg1 $k 'InstallDir' }
            if (-not $DataDir) { $DataDir = Reg1 $k 'DataDir'; if (-not $DataDir) { $DataDir = Reg1 $k 'UserDefinedDir' } }
            if ($InstallDir) { break }
        }
    }
}
if (-not $InstallDir) { $InstallDir = 'C:\Program Files\BlueStacks_nxt' }
if (-not $DataDir) { $DataDir = Join-Path $env:ProgramData 'BlueStacks_nxt' }
if (-not $Adb) { $Adb = Join-Path $InstallDir 'HD-Adb.exe' }
if (-not $Player) { $Player = Join-Path $InstallDir 'HD-Player.exe' }
foreach ($f in @($Cmd, $Engine, $Magisk, $Adb)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f" } }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { throw 'Run elevated (Administrator).' }

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "  [..] $m" -ForegroundColor DarkGray }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# isolate HD-Adb on its own server port (immune to a different-version system adb on 5037)
if (-not $env:ANDROID_ADB_SERVER_PORT) { $env:ANDROID_ADB_SERVER_PORT = '15037' }
function Adb([string[]]$a) { $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { (& $Adb @a 2>&1 | Out-String) } finally { $ErrorActionPreference = $o } }
function Ps([string[]]$a) { $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @a 2>&1 | Out-String } finally { $ErrorActionPreference = $o } }

# resolve instance paths via the engine
$base = $Instance -replace '_\d+$', ''
$res = Ps @($Engine, '-Action', 'Resolve', '-DataDir', $DataDir, '-Base', $base)
$paths = @{}; foreach ($l in ($res -split "`r?`n")) { if ("$l" -match '^(BSR_\w+)=(.*)$') { $paths[$Matches[1]] = $Matches[2] } }
$conf = if ($paths['BSR_CONF']) { $paths['BSR_CONF'] } else { Join-Path $DataDir 'bluestacks.conf' }
$vhd = $paths['BSR_VHD']
# the EXACT instance's adb port from conf (Resolve matches the base, which may be a different clone)
$adbPort = '5555'
if (Test-Path -LiteralPath $conf) {
    $ct = [IO.File]::ReadAllText($conf); $esc = [regex]::Escape($Instance)
    $m = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.status\.adb_port\s*=\s*"?(\d+)"?')
    if (-not $m.Success) { $m = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.adb_port\s*=\s*"?(\d+)"?') }
    if ($m.Success) { $adbPort = $m.Groups[1].Value }
}
$script:serial = "127.0.0.1:$adbPort"
Write-Host "instance=$Instance  master.vhd=$vhd  adb=$script:serial  pkg=$PKG" -ForegroundColor DarkGray
if (-not (Test-Path -LiteralPath $vhd)) { throw "master Root.vhd not found: $vhd  (create the throwaway clone + open it once first)" }

# Wait for boot, trying the conf port AND any live-bound port in the BlueStacks band; pins $serial.
function Wait-Boot([int]$sec) {
    Adb @('start-server') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        $cands = @($adbPort) + @(Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object { $_.LocalPort -ge 5550 -and $_.LocalPort -le 5900 } | Select-Object -Expand LocalPort)
        foreach ($p in ($cands | Select-Object -Unique)) {
            $s = "127.0.0.1:$p"; Adb @('connect', $s) | Out-Null
            if ((Adb @('-s', $s, 'shell', 'getprop', 'sys.boot_completed')).Trim() -match '1') { $script:serial = $s; Start-Sleep 3; return $true }
        }
        Start-Sleep 3
    }
    return $false
}
function Shot([string]$name) {
    $png = Join-Path $Shots $name; $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Adb -s $script:serial exec-out screencap -p > $png } finally { $ErrorActionPreference = $o }
    if ((Test-Path $png) -and (Get-Item $png).Length -gt 1000) { Info "shot -> $png" } else { Info "screenshot failed ($name)" }
}

# ---------------------------------------------------------------- REVERT (Magisk Undo)
if ($Revert) {
    Step "REVERT '$Instance' (Magisk Undo)"
    Ps @($Magisk, '-Action', 'Undo', '-Instance', $Instance, '-SelfCmd', $Cmd, '-Vhd', $vhd, '-Conf', $conf, '-Install', $InstallDir) | Write-Host
    Write-Host "`nReverted ($Instance). The shared master + HD-Player patch are left intact unless you passed -Full to Undo." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- ROOT via the SHIPPED Magisk pipeline
Step "1) run the FULL Magisk pipeline (bsr_magisk.ps1 -Action Auto; embedded debugfs/su/APK)"
$autoOut = Ps @($Magisk, '-Action', 'Auto', '-Instance', $Instance, '-SelfCmd', $Cmd, '-Engine', $Engine, '-Vhd', $vhd, '-Conf', $conf, '-Install', $InstallDir)
$autoRc = $LASTEXITCODE
Write-Host $autoOut
if ($autoRc -eq 0) { Ok "pipeline exited 0" } else { No "pipeline exit code = $autoRc" }
if ($autoOut -match 'VERIFY PASS') { Ok "pipeline reached VERIFY PASS (Magisk sole root, no competing su, no bsr_su traces)" } else { No "pipeline did NOT print VERIFY PASS" }
if ($autoOut -match 'competing su\s*:\s*none') { Ok "pipeline reported NO competing su" }
elseif ($autoOut -match 'competing su\s*:\s*\S') { No "pipeline reported a COMPETING su (Abnormal-State regression)" }

# ---------------------------------------------------------------- independent adb re-check
Step "2) independent verification over adb"
if (-not (Wait-Boot $BootTimeout)) { No "instance not reachable" }
$id = (Adb @('-s', $script:serial, 'shell', 'su -c id')).Trim()
if ($id -match 'uid=0') { Ok "su -c id => $id" } else { No "uid=0 not returned ($id)" }
$binsu = (Adb @('-s', $script:serial, 'shell', 'readlink /system/bin/su')).Trim()
if ($binsu -match 'magisk') { Ok "/system/bin/su -> $binsu" } else { No "/system/bin/su not -> magisk ($binsu)" }
$xbin = (Adb @('-s', $script:serial, 'shell', 'su -c "ls -l /system/xbin/su 2>&1"')).Trim()
if ($xbin -match 'No such file|not found') { Ok "NO /system/xbin/su (competing su is gone)" } else { No "competing /system/xbin/su present: $xbin" }
$mv = (Adb @('-s', $script:serial, 'shell', 'su -c "magisk -c"')).Trim()
if ($mv -match 'kitsune') { Ok "magisk -c => $mv" } else { No "magisk version unexpected ($mv)" }
$pkg = (Adb @('-s', $script:serial, 'shell', "pm path $PKG")).Trim()
if ($pkg -match 'package:') { Ok "manager installed: $pkg" } else { Info "manager package not found via pm path ($pkg)" }
Shot 'magisk_e2e.png'

# ---------------------------------------------------------------- reboot persistence
Step "3) reboot + re-assert (persistence)"
Adb @('-s', $script:serial, 'reboot') | Out-Null; Start-Sleep 8
if (-not (Wait-Boot $BootTimeout)) { No "did not come back after reboot" }
else {
    $id2 = (Adb @('-s', $script:serial, 'shell', 'su -c id')).Trim()
    if ($id2 -match 'uid=0') { Ok "root PERSISTS after reboot (uid=0)" } else { No "root lost after reboot ($id2)" }
    $xbin2 = (Adb @('-s', $script:serial, 'shell', 'su -c "ls -l /system/xbin/su 2>&1"')).Trim()
    if ($xbin2 -match 'No such file|not found') { Ok "still NO competing /system/xbin/su after reboot" } else { No "competing su reappeared: $xbin2" }
    Shot 'magisk_e2e_after_reboot.png'
}

Write-Host "`n================ LIVE E2E SUMMARY ================" -ForegroundColor Cyan
Write-Host ("  PASS=$pass  FAIL=$fail   screenshots in $Shots") -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host "  Undo with:  -Revert -Instance $Instance" -ForegroundColor DarkGray
exit ([int]($fail -gt 0))
