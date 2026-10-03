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
    ... -Instance Tiramisu64_9 -SimulateLostPopulateReply  # replay real population after a discarded reply
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
    [switch]$CheckFailurePaths,
    [switch]$SimulateLostPopulateReply,
    [switch]$Revert
)
$ErrorActionPreference = 'Stop'
if($SimulateLostPopulateReply -and ($VerifyOnly -or $Revert)){throw '-SimulateLostPopulateReply requires the full Auto pipeline.'}
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $Cmd) { $Cmd = Join-Path $repo 'blueStackRoot.cmd' }
. (Join-Path $repo 'tools\bsr_build.ps1')
if (-not $Shots) { $Shots = Join-Path $here 'live-shots' }
if (-not (Test-Path $Shots)) { New-Item -ItemType Directory -Path $Shots -Force | Out-Null }
# Exercise the embedded distribution without access to tools/debugfs or su_src.
$pipeline=Join-Path $Shots 'pipeline'
[void][IO.Directory]::CreateDirectory($pipeline)
$cmdBytes=[IO.File]::ReadAllBytes($Cmd)
foreach($tag in @('ENGINE','MAGISK')){
    $source=Get-BsrEmbeddedText $cmdBytes $tag
    Assert-BsrScript $source $tag
    if($tag -eq 'MAGISK' -and $SimulateLostPopulateReply){
        # Exercise a real guest-side replay: execute the first population script
        # completely, discard ONLY its reply, then let the normal retry recover.
        # This option changes the extracted test copy, never the distribution.
        $anchor='(?m)^    \$script:LastAdbExitCode = \$result.ExitCode\r?\n    \$result.Output\r?$'
        if([regex]::Matches($source,$anchor).Count -ne 1){throw 'Cannot install the lost-reply test hook in the extracted ADB helper.'}
        $replacement=@'
    $script:LastAdbExitCode = $result.ExitCode
    if(-not $script:LostPopulateReply -and $a[-1] -match 'sh /data/local/tmp/bsr_pop.sh' -and $result.Output -match '(?m)^BSR_DATA_OK\r?$'){
        $script:LostPopulateReply=$true
        Write-Host 'BSR_TEST_LOST_POPULATE_REPLY'
        return ''
    }
    $result.Output
'@
        $source=[regex]::Replace($source,$anchor,[Text.RegularExpressions.MatchEvaluator]{param($match) $replacement})
        Assert-BsrScript $source 'lost-reply test copy'
    }
    [IO.File]::WriteAllText((Join-Path $pipeline ($tag+'.ps1')),$source,(New-Object Text.UTF8Encoding($true)))
}
if(-not $Engine){$Engine=Join-Path $pipeline 'ENGINE.ps1'}
$Magisk=Join-Path $pipeline 'MAGISK.ps1'
$PKG = 'io.github.huskydg.magisk'   # the bundled Kitsune Mask package (NOT com.topjohnwu.magisk)

foreach ($f in @($Cmd, $Engine, $Magisk)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f" } }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { throw 'Run elevated (Administrator).' }

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "  [..] $m" -ForegroundColor DarkGray }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# isolate HD-Adb on its own server port (immune to a different-version system adb on 5037)
function Adb([string[]]$a) {
    $result=Invoke-BsrNative $Adb $a 60
    $script:LastAdbExitCode=$result.ExitCode
    $result.Output
}
function Run-PsFile([string[]]$a) {
    $result=Invoke-BsrNative 'powershell.exe' (@('-NoProfile','-ExecutionPolicy','Bypass','-File')+$a) 1800
    $script:LASTEXITCODE=$result.ExitCode
    $result.Output
}
function Output-Lines([string]$text){ @($text -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_}) }
function Adb-State([string]$target){
    $lines=Output-Lines (Adb @('-s',$target,'get-state'))
    @($lines | Where-Object {$_ -match '^(device|offline|unauthorized|unknown)$'} | Select-Object -Last 1)[0]
}
function Is-BootComplete([string]$text){ (Output-Lines $text) -contains '1' }
function Is-TransportError([string]$text){ $text -match "device '.*' not found|device .* not found|no devices/emulators found|device offline|error: closed|protocol fault|connection reset|broken pipe|cannot connect to daemon" }

# Resolve every host path through the same marker-validated engine used by the shipped launcher.
$base = $Instance -replace '_\d+$', ''
$resolveArgs = @($Engine, '-Action', 'Resolve', '-SelfPath', $Cmd, '-Base', $base, '-Instance', $Instance)
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
$env:ANDROID_ADB_SERVER_PORT=Select-BsrAdbServerPort (Get-BsrAdbServerPortState $Adb)
function Get-ExactInstanceProcesses {
    $playerLog=Join-Path $DataDir 'Logs\Player.log'
    Get-BsrInstanceProcesses $Instance $playerLog | ForEach-Object {[pscustomobject]@{ProcessId=$_.Id}}
}
function Get-ExactInstanceAdbPorts {
    $ids=@(Get-ExactInstanceProcesses | Select-Object -ExpandProperty ProcessId)
    if(-not $ids){return @()}
    @(
        Get-BsrTcpListeners |
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
    Stop-BsrAdbServer $Adb
    Start-Sleep 1
    Adb @('start-server') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        $exactIds=@(Get-ExactInstanceProcesses | Select-Object -ExpandProperty ProcessId)
        $livePorts=@(Get-ExactInstanceAdbPorts)
        if(-not $exactIds){Start-Sleep 2;continue}
        $cands = @($livePorts)
        foreach ($p in ($cands | Select-Object -Unique)) {
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
                $boot=Adb @('-s',$s,'exec-out','getprop','sys.boot_completed')
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
    . (Join-Path $repo 'tools\bsr_host.ps1')
    Start-BsrPlayer $Player $Instance | Out-Null
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
        $last=Adb @('-s',$script:serial,'exec-out',($command+"`necho BSR_SHELL_DONE"))
        if(-not(Is-TransportError $last) -and $last -match '(?m)^BSR_SHELL_DONE\r?$'){
            return ($last -replace '(?m)^BSR_SHELL_DONE\r?\n?','').TrimEnd("`r","`n")
        }
        Adb @('disconnect',$script:serial)|Out-Null
        Start-Sleep 1
        Adb @('connect',$script:serial)|Out-Null
        Start-Sleep 2
    }
    throw "ADB shell did not complete after $tries attempts: $last"
}
function Shot([string]$name) {
    $launch=Shell-Retry "monkey -p $PKG -c android.intent.category.LAUNCHER 1"
    if($launch -notmatch 'Events injected: 1'){throw "Magisk manager did not launch: $launch"}
    Start-Sleep -Seconds 10
    # Windows PowerShell's > operator converts native binary stdout into UTF-16.
    # Copy the pipe's bytes directly, and verify the PNG signature before claiming success.
    $png = Join-Path $Shots $name
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Adb; $psi.Arguments='-s '+$script:serial+' exec-out screencap -p'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $failure=''
    for($attempt=0;$attempt -lt 4;$attempt++){
        $process=[Diagnostics.Process]::Start($psi)
        $file=[IO.File]::Create($png)
        try {
            $copy=$process.StandardOutput.BaseStream.CopyToAsync($file)
            $errors=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(15000)){$process.Kill();throw 'ADB screenshot timed out.'}
            $null=$copy.GetAwaiter().GetResult(); $errorText=$errors.GetAwaiter().GetResult()
            if($process.ExitCode -ne 0){throw "ADB screenshot failed: $errorText"}
            $failure=''
        }catch{$failure=$_.Exception.Message}
        finally {$file.Dispose();$process.Dispose()}
        $bytes=[IO.File]::ReadAllBytes($png)
        if(-not $failure -and $bytes.Length -ge 8 -and [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A'){
            Info "shot -> $png";return
        }
        Adb @('disconnect',$script:serial)|Out-Null
        Start-Sleep 1
        Adb @('connect',$script:serial)|Out-Null
    }
    throw "Could not capture a valid PNG screenshot after four attempts: $failure"
}

try {
# ---------------------------------------------------------------- REVERT (Magisk Undo)
if ($Revert) {
    Step "REVERT '$Instance' (Magisk Undo)"
    Run-PsFile @($Magisk, '-Action', 'Undo', '-Instance', $Instance, '-SelfCmd', $Cmd, '-Engine', $Engine, '-Vhd', $vhd, '-Conf', $conf, '-Install', $InstallDir) | Write-Host
    if($LASTEXITCODE){throw "Undo exited $LASTEXITCODE"}
    Start-BsrPlayer $Player $Instance | Out-Null
    if(-not (Wait-Boot $BootTimeout)){throw 'Unrooted instance failed to reboot.'}
    $unroot=Shell-Retry 'id; su -c id; echo BSR_UNROOT_CHECK'
    if($unroot -notmatch '(?m)^BSR_UNROOT_CHECK\s*$' -or $unroot -match 'uid=0' -or $unroot -notmatch 'uid=2000'){
        throw "Unroot verification failed: $unroot"
    }
    $package=Shell-Retry ("pm path $PKG; echo BSR_PACKAGE_CHECK")
    if($package -match 'package:' -or $package -notmatch '(?m)^BSR_PACKAGE_CHECK\s*$'){throw "Manager uninstall verification failed: $package"}
    Ok 'unroot survives a cold boot; shell has no root and Magisk manager is absent'
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
    if ($autoRc -eq 0) { Ok "pipeline exited 0" } else { throw "Pipeline exited $autoRc. Inspect its failure before continuing live checks." }
    if($SimulateLostPopulateReply){
        if($autoOut -match 'BSR_TEST_LOST_POPULATE_REPLY'){Ok 'population recovers after executing successfully and losing its reply'}
        else{No 'lost population reply was not exercised'}
    }
    if ($autoOut -match 'VERIFY PASS') { Ok "pipeline reached VERIFY PASS (Magisk sole root, no competing su, no bsr_su traces)" } else { No "pipeline did NOT print VERIFY PASS" }
    if ($autoOut -match 'competing su\s*:\s*none') { Ok "pipeline reported NO competing su" }
    elseif ($autoOut -match 'competing su\s*:\s*\S') { No "pipeline reported a COMPETING su (Abnormal-State regression)" }
}else{
    Step '1) verify-only stress run (the shipped launcher already completed Auto)'
    if(-not @(Get-ExactInstanceProcesses).Count){
        . (Join-Path $repo 'tools\bsr_host.ps1')
        Start-BsrPlayer $Player $Instance | Out-Null
        Info "launched exact instance '$Instance' for verify-only stress"
    }
}

# ---------------------------------------------------------------- independent adb re-check
Step "2) independent verification over adb"
if (-not (Wait-Boot $BootTimeout)) { throw "Exact instance '$Instance' is not reachable." }
$id = (Shell-Retry 'su -c id').Trim()
if ($id -match 'uid=0') { Ok "su -c id => $id" } else { No "uid=0 not returned ($id)" }
$binsu = (Shell-Retry 'readlink /system/bin/su').Trim()
if ($binsu -match 'magisk') { Ok "/system/bin/su -> $binsu" } else { No "/system/bin/su not -> magisk ($binsu)" }
$xbin = (Shell-Retry 'su -c "ls -l /system/xbin/su 2>&1"').Trim()
if ($xbin -match 'No such file|not found') { Ok "NO /system/xbin/su (competing su is gone)" } else { No "competing /system/xbin/su present: $xbin" }
$mv = (Shell-Retry 'su -c "magisk -c"').Trim()
if ($mv -match 'kitsune') { Ok "magisk -c => $mv" } else { No "magisk version unexpected ($mv)" }
$packagePath = (Shell-Retry "pm path $PKG").Trim()
if ($packagePath -match 'package:') { Ok "manager installed: $packagePath" } else { No "manager package not found via pm path ($packagePath)" }
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
    $scan='BB=/data/adb/magisk/busybox; [ -x "$BB" ] || exit 1; set -- /system /data/adb; [ ! -d /data/downloads ] || set -- "$@" /data/downloads; files=$("$BB" find "$@" -type f -size 4968c) || exit 1; printf "%s\n" "$files" | while IFS= read -r f; do [ -n "$f" ] || continue; h=$("$BB" sha256sum "$f") || exit 1; case "$h" in 7eb6380ee26ce0b68d9f3f23ac04f50e0dfdd49359ef17d1a4978be1795913dd*) echo "TRACE:$f";; esac; done || exit 1; echo BSR_SCAN_DONE'
    $trace=(Shell-Retry ("su -c '"+$scan+"'")).Trim()
    if($trace -match '(?m)^BSR_SCAN_DONE\s*$' -and $trace -notmatch 'TRACE:'){Ok "no bootstrap-su hash trace after cold-boot cycle $cycle"}else{No "bootstrap-su scan failed after cold-boot cycle $cycle`: $trace"}
    Shot "magisk_e2e_after_cold_boot_$cycle.png"
}

if(-not $VerifyOnly -or $CheckFailurePaths){
    Step '4) verification must reject a known bootstrap hash, then recover after cleanup'
    $probeName='bsr_validation_'+[guid]::NewGuid().ToString('N')
    $localProbe=Join-Path $pipeline $probeName
    $guestUpload='/data/local/tmp/'+$probeName
    $guestProbe='/data/adb/'+$probeName
    [IO.File]::WriteAllBytes($localProbe,(Expand-BsrGzip ([Convert]::FromBase64String((Get-BsrEmbeddedText $cmdBytes 'BSRSU')))))
    $verifyArgs=@($Magisk,'-Action','Verify','-Instance',$Instance,'-SelfCmd',$Cmd,'-Engine',$Engine,'-Vhd',$vhd,'-Conf',$conf,'-Install',$InstallDir)
    try{
        Adb @('-s',$script:serial,'push',$localProbe,$guestUpload) | Out-Null
        $placed=Shell-Retry ("su -c 'cp $guestUpload $guestProbe && chmod 600 $guestProbe && echo BSR_PROBE_READY'")
        if($placed -notmatch 'BSR_PROBE_READY'){throw "Could not stage the non-executable verification fixture: $placed"}
        $negative=Run-PsFile $verifyArgs
        if($LASTEXITCODE -ne 0 -and $negative -match 'VERIFY FAIL' -and $negative.Contains('TRACE:'+$guestProbe)){
            Ok 'real verification detects the bootstrap hash and exits nonzero'
        }else{No "verification accepted or failed to inspect the known bootstrap hash: $negative"}
    }finally{
        if(-not(Wait-Boot $BootTimeout)){throw 'Cannot reconnect to remove the verification fixture.'}
        $removed=Shell-Retry ("su -c 'rm -f $guestProbe $guestUpload; test ! -e $guestProbe && echo BSR_PROBE_REMOVED'")
        if($removed -notmatch 'BSR_PROBE_REMOVED'){throw "Could not confirm verification fixture cleanup: $removed"}
        Remove-Item -LiteralPath $localProbe -Force -ErrorAction SilentlyContinue
    }
    $positive=Run-PsFile $verifyArgs
    if($LASTEXITCODE -eq 0 -and $positive -match 'VERIFY PASS'){Ok 'real verification passes again after removing the fixture'}
    else{No "verification did not recover after cleanup: $positive"}
}

Write-Host "`n================ LIVE E2E SUMMARY ================" -ForegroundColor Cyan
Write-Host ("  PASS=$pass  FAIL=$fail   screenshots in $Shots") -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host "  Undo with:  -Revert -Instance $Instance" -ForegroundColor DarkGray
exit ([int]($fail -gt 0))
} finally {
    # Our private ADB server can inherit the caller's redirected log handle.
    # Release it on both success and failure so CI/terminal capture can finish.
    try { Stop-BsrAdbServer $Adb } catch { Write-Warning $_.Exception.Message }
}
