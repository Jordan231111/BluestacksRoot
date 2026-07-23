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
    [int]$RebootCycles = 1,
    [switch]$NoBackup,
    [switch]$VerifyOnly,
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

foreach ($f in @($Cmd, $Engine, $Magisk)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f" } }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { throw 'Run elevated (Administrator).' }

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "  [..] $m" -ForegroundColor DarkGray }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# isolate HD-Adb on its own server port (immune to a different-version system adb on 5037)
if (-not $env:ANDROID_ADB_SERVER_PORT) { $env:ANDROID_ADB_SERVER_PORT = '15037' }
function Adb([string[]]$a) { $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { (& $Adb @a 2>&1 | Out-String) } finally { $ErrorActionPreference = $o } }
function Run-PsFile([string[]]$a) { $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @a 2>&1 | Out-String } finally { $ErrorActionPreference = $o } }
function Output-Lines([string]$text){ @($text -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_}) }
function Adb-State([string]$target){
    $lines=Output-Lines (Adb @('-s',$target,'get-state'))
    @($lines | Where-Object {$_ -match '^(device|offline|unauthorized|unknown)$'} | Select-Object -Last 1)[0]
}
function Is-BootComplete([string]$text){ (Output-Lines $text) -contains '1' }
function Is-TransportError([string]$text){ $text -match "device '.*' not found|device .* not found|no devices/emulators found|device offline|error: closed" }

# Resolve every host path through the same marker-validated engine used by the shipped launcher.
$base = $Instance -replace '_\d+$', ''
$resolveArgs = @($Engine, '-Action', 'Resolve', '-Base', $base)
if($DataDir){$resolveArgs += @('-DataDir',$DataDir)}
if($InstallDir){$resolveArgs += @('-InstallDir',$InstallDir)}
$res = Run-PsFile $resolveArgs
$paths = @{}; foreach ($l in ($res -split "`r?`n")) { if ("$l" -match '^(BSR_\w+)=(.*)$') { $paths[$Matches[1]] = $Matches[2] } }
$InstallDir = $paths['BSR_INSTALL']
$DataDir = $paths['BSR_DATADIR']
$conf = $paths['BSR_CONF']
$vhd = $paths['BSR_VHD']
if (-not $InstallDir -or -not $DataDir -or -not $conf -or -not $vhd) { throw "validated path resolution failed: $res" }
if (-not $Adb) { $Adb = Join-Path $InstallDir 'HD-Adb.exe' }
if (-not $Player) { $Player = Join-Path $InstallDir 'HD-Player.exe' }
foreach ($f in @($Adb,$Player,$conf,$vhd)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing resolved BlueStacks file: $f" } }
function Get-ExactInstanceProcesses {
    # Recent BlueStacks builds hide HD-Player's WMI CommandLine/ExecutablePath. Player.log is stored
    # under the marker-validated DataDir and prefixes every exact-instance line with the host PID,
    # so use its newest line and then require that PID to still be an HD-Player process.
    $playerLog=Join-Path $DataDir 'Logs\Player.log'
    if(-not(Test-Path -LiteralPath $playerLog)){return @()}
    try{
        $text=(Get-Content -LiteralPath $playerLog -Tail 6000 -ErrorAction Stop) -join "`n"
        $rx='(?m)^\S+\s+\S+\s+(\d+)\s+\d+\s+\S+\s+'+[regex]::Escape($Instance)+'\s+\['
        $hits=[regex]::Matches($text,$rx)
        if(-not $hits.Count){return @()}
        $hostPid=[int]$hits[$hits.Count-1].Groups[1].Value
        $proc=Get-Process -Id $hostPid -ErrorAction SilentlyContinue
        if($proc -and $proc.Name -eq 'HD-Player'){
            return @([pscustomobject]@{ProcessId=$hostPid})
        }
    }catch{}
    @()
}
function Get-ExactInstanceAdbPorts {
    $ids=@(Get-ExactInstanceProcesses | Select-Object -ExpandProperty ProcessId)
    if(-not $ids){return @()}
    @(
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {$_.LocalPort -ge 5550 -and $_.LocalPort -le 5900 -and $ids -contains $_.OwningProcess} |
        Select-Object -ExpandProperty LocalPort -Unique
    )
}
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
    Adb @('kill-server') | Out-Null
    Start-Sleep 1
    Adb @('start-server') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        $exactIds=@(Get-ExactInstanceProcesses | Select-Object -ExpandProperty ProcessId)
        $livePorts=@(Get-ExactInstanceAdbPorts)
        if(-not $exactIds){Start-Sleep 2;continue}
        $cands = @($livePorts) + @($adbPort)
        foreach ($p in ($cands | Select-Object -Unique)) {
            $listener=@(Get-NetTCPConnection -State Listen -LocalPort ([int]$p) -ErrorAction SilentlyContinue |
                        Select-Object -First 1)
            if($listener -and $exactIds -notcontains $listener[0].OwningProcess){continue}
            $s = "127.0.0.1:$p"
            Adb @('connect', $s) | Out-Null
            $state=Adb-State $s
            if($state -ne 'device'){
                Adb @('disconnect',$s) | Out-Null
                Start-Sleep 1
                Adb @('connect',$s) | Out-Null
                Start-Sleep 1
                $state=Adb-State $s
            }
            if($state -eq 'device'){
                $boot=Adb @('-s',$s,'shell','getprop','sys.boot_completed')
                if(Is-BootComplete $boot){$script:serial=$s;Start-Sleep 3;return $true}
            }
        }
        Start-Sleep 3
    }
    return $false
}
function Restart-ExactInstance {
    Shell-Retry 'sync' | Out-Null
    $targets=@(Get-ExactInstanceProcesses)
    if(-not $targets){throw "exact HD-Player process for '$Instance' was not found"}
    $oldIds=@($targets | Select-Object -ExpandProperty ProcessId)
    foreach($target in $targets){
        Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
    }
    for($i=0;$i -lt 60 -and @(Get-ExactInstanceProcesses | Where-Object {$oldIds -contains $_.ProcessId}).Count;$i++){Start-Sleep -Milliseconds 500}
    if(@(Get-ExactInstanceProcesses | Where-Object {$oldIds -contains $_.ProcessId}).Count){throw "exact instance did not stop (PID $($oldIds -join ','))"}
    Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null
    $new=$null
    for($i=0;$i -lt 60;$i++){
        $new=@(Get-ExactInstanceProcesses | Where-Object {$oldIds -notcontains $_.ProcessId} | Select-Object -First 1)[0]
        if($new){break}
        Start-Sleep -Milliseconds 500
    }
    if(-not $new){throw "exact instance did not relaunch with a new process after stopping PID $($oldIds -join ',')"}
    Info "exact cold boot: PID $($oldIds -join ',') -> $($new.ProcessId)"
}
function Shell-Retry([string]$command,[int]$tries=5){
    $last=''
    for($i=0;$i -lt $tries;$i++){
        $last=Adb @('-s',$script:serial,'shell',$command)
        if(-not(Is-TransportError $last)){return $last}
        Adb @('disconnect',$script:serial)|Out-Null
        Start-Sleep 1
        Adb @('connect',$script:serial)|Out-Null
        Start-Sleep 2
    }
    $last
}
function Shot([string]$name) {
    $png = Join-Path $Shots $name; $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Adb -s $script:serial exec-out screencap -p > $png } finally { $ErrorActionPreference = $o }
    if ((Test-Path $png) -and (Get-Item $png).Length -gt 1000) { Info "shot -> $png" } else { Info "screenshot failed ($name)" }
}

# ---------------------------------------------------------------- REVERT (Magisk Undo)
if ($Revert) {
    Step "REVERT '$Instance' (Magisk Undo)"
    Run-PsFile @($Magisk, '-Action', 'Undo', '-Instance', $Instance, '-SelfCmd', $Cmd, '-Vhd', $vhd, '-Conf', $conf, '-Install', $InstallDir) | Write-Host
    Write-Host "`nReverted ($Instance). The shared master + HD-Player patch are left intact unless you passed -Full to Undo." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- ROOT via the SHIPPED Magisk pipeline
if(-not $VerifyOnly){
    Step "1) run the FULL Magisk pipeline (bsr_magisk.ps1 -Action Auto; embedded debugfs/su/APK)"
    $autoArgs=@($Magisk, '-Action', 'Auto', '-Instance', $Instance, '-SelfCmd', $Cmd, '-Engine', $Engine, '-Vhd', $vhd, '-Conf', $conf, '-Install', $InstallDir)
    if($NoBackup){$autoArgs += '-NoBackup'}
    $autoOut = Run-PsFile $autoArgs
    $autoRc = $LASTEXITCODE
    Write-Host $autoOut
    if ($autoRc -eq 0) { Ok "pipeline exited 0" } else { No "pipeline exit code = $autoRc" }
    if ($autoOut -match 'VERIFY PASS') { Ok "pipeline reached VERIFY PASS (Magisk sole root, no competing su, no bsr_su traces)" } else { No "pipeline did NOT print VERIFY PASS" }
    if ($autoOut -match 'competing su\s*:\s*none') { Ok "pipeline reported NO competing su" }
    elseif ($autoOut -match 'competing su\s*:\s*\S') { No "pipeline reported a COMPETING su (Abnormal-State regression)" }
}else{
    Step '1) verify-only stress run (the shipped launcher already completed Auto)'
    if(-not @(Get-ExactInstanceProcesses).Count){
        Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null
        Info "launched exact instance '$Instance' for verify-only stress"
    }
}

# ---------------------------------------------------------------- independent adb re-check
Step "2) independent verification over adb"
if (-not (Wait-Boot $BootTimeout)) { No "instance not reachable" }
$id = (Shell-Retry 'su -c id').Trim()
if ($id -match 'uid=0') { Ok "su -c id => $id" } else { No "uid=0 not returned ($id)" }
$binsu = (Shell-Retry 'readlink /system/bin/su').Trim()
if ($binsu -match 'magisk') { Ok "/system/bin/su -> $binsu" } else { No "/system/bin/su not -> magisk ($binsu)" }
$xbin = (Shell-Retry 'su -c "ls -l /system/xbin/su 2>&1"').Trim()
if ($xbin -match 'No such file|not found') { Ok "NO /system/xbin/su (competing su is gone)" } else { No "competing /system/xbin/su present: $xbin" }
$mv = (Shell-Retry 'su -c "magisk -c"').Trim()
if ($mv -match 'kitsune') { Ok "magisk -c => $mv" } else { No "magisk version unexpected ($mv)" }
$pkg = (Shell-Retry "pm path $PKG").Trim()
if ($pkg -match 'package:') { Ok "manager installed: $pkg" } else { Info "manager package not found via pm path ($pkg)" }
Shot 'magisk_e2e.png'

# ---------------------------------------------------------------- cold-boot persistence
for($cycle=1;$cycle -le $RebootCycles;$cycle++){
    Step "3.$cycle) exact-instance cold boot + re-assert (persistence cycle $cycle/$RebootCycles)"
    Restart-ExactInstance
    if (-not (Wait-Boot $BootTimeout)) { No "did not come back after cold-boot cycle $cycle"; continue }
    $id2 = (Shell-Retry 'su -c id').Trim()
    if ($id2 -match 'uid=0') { Ok "root PERSISTS after cold-boot cycle $cycle (uid=0)" } else { No "root lost after cold-boot cycle $cycle ($id2)" }
    $xbin2 = (Shell-Retry 'su -c "ls -l /system/xbin/su 2>&1"').Trim()
    if ($xbin2 -match 'No such file|not found') { Ok "still NO competing /system/xbin/su after cold-boot cycle $cycle" } else { No "competing su reappeared: $xbin2" }
    $trace=(Shell-Retry "su -c `"find /system /data/adb /data/downloads -type f -size 4968c 2>/dev/null | while read f; do [ \`"`$(sha256sum `$f|cut -d' ' -f1)\`" = '7eb6380ee26ce0b68d9f3f23ac04f50e0dfdd49359ef17d1a4978be1795913dd' ] && echo TRACE:`$f; done`"").Trim()
    if(-not $trace){Ok "no bootstrap-su hash trace after cold-boot cycle $cycle"}else{No "bootstrap-su trace after cold-boot cycle $cycle`: $trace"}
    Shot "magisk_e2e_after_cold_boot_$cycle.png"
}

Write-Host "`n================ LIVE E2E SUMMARY ================" -ForegroundColor Cyan
Write-Host ("  PASS=$pass  FAIL=$fail   screenshots in $Shots") -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host "  Undo with:  -Revert -Instance $Instance" -ForegroundColor DarkGray
exit ([int]($fail -gt 0))
