<#
  Run-Live-E2E.ps1  --  REAL end-to-end proof against a LIVE BlueStacks instance.

  This actually roots an instance and proves Magisk works across a reboot, the way
  a human would, but scripted + screenshotted so the result is visible and checkable.

  !!  THIS MODIFIES A REAL INSTANCE.  Use a THROWAWAY CLONE you created in the
  !!  Multi-Instance Manager.  Do NOT point it at an instance you care about.
  !!  (Pass -Revert afterwards, or use the cmd's Undo, to put it back.)

  What it does, in order (Action = Root, the default):
    1. kill emulator procs, resolve paths for -Instance
    2. .bstk -> Normal,  conf root/adb flags -> 1,  HD-Player integrity bypass
    3. boot the instance, wait for Android, push the embedded su over HD-Adb
       (engine Action AdbRoot) and prove `su -c id` => uid=0
    4. adb install the Magisk APK, launch it, screenshot the app
    5. adb reboot, wait for boot, prove su STILL gives uid=0, read `magisk -V`,
       screenshot the Magisk app again
  Screenshots land in -Shots (default tests\live-shots\).  Read them to SEE the
  Magisk "Installed" state before/after reboot.

  After you have visually confirmed Magisk's "Direct Install to system" + the
  SU-conflict message, run with -Revert to undo (or use the .cmd Undo menu).

  Usage (Administrator):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Live-E2E.ps1 -Instance Rvc64_2
    ...                                                                        -Revert -Instance Rvc64_2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Instance,
    [string]$Engine,
    [string]$Cmd,
    [string]$Adb,
    [string]$Player,
    [string]$InstallDir,
    [string]$DataDir,
    [string]$Magisk,
    [string]$Shots,
    [int]$BootTimeout = 300,
    [switch]$Revert,
    [switch]$SkipMagisk,
    [switch]$Unattended   # don't pause for the manual Magisk "Direct Install" GUI tap
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $Engine) { $Engine = Join-Path $repo 'tools\bsr_engine.ps1' }
if (-not $Cmd) { $Cmd = Join-Path $repo 'blueStackRoot.cmd' }
if (-not $Shots) { $Shots = Join-Path $here 'live-shots' }
if (-not (Test-Path $Shots)) { New-Item -ItemType Directory -Path $Shots -Force | Out-Null }

# ---- registry discovery (nxt then msi5) ----
function Reg1($key, $name) { try { (Get-ItemProperty -Path $key -Name $name -EA Stop).$name } catch { $null } }
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
if (-not $Adb) { $Adb = Join-Path $InstallDir 'HD-Adb.exe' }
if (-not $Player) { $Player = Join-Path $InstallDir 'HD-Player.exe' }
if (-not $Magisk) {
    foreach ($m in @((Join-Path $repo 'magiskkitsune.apk'), (Join-Path $repo 'Working Example & Fix\Magisk-27.2-kitsune-4.apk'))) {
        if (Test-Path -LiteralPath $m) { $Magisk = $m; break }
    }
}
foreach ($f in @($Engine, $Adb, $Player)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f" } }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { throw "Run elevated (Administrator)." }

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "  [..] $m" -ForegroundColor DarkGray }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# child PS with the engine, env-driven, capturing exit + text (stderr won't throw here)
function Eng([hashtable]$envv, [string[]]$a, [string]$label) {
    foreach ($k in $envv.Keys) { Set-Item -Path "Env:$k" -Value $envv[$k] }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine @a 2>&1 | Out-String }
    finally { $ErrorActionPreference = $old }
    if ($label) { Write-Host ("--- {0} (rc={1}) ---" -f $label, $LASTEXITCODE) -ForegroundColor DarkGray; Write-Host $o.Trim() }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
function Adb([string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& $Adb @a 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
}

# resolve instance paths via the engine (master/.bstk/conf/vhd/adbport)
$base = $Instance -replace '_\d+$', ''
$res = Eng @{ BSR_DATADIR = $DataDir; BSR_BASE = $base } @('-Action', 'Resolve') ''
$paths = @{}
foreach ($l in ($res.Out -split "`r?`n")) { if ($l -match '^(BSR_\w+)=(.*)$') { $paths[$Matches[1]] = $Matches[2] } }
$dataBase = $paths['BSR_DATADIR']
$bstk = Join-Path $dataBase "Engine\$Instance\$Instance.bstk"
$conf = Join-Path $dataBase 'bluestacks.conf'
$vhd = $paths['BSR_VHD']
$adbPort = if ($paths['BSR_ADBPORT']) { $paths['BSR_ADBPORT'] } else { '5555' }
# Resolve matches the base (may pick a clone) -- read the EXACT instance's port from conf
if (Test-Path -LiteralPath $conf) {
    try {
        $ct = Get-Content -Raw -LiteralPath $conf
        $esc = [regex]::Escape($Instance)
        $m = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.status\.adb_port\s*=\s*"?(\d+)"?')
        if (-not $m.Success) { $m = [regex]::Match($ct, '(?im)^\s*bst\.instance\.' + $esc + '\.adb_port\s*=\s*"?(\d+)"?') }
        if ($m.Success) { $adbPort = $m.Groups[1].Value }
    }
    catch { }
}
# rooting the master writes its OWN Root.vhd
$vhd = Join-Path $dataBase "Engine\$($Instance -replace '_\d+$','')\Root.vhd"
Write-Host "instance=$Instance  bstk=$bstk  vhd=$vhd  adb=127.0.0.1:$adbPort" -ForegroundColor DarkGray
if (-not (Test-Path -LiteralPath $bstk)) { throw ".bstk not found for '$Instance': $bstk  (create the throwaway clone first)" }

function Kill-Bst { foreach ($p in 'HD-Player', 'HD-MultiInstanceManager', 'BstkSVC', 'BlueStacksHelper') { Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }; Start-Sleep 2 }
$commonEnv = @{ BSR_BSTK = $bstk; BSR_CONF = $conf; BSR_INSTANCE = $Instance; BSR_VHD = $vhd;
    BSR_EXE = (Join-Path $InstallDir 'HD-Player.exe'); BSR_ADB = $Adb; BSR_PLAYER = $Player; BSR_ADBPORT = $adbPort; BSR_SELF = $Cmd
}

# ---------------------------------------------------------------- REVERT
if ($Revert) {
    Step "REVERT '$Instance'"
    Kill-Bst
    Eng $commonEnv @('-Action', 'Unroot') 'Unroot (remove su offline)' | Out-Null
    Eng $commonEnv @('-Action', 'Patch', '-Restore') 'Restore HD-Player.exe' | Out-Null
    Eng $commonEnv @('-Action', 'ConfUnroot') 'conf flags -> 0' | Out-Null
    Eng $commonEnv @('-Action', 'DiskRO') '.bstk -> Readonly' | Out-Null
    Write-Host "`nReverted. (Root.vhd backup, if made, is at $vhd.bsrbak)" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- ROOT + PROVE
Step "1) prepare disk / conf / integrity bypass"
Kill-Bst
$r1 = Eng $commonEnv @('-Action', 'DiskRW') '.bstk -> Normal'
$r2 = Eng $commonEnv @('-Action', 'ConfRoot') 'conf root/adb flags -> 1'
$r3 = Eng $commonEnv @('-Action', 'Patch') 'HD-Player integrity bypass'
if ($r1.Code -eq 0) { Ok "disk set R/W" } else { No "DiskRW failed" }
if ($r2.Code -eq 0) { Ok "conf flags set" } else { No "ConfRoot failed" }
if ($r3.Code -eq 0) { Ok "integrity bypass applied" } else { No "Patch failed" }

Step "2) boot + install su over adb (engine AdbRoot)"
$r4 = Eng $commonEnv @('-Action', 'AdbRoot') 'AdbRoot (boot, push su, verify uid=0)'
if ($r4.Code -eq 0 -and $r4.Out -match 'uid=0') { Ok "ONLINE root: su -c id => uid=0" }
elseif ($r4.Code -eq 0) { Ok "su installed online (uid=0 not echoed; will re-check)" }
else {
    No "online adb root did not confirm (rc=$($r4.Code)); trying OFFLINE debugfs fallback"
    Kill-Bst
    $r4b = Eng $commonEnv @('-Action', 'Root') 'Root (offline debugfs into Root.vhd)'
    if ($r4b.Code -eq 0) { Ok "OFFLINE root: su injected into Root.vhd" } else { No "offline root failed too" }
    # need the instance running for the rest
    Start-Process -FilePath $Player -ArgumentList @('--instance', $Instance) | Out-Null
}

$serial = "127.0.0.1:$adbPort"
function Wait-Boot([int]$sec) {
    Adb @('start-server') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        Adb @('connect', $serial) | Out-Null
        if ((Adb @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')).Trim() -match '1') { Start-Sleep 3; return $true }
        Start-Sleep 3
    }
    return $false
}
function Shot([string]$name) {
    $png = Join-Path $Shots $name
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Adb -s $serial exec-out screencap -p > $png } finally { $ErrorActionPreference = $old }
    if ((Test-Path $png) -and (Get-Item $png).Length -gt 1000) { Info "screenshot -> $png" } else { Info "screenshot failed ($name)" }
}

Step "3) verify root via adb"
if (-not (Wait-Boot $BootTimeout)) { No "instance not reachable"; }
$id = Adb @('-s', $serial, 'shell', '/system/xbin/su -c id 2>/dev/null || /system/bin/su -c id 2>/dev/null')
Write-Host "  su -c id => $($id.Trim())"
if ($id -match 'uid=0') { Ok "ROOT CONFIRMED: uid=0 from a normal adb shell" } else { No "uid=0 not returned (SELinux/su style?)" }
$ls = Adb @('-s', $serial, 'shell', 'ls -lZ /system/xbin/su /system/bin/su 2>/dev/null')
Write-Host "  su file: $($ls.Trim())"

if (-not $SkipMagisk -and $Magisk -and (Test-Path -LiteralPath $Magisk)) {
    Step "4) install Magisk + screenshot"
    Info "installing $Magisk"
    Write-Host (Adb @('-s', $serial, 'install', '-r', '-g', $Magisk)).Trim()
    $pkg = 'com.topjohnwu.magisk'
    Adb @('-s', $serial, 'shell', "monkey -p $pkg -c android.intent.category.LAUNCHER 1") | Out-Null
    Start-Sleep 8
    Shot 'magisk_before_reboot.png'
    $mv = Adb @('-s', $serial, 'shell', 'magisk -V 2>/dev/null; magisk -c 2>/dev/null')
    Write-Host "  magisk -V/-c => $($mv.Trim())"

    if (-not $Unattended) {
        Write-Host "`n  >>> NOW (in the emulator window): open Magisk -> Install -> Direct Install (to /system)." -ForegroundColor Yellow
        Write-Host "  >>> Wait for it to finish, then press ENTER here to reboot + verify." -ForegroundColor Yellow
        [void](Read-Host)
    }
    else { Write-Host "  [unattended] Magisk APK installed + screenshotted; skipping the GUI 'Direct Install' tap. Do it later, then reboot." -ForegroundColor Yellow }
}

Step "5) reboot + re-verify persistence"
Adb @('-s', $serial, 'reboot') | Out-Null
Start-Sleep 8
if (-not (Wait-Boot $BootTimeout)) { No "did not come back after reboot" }
else {
    $id2 = Adb @('-s', $serial, 'shell', '/system/xbin/su -c id 2>/dev/null || /system/bin/su -c id 2>/dev/null')
    Write-Host "  after reboot, su -c id => $($id2.Trim())"
    if ($id2 -match 'uid=0') { Ok "ROOT PERSISTS after reboot (uid=0)" } else { No "root did NOT persist after reboot" }
    $mv2 = Adb @('-s', $serial, 'shell', 'magisk -V 2>/dev/null; magisk -c 2>/dev/null')
    Write-Host "  after reboot, magisk -V/-c => $($mv2.Trim())"
    if ($mv2.Trim()) { Ok "Magisk reports a version after reboot (installed)" }
    if (-not $SkipMagisk) { $pkg = 'com.topjohnwu.magisk'; Adb @('-s', $serial, 'shell', "monkey -p $pkg -c android.intent.category.LAUNCHER 1") | Out-Null; Start-Sleep 8; Shot 'magisk_after_reboot.png' }
}

Write-Host "`n================ LIVE E2E SUMMARY ================" -ForegroundColor Cyan
$col = if ($fail) { 'Red' } else { 'Green' }
Write-Host ("  PASS=$pass  FAIL=$fail   screenshots in $Shots") -ForegroundColor $col
Write-Host "  When satisfied, undo with:  -Revert -Instance $Instance" -ForegroundColor DarkGray
exit ([int]($fail -gt 0))
