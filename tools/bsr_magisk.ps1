<#  bsr_magisk.ps1  --  Make Magisk the SOLE, self-sustaining root on BlueStacks 5 (rvc/Android 11),
    with no traces of any bootstrap su.  Minimal read/writes.  Built from the proven workflow in
    docs/BLUESTACKS_ROOTING_DEEP_DIVE.md (sect. 6).

    Pipeline (no DiskRW; Root.vhd edited offline at file level; only /data written at runtime):
      Prep      [offline] HD-Player anti-tamper patch (via bsr_engine.ps1) + conf enable_root_access=1
                          + ONE Root.vhd carve writing: Magisk /system files + hijacked bootanim.rc
                          + bootstrap su (bsr_su) + hijacked bindmount.
      Data      [online ] boot, adb install Magisk APK, then via bootstrap su populate /data/adb/magisk
                          (busybox + ABI binaries + scripts) and set the grant policy.
      Clean     [offline] remove bsr_su + restore the stock bindmount.
      Finalize  [conf   ] enable_root_access=0  ("turn off emulator root").
      Verify    [online ] cold boot; confirm Magisk-only root, no traces.
      Auto                Prep -> boot -> Data -> Clean -> Finalize -> Verify (the whole thing).

    Inputs:  -MagiskApk <path to Magisk-*.apk>  (manager app + every Magisk binary; the one external file)
             -Vhd <Root.vhd>  -Conf <bluestacks.conf>  -Instance <name>  -Install <BlueStacks install dir>
#>
[CmdletBinding()]
param(
    [ValidateSet('Prep','Data','Clean','Finalize','Verify','Auto','Undo')]
    [string]$Action = 'Auto',
    [string]$Vhd,
    [string]$Conf,
    [string]$Instance = 'Rvc64',
    [string]$Install,                         # BlueStacks install dir; resolved from the registry if omitted
    [string]$MagiskApk,
    [string]$Engine,                          # bsr_engine.ps1 (for the HD-Player patch); auto-detected if omitted
    [string]$Debugfs,                         # debugfs.exe; auto-detected if omitted
    [string]$BsrSuPath,                       # bootstrap su binary; auto-detected if omitted
    [string]$SelfCmd,                         # path to blueStackRoot.cmd (embedded mode: self-extract debugfs + bsr_su)
    [switch]$NoBackup,
    [switch]$Full                             # Undo: also scrub the shared master + un-patch HD-Player (unroots ALL instances)
)
if(-not $NoBackup -and $env:BSR_NOBACKUP -eq '1'){ $NoBackup=$true }
# Native commands capture stderr explicitly; all PowerShell I/O errors must terminate.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$script:WorkDir = Join-Path (Join-Path $env:TEMP 'bsr_work') ('session_' + [guid]::NewGuid().ToString('N'))
$Self = $MyInvocation.MyCommand.Path
$Here = Split-Path -Parent $Self

# --------- the bsr_su grant policy / known signatures ----------
$BSR_SU_SHA = '7eb6380ee26ce0b68d9f3f23ac04f50e0dfdd49359ef17d1a4978be1795913dd'

# ---- embedded-payload self-extraction (only used when -SelfCmd <blueStackRoot.cmd> is given) ----
# Extract-Block is called up to 3x per run (DFS + BSRSU + APK payloads), each scanning the large
# (~21 MB) self .cmd. Read it once and cache by path so it is read once, not three times.
# $script:SelfReadCount is a test seam (asserted by Run-Magisk-Unit-Tests.ps1).
$script:SelfCmdTextCache = @{}
$script:SelfReadCount = 0
function Get-SelfText($path){
    if(-not $path){ return $null }
    if($script:SelfCmdTextCache.ContainsKey($path)){ return $script:SelfCmdTextCache[$path] }
    $script:SelfReadCount++
    $t=[System.IO.File]::ReadAllText($path)
    $script:SelfCmdTextCache[$path]=$t
    return $t
}
function Extract-Block($cmdPath,$begTok,$endTok){
    $t=Get-SelfText $cmdPath
    $b="__BSR_${begTok}_"+"BEGIN__"; $e="__BSR_${endTok}_"+"END__"
    $i=$t.IndexOf($b); $j=$t.IndexOf($e)
    if($i -lt 0 -or $j -le $i){ return $null }
    $i=$t.IndexOf([char]10,$i)+1
    $t.Substring($i,$j-$i)
}

# The same host helpers are used by the engine and diagnostic launcher. In the
# distributed .cmd they are loaded in memory from the embedded HOST block.
if ($SelfCmd) {
    $hostCode = Extract-Block $SelfCmd 'HOST' 'HOST'
    if (-not $hostCode) { throw 'Embedded HOST helpers are missing; re-download the complete blueStackRoot.cmd.' }
    . ([scriptblock]::Create($hostCode))
} else {
    . (Join-Path $Here 'bsr_host.ps1')
}

function Say($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function DfsPath($p){ ConvertTo-BsrDebugfsPath $p }
function Fwd($p){ $p -replace '\\','/' }

# --------- normalize incoming paths (callers may pass a trailing '\' or a stray '"') ----------
# A registry InstallDir ending in '\' can become a quoted command-line value ending in '\"';
# PowerShell -File can then deliver a stray trailing quote. Strip quotes/slashes/spaces so
# Join-Path receives a clean, registry-derived value.
function Clean-Path($p){ if($null -eq $p){return $p}; ($p -replace '"','').Trim().TrimEnd('\') }
$Install = Clean-Path $Install
$Engine  = Clean-Path $Engine
$Debugfs = Clean-Path $Debugfs
$Vhd     = Clean-Path $Vhd
$Conf    = Clean-Path $Conf
$SelfCmd = Clean-Path $SelfCmd

# --------- validated discovery (NO hardcoded filesystem locations) ----------
function Get-DataRoot($reg){
    $d=if($reg){if($reg.DataDir){$reg.DataDir}elseif($reg.UserDefinedDir){$reg.UserDefinedDir}else{$null}}else{$null}
    if(-not $d){return $null}
    if($d -match '(?i)[\\/]engine[\\/]?$'){$d=$d -replace '(?i)[\\/]engine[\\/]?$',''}
    $d.TrimEnd('\','/')
}
# Keep the public test/developer helper names while using one discovery implementation.
function Get-InstallRoot([string]$value){ Get-InstallRootFromPath $value }
function Same-Path([string]$a,[string]$b){ Test-SamePath $a $b }

function Resolve-InstallRoot([string]$preferred,$records,[string]$dataRoot){
    foreach($record in @($records)){
        $rd=Get-RecordDataRoot $record; $ri=Get-InstallRoot $record.InstallDir
        if($ri -and $rd -and (Same-Path $rd $dataRoot)){return $ri}
    }
    $p=Get-InstallRoot $preferred;if($p){return $p}
    $valid=New-Object System.Collections.Generic.List[string]
    foreach($r in @(Get-RuntimeInstallRoots)){if($r-and-not($valid-contains$r)){[void]$valid.Add($r)}}
    foreach($record in @($records)){$p=Get-InstallRoot $record.InstallDir;if($p-and-not($valid-contains$p)){[void]$valid.Add($p)}}
    if($valid.Count-eq1){return $valid[0]}
    if($valid.Count-gt1){throw "Multiple marker-valid BlueStacks installations were found and none matches the selected data folder. Use option 8 to select the intended install folder."}
    $null
}

$regRecords=@(Get-RegBlueStacksRecords)
$reg=if($regRecords.Count){$regRecords[0]}else{$null}
$DataRoot=if($Conf -and (Test-Path -LiteralPath $Conf)){Split-Path -Parent $Conf}else{Get-RecordDataRoot $reg}
$Install=Resolve-InstallRoot $Install $regRecords $DataRoot
if (-not $Engine)  { $Engine  = Join-Path $Here 'bsr_engine.ps1' }
if (-not $Debugfs) {
    foreach($c in @((Join-Path $Here 'debugfs\debugfs.exe'), (Join-Path $script:WorkDir 'debugfs\debugfs.exe'))){ if(Test-Path -LiteralPath $c){ $Debugfs=$c; break } }
}
if (-not $Conf -and $DataRoot)    { $Conf = Join-Path $DataRoot 'bluestacks.conf' }
if (-not $Vhd -and $Instance -and $DataRoot) { $Vhd = Join-Path $DataRoot "Engine\$Instance\Root.vhd" }
$PlayerLog = if($DataRoot){Join-Path $DataRoot 'Logs\Player.log'}else{$null}   # host-side boot-phase log
# Resolve BlueStacks' OWN adb (HD-Adb.exe). We deliberately do NOT fall back to a system adb.exe:
# mixing a system adb (e.g. Android SDK platform-tools v1.0.41) with BlueStacks' HD-Adb (v1.0.36)
# triggers the "adb server version doesn't match this client; killing..." war -- the two kill each
# other's server, getprop/shell calls fail intermittently, and a fully-booted instance can still
# fail Boot-And-Wait with "did not become adb-reachable". So we pin HD-Adb.exe specifically.
function Resolve-HdAdb {
    if($Install){
        $p=Join-Path $Install 'HD-Adb.exe'
        if(Test-Path -LiteralPath $p){return (Resolve-Path -LiteralPath $p).Path}
    }
    $g = Get-Command 'HD-Adb.exe' -ErrorAction SilentlyContinue; if($g){ return $g.Source }
    return $null
}
$Adb    = Resolve-HdAdb
$Player = if($Install){Join-Path $Install 'HD-Player.exe'}else{$null}
$BsrSu  = if($BsrSuPath){$BsrSuPath}else{ Join-Path $Here 'su_src\bsr_su' }   # the setuid bootstrap su (4968 B)

function Assert-BlueStacksHostTools{
    if(-not $Install){throw "BlueStacks install folder could not be resolved from validated registry/process/service/PATH evidence. Use menu option 8 to select the folder containing HD-Player.exe and HD-Adb.exe."}
    if(-not(Test-Path -LiteralPath $Player)){throw "HD-Player.exe not found in the resolved install folder: $Install"}
    if(-not($Adb -and (Test-Path -LiteralPath $Adb))){throw "HD-Adb.exe not found in the resolved install folder: $Install"}
}

# ---- payload integrity: turn a cryptic base64/gzip crash into an actionable message (issue #24) ----
# The embedded blocks (APK, debugfs zip, bootstrap-su gzip) are exactly the bytes antivirus loves to
# strip from this .cmd -- a real Magisk APK + a setuid 'su' ELF read as HackTool/PUA. When Defender
# removes part of the file (or a download is cut short) FromBase64String / GZipStream throw an opaque
# .NET error. Get-BlockBytes validates structure first and, on any problem, throws a message that tells
# the user what to actually do instead of surfacing a raw exception.
# Name the antivirus actually installed (root/SecurityCenter2) so the guidance can be vendor-specific.
# Only Defender can be excluded from code; for anything else the user must add the exclusion by hand, so
# telling them WHICH product is running is the honest, useful help. Best-effort: empty string on any error.
function Get-AvHint {
    try {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
                ForEach-Object { $_.displayName } | Where-Object { $_ } | Select-Object -Unique)
        if($av.Count){ return " Antivirus detected: $($av -join ', '). Windows Defender exclusions are added for you; any THIRD-PARTY antivirus you must exclude yourself -- add this folder and %TEMP%\bsr_work to its exclusions." }
    } catch {}
    return ''
}
function Fail-Damaged($what){
    throw ("embedded $what payload is damaged or incomplete -- antivirus most likely removed part of this " +
           "file, or the download was interrupted." + (Get-AvHint) + " Fix: add a folder exclusion for this " +
           "directory, then RE-DOWNLOAD blueStackRoot.cmd from the GitHub Releases page into the SAME folder " +
           "and run it again.")
}
# After a payload is written to %TEMP%\bsr_work, confirm AV didn't quarantine/alter it in the moment between
# write and use (real Magisk APK / setuid su are prime targets even with a path exclusion, if the verdict is
# cloud/behavioural rather than path-based).
function Assert-Extracted($path,$expectedLen,$what){
    if(-not (Test-Path -LiteralPath $path)){
        throw ("the extracted $what was deleted right after it was written -- antivirus quarantined it." + (Get-AvHint) + " Add the exclusions above and run again.")
    }
    if($expectedLen -and ((Get-Item -LiteralPath $path).Length -ne $expectedLen)){
        throw ("the extracted $what changed size after it was written -- antivirus altered/quarantined it." + (Get-AvHint) + " Add the exclusions above and run again.")
    }
}
function Get-BlockBytes($tok){
    if(-not ($SelfCmd -and (Test-Path -LiteralPath $SelfCmd))){ throw "no -SelfCmd path: cannot read the embedded $tok payload." }
    $b64 = Extract-Block $SelfCmd $tok $tok
    if($null -eq $b64){ Fail-Damaged $tok }                                    # BEGIN/END marker gone -> truncated
    $b64 = ($b64 -replace '\s','')
    if($b64.Length -lt 16 -or ($b64.Length % 4) -ne 0){ Fail-Damaged $tok }    # not a valid base64 length
    try { return ,([Convert]::FromBase64String($b64)) } catch { Fail-Damaged $tok }
}
function Ensure-Debugfs {
    if($script:Debugfs -and (Test-Path -LiteralPath $script:Debugfs)){ return }
    foreach($c in @((Join-Path $Here 'debugfs\debugfs.exe'), (Join-Path $script:WorkDir 'debugfs\debugfs.exe'))){ if(Test-Path -LiteralPath $c){ $script:Debugfs=$c; return } }
    if($SelfCmd -and (Test-Path -LiteralPath $SelfCmd)){
        $zipBytes=Get-BlockBytes 'DFS'
        if((Get-BsrBytesHash $zipBytes) -ne '008b6006e766d2591c8c7db7bf6d6a0a4b9cd6116b9a8e2737151828eb577632'){ Fail-Damaged 'DFS' }
        $d=Join-Path $script:WorkDir 'debugfs'
        [void][IO.Directory]::CreateDirectory($d)
        $zip=Join-Path $d '_d.zip'
        [IO.File]::WriteAllBytes($zip,$zipBytes)
        try { Expand-BsrZip $zip $d } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        $exe=Join-Path $d 'debugfs.exe'; Assert-Extracted $exe $null 'debugfs.exe'; $script:Debugfs=$exe

    }
    if(-not ($script:Debugfs -and (Test-Path -LiteralPath $script:Debugfs))){ throw "debugfs.exe not found (pass -Debugfs or -SelfCmd)." }
}
function Ensure-BsrSu {
    if($script:BsrSu -and (Test-Path -LiteralPath $script:BsrSu)){ return }
    if($SelfCmd -and (Test-Path -LiteralPath $SelfCmd)){
        $gz=Get-BlockBytes 'BSRSU'
        if($gz.Length -lt 2 -or $gz[0] -ne 0x1F -or $gz[1] -ne 0x8B){ Fail-Damaged 'BSRSU' }   # gzip magic 1F 8B
        try{ $su=Expand-BsrGzip $gz }catch{ Fail-Damaged 'BSRSU' }
        $sha=Get-BsrBytesHash $su
        if($sha -ne $BSR_SU_SHA){ Fail-Damaged 'BSRSU' }                                       # decoded su must match the known-good hash
        $d=$script:WorkDir; New-Item -ItemType Directory -Path $d -Force | Out-Null; $p=Join-Path $d 'bsr_su'; [System.IO.File]::WriteAllBytes($p,$su); Assert-Extracted $p $su.Length 'bootstrap su'; $script:BsrSu=$p
    }
    if(-not ($script:BsrSu -and (Test-Path -LiteralPath $script:BsrSu))){ throw "bootstrap su (bsr_su) not found (pass -BsrSuPath or -SelfCmd)." }
}
function Ensure-MagiskApk {
    if($script:MagiskApk -and (Test-Path -LiteralPath $script:MagiskApk)){ return }
    # an external APK next to the .cmd already resolved by the caller; otherwise extract the EMBEDDED one
    if($SelfCmd -and (Test-Path -LiteralPath $SelfCmd)){
        $apkBytes=Get-BlockBytes 'APK'
        if((Get-BsrBytesHash $apkBytes) -ne 'fac319d2de262fcfff1684e13e1a5c61c486d2a773a7a8ffcfdbfe6f763a7fd4'){ Fail-Damaged 'APK' }
        $d=$script:WorkDir; New-Item -ItemType Directory -Path $d -Force | Out-Null; $p=Join-Path $d 'magisk.apk'; [System.IO.File]::WriteAllBytes($p,$apkBytes); Assert-Extracted $p $apkBytes.Length 'Magisk APK'; $script:MagiskApk=$p; Say "[*] using embedded Magisk APK ($([Math]::Round((Get-Item -LiteralPath $p).Length/1MB,1)) MB)." DarkGray
    }
    if(-not ($script:MagiskApk -and (Test-Path -LiteralPath $script:MagiskApk))){ throw "Magisk APK not found (pass -MagiskApk or -SelfCmd with an embedded APK)." }
}

# ====================================================================
#  Embedded text templates (LF; written verbatim into ext4 / used at runtime)
# ====================================================================
# GATED bootanim.rc: the shared master Root.vhd is used by ALL instances, so Magisk's boot hooks
# must be PER-INSTANCE. Each stage execs bsr_boot.sh, which no-ops unless THIS instance carries
# /data/adb/.bsr_root (its own /data). Unrooted instances -> no magiskd, no su, no app, no leak.
$BOOTANIM_RC = @'
service bootanim /system/bin/bootanimation
    class core animation
    user graphics
    group graphics audio
    disabled
    oneshot
    ioprio rt 0
    task_profiles MaxPerformance
on post-fs-data
    start logd
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh post-fs-data
on nonencrypted
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh service
on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh service
on property:sys.boot_completed=1
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh boot-complete
on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh zygote-restart
on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh zygote-restart
'@ -replace "`r`n","`n"

# Per-instance Magisk gate. SELinux is disabled on BlueStacks so one context (root) suffices.
$BSR_BOOT_SH = @'
#!/system/bin/sh
# BSR per-instance Magisk gate. Activates Magisk ONLY if THIS instance (its own /data) is flagged.
[ -f /data/adb/.bsr_root ] || exit 0
M=/system/etc/init/magisk
case "$1" in
  post-fs-data)
    "$M/magiskpolicy" --live --magisk 2>/dev/null
    "$M/magisk64" --auto-selinux --setup-sbin "$M" /sbin 2>/dev/null
    /sbin/magisk --auto-selinux --post-fs-data 2>/dev/null
    ;;
  service)        /sbin/magisk --auto-selinux --service 2>/dev/null ;;
  boot-complete)  mkdir -p /data/adb/magisk; /sbin/magisk --auto-selinux --boot-complete 2>/dev/null ;;
  zygote-restart) /sbin/magisk --auto-selinux --zygote-restart 2>/dev/null ;;
esac
exit 0
'@ -replace "`r`n","`n"

$MAGISK_CONFIG = "SYSTEMMODE=true`nRECOVERYMODE=false`n"

# bootstrap bindmount: stock behaviour + bind our setuid su over xbin/su AFTER the .xb overmount
$BINDMOUNT_MOD = @'
#!/system/bin/sh
# Rooting helper: preserve stock .xb behavior, then idempotently expose our setuid bootstrap.
MAXSIZE=100000
MARKER_FILE="/data/downloads/.bm"
to_mount=$(getprop bst.config.bindmount)
[ -n "$to_mount" ] || to_mount=0
echo "to_mount=$to_mount" > /dev/kmsg
mounted=`mountpoint -q /system/xbin && echo "1" || echo "0"`
echo "mounted=$mounted" > /dev/kmsg
FILESIZE=$(stat -c%s "$MARKER_FILE" 2>/dev/null)
[ -n "$FILESIZE" ] || FILESIZE=0
echo "Size of $MARKER_FILE = $FILESIZE bytes." > /dev/kmsg
if [ "$FILESIZE" -gt "$MAXSIZE" ]; then
    rm -f "$MARKER_FILE"
    touch "$MARKER_FILE"
fi
if [ "$to_mount" -gt 0 ]; then
    if [ "$mounted" -le 0 ] && [ -d /data/downloads/.xb ]; then
        echo "Bind mounting..." > /dev/kmsg
        mount -o bind /data/downloads/.xb/ /system/xbin/ > /dev/kmsg
        echo "`date` bindmount" >> "$MARKER_FILE"
    fi
    # This script can run more than once, or after another helper already mounted xbin.
    # Bind the bootstrap on every invocation instead of only on the first .xb mount.
    mounted=`mountpoint -q /system/xbin && echo "1" || echo "0"`
    bootstrap=0
    if [ "$mounted" -gt 0 ] && [ -f /system/etc/bsr_su ]; then
        for target in /system/xbin/su /system/xbin/bstk/su; do
            if [ -e "$target" ] && mount -o bind /system/etc/bsr_su "$target"; then
                bootstrap=1
            fi
        done
        [ "$bootstrap" -gt 0 ] && echo "bsr: ungated setuid su bind-mounted" > /dev/kmsg
    fi
    # Do not pass --auto-daemon to bsr_su (it is intentionally daemonless).
    if [ "$bootstrap" -le 0 ] && [ ! -f /system/etc/bsr_su ] && [ -x /system/xbin/su ]; then
        /system/xbin/su --auto-daemon &
    fi
elif [ "$mounted" -gt 0 ]; then
    for pid in `pgrep daemonsu`
    do
        kill -9 $pid
    done
    sleep 3
    echo "`date` unbindmount" >> "$MARKER_FILE"
    umount /system/xbin/su 2>/dev/null
    umount /system/xbin/bstk/su 2>/dev/null
    umount /system/xbin/ > /dev/kmsg
fi
'@ -replace "`r`n","`n"

# stock bindmount restored at Clean (genuine factory file, extracted from bsrbak)
$BINDMOUNT_ORIG = @'
#!/system/bin/sh
# This script helps in rooting/unrooting the app-player by bindmounting/unmounting the .xb folder and xbin.

#================ ROOT/UNROOT =====================#

MAXSIZE=100000
MARKER_FILE="/data/downloads/.bm"
to_mount=$(getprop bst.config.bindmount)
echo "to_mount=$to_mount" > /dev/kmsg

mounted=`mountpoint -q /system/xbin && echo "1" || echo "0"`
echo "mounted=$mounted" > /dev/kmsg

# Get marker file size
FILESIZE=$(stat -c%s "$MARKER_FILE")
# Checkpoint
echo "Size of $MARKER_FILE = $FILESIZE bytes." > /dev/kmsg

if (( FILESIZE > MAXSIZE )); then
    echo "Removing and creating new $MARKER_FILE" > /dev/kmsg
    rm $MARKER_FILE
    touch $MARKER_FILE
fi

if [ $to_mount -gt 0 ] && [ $mounted -le 0 ] && [ -d /data/downloads/.xb ]; then
    echo "Bind mounting..." > /dev/kmsg
    mount -o bind /data/downloads/.xb/ /system/xbin/ > /dev/kmsg
    echo "`date` bindmount" >> $MARKER_FILE
    /system/xbin/su --auto-daemon &
elif [ $to_mount -le 0 ] && [ $mounted -gt 0 ]; then
    echo "Bind Unmounting..." > /dev/kmsg
    for pid in `pgrep daemonsu`
    do
        echo "Killing Process $pid" > /dev/kmsg
        kill -9 $pid
    done
    sleep 3
    echo "`date` unbindmount" >> $MARKER_FILE
    umount /system/xbin/ > /dev/kmsg
    if [ "$?" -ne 0 ]; then
        echo "Unmount failed..." > /dev/kmsg
    fi
fi

'@ -replace "`r`n","`n"

# ====================================================================
#  Raw-device / ext4 helpers (proven; same as the engine)
# ====================================================================
function Read-DeviceBytes($dev,$off,$cnt){ return ,(Read-BsrDeviceBytes $dev $off $cnt) }
function Copy-DeviceToFile($dev,$start,$len,$out){ Copy-BsrDiskRegion $dev $start $len $out }
function Copy-FileToDevice($inf,$dev,$start,$length){ Write-BsrDiskRegion $inf $dev $start $length }

function Kill-BlueStacks {
    # Kill ONLY BlueStacks-owned processes (names start with HD-, Bstk, or BlueStacks):
    # HD-Player/Adb/Agent/MultiInstanceManager/CommonLoader, BstkSVC, BlueStacksHelper/Web/Services...
    # This is scoped (no unrelated services are touched) and complete (BstkSVC holds the .bstk/conf
    # lock, so it MUST go or config edits won't persist -- verified). BlueStacks 5 has no auto-restart
    # Windows service, so killing the processes is sufficient. Wait only as long as needed: a slow
    # HD-Player shutdown can leave the old adb listener bound for a few seconds, which makes the next
    # boot rebind to a different live port.
    $killed = Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match '^(HD-|Bstk|BlueStacks)' }
    if($killed){ $killed | Stop-Process -Force -EA SilentlyContinue }
    $sw=[Diagnostics.Stopwatch]::StartNew()
    do{
        Start-Sleep 1
        $left = @(Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match '^(HD-|Bstk|BlueStacks)' })
    }while($left.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt 20)
    if($left.Count){ throw "BlueStacks processes are still running: $($left.Name -join ', '). No offline edits started." }
}

# Run a debugfs command-list against an ext4 image file; returns combined output.
function Invoke-Debugfs($img,[string[]]$cmds){
    if(-not $Debugfs -or -not (Test-Path -LiteralPath $Debugfs)){ throw "debugfs.exe not found (pass -Debugfs)." }
    [void][IO.Directory]::CreateDirectory($script:WorkDir)
    $scr = Join-Path $script:WorkDir ('dfs_' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllText($scr, ($cmds -join "`n"), (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-BsrNative $Debugfs @('-w','-f',$scr,$img) 120
        if($result.ExitCode){ throw "debugfs failed ($($result.ExitCode)): $($result.Output)" }
        $result.Output
    } finally { Remove-Item -LiteralPath $scr -Force -ErrorAction SilentlyContinue }
}

# Attach Root.vhd, carve ext4 -> temp img, run $editScriptBlock(img), then (optionally) write back.
function With-RootVhdExt4([scriptblock]$edit,[bool]$writeBack){
    if(-not (Test-Path -LiteralPath $Vhd)){ throw "Root.vhd not found: $Vhd" }
    $mounted=$null; $img=$null
    try{
        Say "[*] attach $Vhd (RW)..." Cyan
        $mounted=Mount-BsrDisk $Vhd -ReadOnly:(-not $writeBack)
        $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Vhd -StorageType $mounted.StorageType -EA Stop; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
        if($null -eq $dn){ throw 'no disk number' }
        $tgt=Get-Ext4Target $dn "\\.\PhysicalDrive$dn"
        if(-not $tgt){ throw 'no ext4 partition (0xEF53) in Root.vhd' }
        Say "[*] ext4 device=$($tgt.Device) size=$([Math]::Round($tgt.Length/1GB,2))GB"
        $img=Join-Path $script:WorkDir ('rootvhd_' + [guid]::NewGuid().ToString('N') + '.img'); New-Item -ItemType Directory -Path (Split-Path $img) -Force | Out-Null
        Say "[*] carve ext4 region (~1-2 min)..." Cyan
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img
        $ok = & $edit $img
        if($writeBack -and $ok -is [bool] -and $ok){
            Say "[*] write modified ext4 back into Root.vhd..." Cyan
            Copy-FileToDevice $img $tgt.Device $tgt.Start $tgt.Length
            Say "[+] Root.vhd updated." Green
        } elseif($writeBack){
            Say "[!] edit reported failure -- NOT writing back (Root.vhd unchanged)." Red
        }
        return $ok
    } finally {
        if($img -and (Test-Path -LiteralPath $img)){ Remove-Item -LiteralPath $img -Force -EA SilentlyContinue }
        if($mounted){ Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null; Say "[*] detached Root.vhd" }
    }
}

# Extract the canonical /data/adb/magisk + /system/etc/init/magisk file set from a Magisk APK.
function Extract-MagiskApk($apk,$dst){
    Expand-BsrMagiskApk $apk $dst
    Say '[+] extracted Magisk databin (10 files) from APK.' Green
}

# ---- conf edit: set a per-instance key (modify-only, UTF-8 no BOM) ----
function Set-ConfKeys([System.Collections.IDictionary]$values){
    $missing = @(Set-BsrConfValues $Conf $values)
    foreach($key in $missing){ Say "[~] conf key $key not present; leaving conf unchanged." Yellow }
}
function Set-ConfKey($key,$val){ Set-ConfKeys ([ordered]@{ $key=$val }) }

# ---- adb helpers ----
function Adb([string[]]$a){
    $timeout = if($a -contains 'install' -or $a -contains 'push'){180}else{30}
    $result = Invoke-BsrNative $Adb $a $timeout
    $script:LastAdbExitCode = $result.ExitCode
    $result.Output
}

# --- adb server isolation + private-port selection (version-conflict immunity) ---
$Script:AdbServerInit = $false
# Test seam: tests set this to a scriptblock returning @{ <port> = 'ours'|'other' } (absent key = free).
$Script:AdbServerPortProbe = $null
# Map listening ports in our private band to 'ours' (an HD-Adb.exe server we can safely reuse) or
# 'other' (anything else -- a non-adb app, OR a foreign-version adb we must NOT fight). Absent = free.
function Get-AdbServerPortState{ Get-BsrAdbServerPortState $Adb }
# Pick a private adb-server port that is FREE (or already hosts our own HD-Adb server). THIS is what
# handles "something is already using 15037 before my session": a non-adb app or a foreign-version adb
# on a candidate port is skipped, so we never collide with it and never kill it. A private-band
# ANDROID_ADB_SERVER_PORT override wins, but the shared default 5037 is ignored. 15037..15057 gives
# 21 ports of headroom.
function Resolve-AdbServerPort{
    $state = if($Script:AdbServerPortProbe){ & $Script:AdbServerPortProbe } else { Get-AdbServerPortState }
    Select-BsrAdbServerPort $state

}
# Force HD-Adb onto our resolved private server port so a DIFFERENT-version system adb on the default
# 5037 (Android SDK platform-tools v1.0.41 vs HD-Adb v1.0.36) can't kill our server mid-run. The clash
# ("server version doesn't match; killing...") silently breaks getprop/shell calls -- exactly how a
# fully-booted instance still trips Boot-And-Wait's "did not become adb-reachable" throw. A private
# port also gives us a clean transport table (no stale 'offline' devices). HD-Adb honours the env var.
function Initialize-AdbServer{
    if(-not $Script:AdbServerInit){ $env:ANDROID_ADB_SERVER_PORT = Resolve-AdbServerPort }
    if(-not (Test-Path -LiteralPath $Adb)){ return }
    if(-not $Script:AdbServerInit){ Stop-BsrAdbServer $Adb; $Script:AdbServerInit=$true }  # clean slate on OUR port
    Adb @('start-server') *>$null   # idempotent; also revives the server after Kill-BlueStacks nukes HD-Adb
}

# Test seam: the unit tests dot-source this file and set $Script:LiveAdbPortProbe to a scriptblock so
# the live scan is deterministic (it otherwise depends on what is really listening on the host).
$Script:LiveAdbPortProbe = $null
# Ports actually LISTENING in the BlueStacks adb band right now. This catches what the conf can get
# wrong: a clone can rebind a port that differs from BOTH status.adb_port and adb_port (verified in the
# wild -- when an instance's usual port is held by a leftover socket, BlueStacks records one port but
# binds another). We do NOT filter by owning process (the forwarder may be a privileged VM proc we
# can't name without elevation); every candidate is still verified by getprop + Is-BlueStacks in
# Boot-And-Wait, so a non-instance port here is harmless. Band 5550-5900 spans BlueStacks' clone ports
# (base 5555, clones +10 per instance => _9 = 5645, etc.).
function Get-LiveAdbPorts{
    if($Script:LiveAdbPortProbe){ return @(& $Script:LiveAdbPortProbe) }
    @(Get-BsrTcpListeners | Where-Object { $_.LocalPort -ge 5550 -and $_.LocalPort -le 5900 } |
        ForEach-Object { [string]$_.LocalPort } | Sort-Object -Unique)
}

# Test seam: unit tests set this to a scriptblock returning the Player.log text to scan.
$Script:PlayerLogProbe = $null
$Script:PlayerLogOffset = 0
# Mark the current end of Player.log so the readiness scan only looks at THIS boot's lines (the log is
# append-only and shared across instances/runs, so an old [Ready] from a previous session must not count).
function Set-PlayerLogMark { $Script:PlayerLogOffset = if($PlayerLog -and (Test-Path -LiteralPath $PlayerLog)){ try{ (Get-Item -LiteralPath $PlayerLog).Length }catch{ 0 } } else { 0 } }
# New Player.log text since the mark (bounded to the last ~1 MB so a very chatty log stays cheap to scan).
function Get-PlayerLogNew {
    if($Script:PlayerLogProbe){ return [string](& $Script:PlayerLogProbe) }
    if(-not ($PlayerLog -and (Test-Path -LiteralPath $PlayerLog))){ return '' }
    $txt=''
    try{
        $fs=[IO.File]::Open($PlayerLog,'Open','Read','ReadWrite')
        try{
            $len=$fs.Length; $start=$Script:PlayerLogOffset
            if($len -lt $start){ $start=0 }
            if(($len - $start) -gt 1MB){ $start=$len - 1MB }
            $fs.Position=$start
            $txt=(New-Object IO.StreamReader($fs)).ReadToEnd()
        } finally { $fs.Close() }
    }catch{ $txt='' }
    $txt
}
# Host-side boot signals (no adb needed -- immune to the offline-transport race). BlueStacks tags every
# Player.log line "<instance> [<phase>]" and the phase walks StartingKernel -> StartingAndroid -> Ready.
# Ready = fully booted (home launcher up); Alive = any phase line for THIS instance (cheap liveness a false
# WMI command-line read cannot contradict, so it stops the endless relaunch on a slow boot).
function Test-PlayerLogReady([string]$name=$Instance){ $t=Get-PlayerLogNew; if(-not $t){ return $false }; [bool]($t -match ('(?im)\s'+[regex]::Escape($name)+'\s+\[Ready\]')) }
function Test-PlayerLogAlive([string]$name=$Instance){ $t=Get-PlayerLogNew; if(-not $t){ return $false }; [bool]($t -match ('(?im)\s'+[regex]::Escape($name)+'\s+\[(StartingKernel|StartingAndroid|Ready|Stopping)\]')) }

# Candidate adb ports for THIS instance, in priority order. status.adb_port is the runtime port
# BlueStacks writes on boot; adb_port is the Multi-Instance Manager's assigned port (clones get
# 5585/5595/...). Those (from BlueStacks' OWN conf) come FIRST -- authoritative when fresh. Then the
# actually-bound listening ports, which rescue us when the conf is stale. 5555 is the last resort.
# NEVER hardcoded to a single value; Boot-And-Wait tries each AND verifies identity, so a stale conf
# value or a foreign emulator on a port can't mislead.
function Get-AdbPortCandidates([string[]]$LivePorts){
    $cands=New-Object System.Collections.Generic.List[string]
    if($Conf -and (Test-Path -LiteralPath $Conf)){
        try{
            $ct=[IO.File]::ReadAllText($Conf); $esc=[regex]::Escape($Instance)
            foreach($key in @('status\.adb_port','adb_port')){
                $m=[regex]::Match($ct,'(?im)^\s*bst\.instance\.'+$esc+'\.'+$key+'\s*=\s*"?(\d+)"?')
                if($m.Success){ [void]$cands.Add($m.Groups[1].Value) }
            }
        }catch{}
    }
    if(-not $PSBoundParameters.ContainsKey('LivePorts')){ $LivePorts = @(Get-LiveAdbPorts) }
    foreach($lp in $LivePorts){ [void]$cands.Add($lp) }   # live bound ports rescue a stale conf
    [void]$cands.Add('5555')
    $seen=@{}; $out=New-Object System.Collections.Generic.List[string]; foreach($c in $cands){ $portNumber=0; if([int]::TryParse($c,[ref]$portNumber) -and $portNumber -ge 1 -and $portNumber -le 65535 -and -not $seen.ContainsKey($c)){ $seen[$c]=$true; $out.Add($c) } }
    $out
}
# Is the device on $serial actually a BlueStacks instance (vs a foreign emulator squatting the port)?
# BlueStacks exposes bst.* props + the bst service manager (init.svc.bstsvcmgrtest); a stock AVD has neither.
function Is-BlueStacks([string]$serial){
    $all=(Adb @('-s',$serial,'exec-out','getprop') 2>&1 | Out-String)
    return ($all -match '\[(bst\.|init\.svc\.bst|ro\.bst)')
}
$Script:AdbSerial = $null   # the pinned 127.0.0.1:<port> transport for the current boot
function AdbConnect{ $s = if($Script:AdbSerial){$Script:AdbSerial}else{"127.0.0.1:$((Get-AdbPortCandidates)[0])"}; Adb @('connect',$s) *>$null }
# Transport state for $serial from `adb get-state`: 'device' (usable), 'offline' (socket up but handshake
# not done), or an error line. Returns the LAST non-empty, non-'* daemon *' token so daemon-start noise on
# the first call doesn't mask the real state. (Parse split out so it is unit-testable without adb.)
function Parse-AdbState([string]$text){ ($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($_ -notmatch '^\*') } | Select-Object -Last 1) }
function Get-AdbState([string]$serial){ Parse-AdbState (Adb @('-s',$serial,'get-state') 2>&1 | Out-String) }
# Force a FRESH transport for a wedged 'offline' TCP device. adb never re-handshakes a connected-but-offline
# socket -- a plain 'connect' on it just returns 'already connected' and leaves it offline -- so on a slow
# boot the transport can sit offline indefinitely while the guest is in fact up. disconnect (drop the dead
# socket) + connect (new handshake against a now-ready adbd) is what recovers it; the same thing a manual
# kill-server+connect does, but scoped to this one transport so other instances are left untouched.
function Repair-AdbTransport([string]$serial){
    Adb @('disconnect',$serial) *>$null
    Start-Sleep -Milliseconds 600
    (Adb @('connect',$serial) 2>&1 | Out-String)
}
# False if adb reported a transient transport/device error (common while a freshly-booted instance
# is still restarting adbd). Such output should be retried after a reconnect, not trusted.
function AdbOk([string]$o){
    $o -notmatch "device '.*' not found|device .* not found|no devices/emulators found|device offline|error: closed|protocol fault|connection reset|broken pipe|cannot connect to daemon"
}
# Run a noninteractive shell command without the legacy ADB terminal/PTY path,
# which can truncate output even when HD-Adb exits zero. Reconnect on a drop.
function AdbShellRetry([string]$serial,[string]$cmd,[int]$tries=6){
    $o=''
    for($k=0;$k -lt $tries;$k++){
        $o=Adb @('-s',$serial,'exec-out',($cmd+"`necho BSR_SHELL_DONE"))
        # HD-Adb can exit zero with an empty response during a transport reset.
        # Require a shell completion marker even for commands that print nothing.
        if((AdbOk $o) -and $o -match '(?m)^BSR_SHELL_DONE\r?$'){
            return ($o -replace '(?m)^BSR_SHELL_DONE\r?\n?','').TrimEnd("`r","`n")
        }
        if($k+1 -lt $tries){Start-Sleep 3; Adb @('start-server') *>$null; Repair-AdbTransport $serial | Out-Null}
    }
    throw "ADB shell did not complete after $tries attempts: $o"
}
# Run any adb subcommand (install/push/...) with the same reconnect-on-drop retry.
function AdbTry([string[]]$a,[int]$tries=4){
    $o=''
    for($k=0;$k -lt $tries;$k++){
        $o=Adb $a
        if(AdbOk $o){
            if($script:LastAdbExitCode){ throw "ADB failed ($($script:LastAdbExitCode)): $o" }
            $completed = if($a -contains 'install' -or $a -contains 'uninstall'){$o -match '(?m)^Success\s*$'}
                         elseif($a -contains 'push'){$o -match 'files? pushed|bytes in|\[\s*100%\]'}
                         else{$true}
            if($completed){return $o}
        }
        if($k + 1 -lt $tries){
            Start-Sleep 3; Adb @('start-server') | Out-Null
            if($Script:AdbSerial){ Repair-AdbTransport $Script:AdbSerial | Out-Null } else { AdbConnect }
        }
    }
    throw "ADB did not confirm completion after $tries attempts: $o"
}
$Script:BootstrapSuPath = $null
$Script:BootstrapSuProbe = $null   # unit-test seam: scriptblock(path) -> simulated `su -c id` output
$Script:BootstrapSuProbeResults = @()
function Resolve-BootstrapSu([string]$serial){
    if($Script:BootstrapSuPath){ return $Script:BootstrapSuPath }
    $results=New-Object System.Collections.Generic.List[string]
    foreach($path in @('/system/etc/bsr_su','/system/xbin/su','/system/xbin/bstk/su')){
        $o=if($Script:BootstrapSuProbe){& $Script:BootstrapSuProbe $path}else{AdbShellRetry $serial "$path -c 'id' 2>&1"}
        [void]$results.Add("$path=[$(Compact-Line $o 100)]")
        if($o -match 'uid=0'){
            $Script:BootstrapSuPath=$path
            $Script:BootstrapSuProbeResults=@($results | ForEach-Object {$_})
            return $path
        }
    }
    $Script:BootstrapSuProbeResults=@($results | ForEach-Object {$_})
    return $null
}
function Get-BootstrapDiagnostics([string]$serial){
    $guest=AdbShellRetry $serial 'echo BSR_BOOTSTRAP_DIAG; id; getenforce 2>/dev/null; echo bindmount=$(getprop bst.config.bindmount); ls -l /system/etc/bsr_su /system/xbin/su /system/xbin/bstk/su /system/bin/bindmount 2>&1; mount | grep " /system/xbin " 2>/dev/null'
    (($Script:BootstrapSuProbeResults -join '; ') + '; guest=[' + (Compact-Line $guest 500) + ']')
}
function AdbSu([string]$serial,[string]$cmd){
    $path=Resolve-BootstrapSu $serial
    if(-not $path){ return "BSR_BOOTSTRAP_SU_NOT_FOUND: $(Get-BootstrapDiagnostics $serial)" }
    AdbShellRetry $serial "$path -c '$cmd'"
}
function Compact-Line([string]$s,[int]$max=120){
    $x = (($s -replace "`r?`n",' | ').Trim())
    if($x.Length -gt $max){ return ($x.Substring(0,$max-3) + '...') }
    $x
}
function Get-HdPlayerCount([string]$name=$Instance){
    try{
        return @(Get-CimInstance Win32_Process -Filter "Name='HD-Player.exe'" -EA Stop |
            Where-Object { Test-HdPlayerInstance $_.CommandLine $name }).Count
    }catch{
        return 0
    }
}
function Boot-And-Wait([int]$timeoutSec=300){
    Assert-BlueStacksHostTools
    $Script:AdbSerial=$null; $Script:BootstrapSuPath=$null
    Initialize-AdbServer   # pin HD-Adb to its private server port BEFORE any connect (version-conflict immunity)
    if(-not (Test-Path -LiteralPath $Player)){ throw "HD-Player.exe not found: $Player" }
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $lastLaunch=-999; $lastProgress=-999; $extended=$false; $sawLife=$false; $sawReady=$false; $readyAt=-1; $lastDiag=''
    function Start-BsrInstanceLaunch {
        Say "[*] launching instance $Instance ..." Cyan
        Start-BsrPlayer $Player $Instance | Out-Null
        $sw.Elapsed.TotalSeconds
    }
    Set-PlayerLogMark   # only count [Ready] lines written AFTER this launch, not a prior boot's
    if(@(Get-BsrInstanceProcesses $Instance $PlayerLog).Count){
        Say "[*] waiting for the running instance $Instance ..." Cyan
        $lastLaunch=$sw.Elapsed.TotalSeconds
    }else{$lastLaunch = Start-BsrInstanceLaunch}
    Say "[*] HD-Adb server port: $env:ANDROID_ADB_SERVER_PORT" DarkGray
    # Find the adb endpoint from BlueStacks' OWN per-instance conf ports (status.adb_port first). Each pass we
    # connect, read get-state, and -- crucially -- HEAL a wedged 'offline' transport (disconnect + reconnect)
    # instead of letting a plain 'connect' no-op on it; THEN require boot_completed=1 and confirm the device
    # is really our BlueStacks instance. A host-side Player.log [Ready] is an independent 'guest booted'
    # signal, so a slow boot is tolerated while a genuinely dead launch still fails fast.
    $serial=$null; $primary=@(Get-AdbPortCandidates)[0]
    while(-not $serial){
        $elapsed=$sw.Elapsed.TotalSeconds
        $limit = if($sawLife){ $timeoutSec + 300 } else { $timeoutSec }
        if($elapsed -ge $limit){ break }
        # Guest booted (Player.log [Ready]) but adb never came online even after healing -> conclusive
        # failure; don't burn the full slow-boot grace on it.
        if($sawReady -and $readyAt -ge 0 -and ($elapsed - $readyAt) -ge 120){ break }
        # Clearly NOT a slow boot: nothing alive at all after a short while -> stop instead of waiting it out.
        if(-not $sawLife -and $elapsed -ge 90){ break }
        if($elapsed -ge $timeoutSec -and $sawLife -and -not $extended){
            Say "[~] instance is alive but not adb-ready after $timeoutSec s; extending wait (slow BlueStacks boot)." Yellow
            $extended=$true
        }
        Start-Sleep 3; Adb @('start-server') *>$null

        # Liveness is instance-specific (so another running instance can't mask a dead launch) and does NOT
        # trust the WMI command-line read alone (it reads null / != instance on some hosts -> a false zero).
        $ids = @(Get-BsrInstanceProcesses $Instance $PlayerLog | Select-Object -ExpandProperty Id)
        $playerCount = $ids.Count
        $ownedPorts = @(Get-BsrTcpListeners | Where-Object { $ids -contains $_.OwningProcess } | ForEach-Object { [string]$_.LocalPort })
        $ourPortUp = $ownedPorts.Count -gt 0
        $logAlive    = Test-PlayerLogAlive $Instance
        $alive = ($playerCount -gt 0 -or $ourPortUp -or $logAlive)
        if($alive){ $sawLife=$true }
        if(-not $sawReady -and (Test-PlayerLogReady $Instance)){ $sawReady=$true; $sawLife=$true; $readyAt=$elapsed; Say "[+] Player.log: $Instance reached [Ready] (guest booted)" Green }

        # Relaunch ONLY when nothing says the instance is alive -- a false WMI zero no longer spams launches
        # while the instance is clearly up (its adb port is listening or Player.log is advancing).
        if(-not $alive -and ($elapsed - $lastLaunch) -ge 45){
            Say "[~] instance not detected (no process / adb port / Player.log); retrying launch for $Instance ..." Yellow
            $lastLaunch = Start-BsrInstanceLaunch
        }

        $cands = @(Get-AdbPortCandidates -LivePorts $ownedPorts | Where-Object { $ownedPorts -contains $_ })
        foreach($port in $cands){
            $cand="127.0.0.1:$port"
            $conn=(Adb @('connect',$cand) 2>&1 | Out-String)
            if($conn -match '(?i)(connected to|already connected)'){ $sawLife=$true }
            $state = Get-AdbState $cand
            # The slow-boot fix: a connected-but-offline transport never self-heals, so force a fresh socket.
            if($state -ne 'device'){
                Repair-AdbTransport $cand | Out-Null
                $state = Get-AdbState $cand
            }
            if($state -ne 'device'){ $lastDiag = "$cand state=[$state]"; continue }
            # boot_completed must be EXACTLY "1" on its own line -- a "device '...:port' not found" error
            # contains the port digits and would false-positive a naive -match '1'.
            $out=(Adb @('-s',$cand,'exec-out','getprop','sys.boot_completed') 2>&1 | Out-String)
            $lastDiag = "$cand state=device boot=[$(Compact-Line $out)]"
            if(-not (($out -split "`n" | ForEach-Object { $_.Trim() }) -contains '1')){ continue }
            if(Is-BlueStacks $cand){ $serial=$cand; break }      # confirmed: our instance

        }
        if(($sw.Elapsed.TotalSeconds - $lastProgress) -ge 30 -and -not $serial){
            Say ("[~] waiting for adb: elapsed={0:n0}s hdplayer($Instance)={1} ready={2} candidates={3} last={4}" -f $sw.Elapsed.TotalSeconds,$playerCount,$sawReady,($cands -join ','),$lastDiag) DarkGray
            $lastProgress=$sw.Elapsed.TotalSeconds
        }
    }

    if(-not $serial){ throw "instance '$Instance' did not boot / become adb-reachable within $([int]$sw.Elapsed.TotalSeconds) s (adb server port $env:ANDROID_ADB_SERVER_PORT; last: $lastDiag)" }
    $Script:AdbSerial=$serial
    # Stabilize: a freshly-booted instance (esp. a first boot) restarts adbd a few times, which drops the
    # transport -> the next call fails with "device '127.0.0.1:<port>' not found". HEAL (not just reconnect)
    # on each drop until a plain shell is reliably reachable (3 consecutive hits) before handing it over.
    $stable=0
    for($s=0;$s -lt 30 -and $stable -lt 3;$s++){
        if((Get-AdbState $serial) -ne 'device'){ Repair-AdbTransport $serial | Out-Null } else { AdbConnect }
        $t=(Adb @('-s',$serial,'exec-out','echo BSR_RDY') 2>&1 | Out-String)
        if($t -match 'BSR_RDY'){ $stable++ } else { $stable=0; Start-Sleep 3 }
    }
    if($stable -lt 3){ throw "ADB transport for $Instance did not stabilize: $serial" }
    Say "[+] booted: $serial" Green
    Start-Sleep 4
    $serial
}

# ====================================================================
#  ACTIONS
# ====================================================================
function Do-Prep {
    Assert-BlueStacksHostTools
    Ensure-MagiskApk; Ensure-BsrSu; Ensure-Debugfs
    Say '==== PREP (offline) ====' Cyan
    Kill-BlueStacks

    # Fail before patching HD-Player or changing root flags if Windows cannot open
    # this image. Keep the preflight read-only and always release our attachment.
    Say '[*] checking virtual disk format and Windows mount support...'
    $preflight=Mount-BsrDisk $Vhd -ReadOnly
    Dismount-DiskImage -InputObject $preflight -ErrorAction Stop | Out-Null

    # 0) one-time pristine safety backup (so Undo can fully restore)
    $bak = "$Vhd.bsrbak"
    if(-not $NoBackup -and -not (Test-Path -LiteralPath $bak)){
        try { Say "[*] one-time pristine backup -> $bak ..." ; Copy-BsrBackupOnce $Vhd $bak; Say "[+] backup done." Green }
        catch { throw "Could not create the safety backup: $($_.Exception.Message)" }
    } else { Say "[*] pristine backup present (or -NoBackup): $bak" DarkGray }

    # 1) HD-Player anti-tamper patch (proven, via engine; engine Patch requires -Exe)
    Say '[*] HD-Player anti-tamper patch (engine Patch)...'
    $hdp = Join-Path $Install 'HD-Player.exe'
    $patchArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Engine,'-Action','Patch','-Exe',$hdp)
    if($SelfCmd){$patchArgs+=@('-SelfPath',$SelfCmd)}
    $patch = Invoke-BsrNative 'powershell.exe' $patchArgs 120
    Say $patch.Output DarkGray
    if($patch.ExitCode){ throw "HD-Player anti-tamper patch failed (exit code $($patch.ExitCode))." }

    # 2) conf: emulator root ON (so the bootstrap bindmount runs) + adb on. feature.rooting is a
    # real global BlueStacks key and is required by some builds before bst.config.bindmount becomes 1.
    Set-ConfKeys ([ordered]@{
        "bst.instance.$Instance.enable_root_access"='1'; 'bst.feature.rooting'='1'; 'bst.enable_adb_access'='1'
    })

    # 3) stage files
    $stage = Join-Path $script:WorkDir 'databin'
    Extract-MagiskApk $MagiskApk $stage
    $tmpDir = Join-Path $script:WorkDir 'sysfiles'; New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bootanim.rc'), $BOOTANIM_RC, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'config'),      $MAGISK_CONFIG, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bindmount'),   $BINDMOUNT_MOD, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bsr_boot.sh'), $BSR_BOOT_SH,   (New-Object System.Text.UTF8Encoding($false)))

    # 4) ONE offline carve: Magisk /system files + bootanim hijack + bootstrap su + hijacked bindmount
    $ok = With-RootVhdExt4 {
        param($img)
        $cmds = @(
            'mkdir /android','mkdir /android/system','mkdir /android/system/etc','mkdir /android/system/etc/init',
            'mkdir /android/system/etc/init/magisk','cd /android/system/etc/init/magisk'
        )
        foreach($f in 'magisk32','magisk64','magiskinit','magiskpolicy','stub.apk'){
            $cmds += @("rm $f","write $(DfsPath (Join-Path $stage $f)) $f","sif $f mode 0100700","sif $f uid 0","sif $f gid 0","sif $f links_count 1")
        }
        $cmds += @("rm config","write $(DfsPath (Join-Path $tmpDir 'config')) config","sif config mode 0100700","sif config uid 0","sif config gid 0","sif config links_count 1")
        # per-instance gate script (root-owned 0700, alongside the magisk binaries)
        $cmds += @("rm bsr_boot.sh","write $(DfsPath (Join-Path $tmpDir 'bsr_boot.sh')) bsr_boot.sh","sif bsr_boot.sh mode 0100700","sif bsr_boot.sh uid 0","sif bsr_boot.sh gid 0","sif bsr_boot.sh links_count 1")
        # hijack bootanim.rc (system:system 0664) -- now the GATED version
        $cmds += @('cd /android/system/etc/init','rm bootanim.rc',"write $(DfsPath (Join-Path $tmpDir 'bootanim.rc')) bootanim.rc",'sif bootanim.rc mode 0100664','sif bootanim.rc uid 1000','sif bootanim.rc gid 1000','sif bootanim.rc links_count 1')
        # bootstrap su template (setuid root)
        $cmds += @('cd /android/system/etc','rm bsr_su',"write $(DfsPath $BsrSu) bsr_su",'sif bsr_su mode 0106755','sif bsr_su uid 0','sif bsr_su gid 0','sif bsr_su links_count 1')
        # hijacked bindmount
        $cmds += @('cd /android/system/bin','rm bindmount',"write $(DfsPath (Join-Path $tmpDir 'bindmount')) bindmount",'sif bindmount mode 0100755','sif bindmount uid 0','sif bindmount gid 0','sif bindmount links_count 1')
        # Replace (never retain) any classic/engine su with OUR known bootstrap as a second delivery path.
        # If a build never raises bst.config.bindmount or no longer creates /data/downloads/.xb, native
        # /system/xbin remains visible and this still grants the one-time bootstrap. Clean removes it.
        $cmds += @('cd /android/system/xbin','rm su','rm daemonsu',
                   "write $(DfsPath $BsrSu) su",'sif su mode 0106755','sif su uid 0','sif su gid 0','sif su links_count 1')
        $expected = @(
            @('/android/system/etc/init/magisk/magisk64',(Join-Path $stage 'magisk64'),448,0,0),
            @('/android/system/etc/init/magisk/magisk32',(Join-Path $stage 'magisk32'),448,0,0),
            @('/android/system/etc/init/magisk/magiskinit',(Join-Path $stage 'magiskinit'),448,0,0),
            @('/android/system/etc/init/magisk/magiskpolicy',(Join-Path $stage 'magiskpolicy'),448,0,0),
            @('/android/system/etc/init/magisk/stub.apk',(Join-Path $stage 'stub.apk'),448,0,0),
            @('/android/system/etc/init/magisk/config',(Join-Path $tmpDir 'config'),448,0,0),
            @('/android/system/etc/init/magisk/bsr_boot.sh',(Join-Path $tmpDir 'bsr_boot.sh'),448,0,0),
            @('/android/system/etc/init/bootanim.rc',(Join-Path $tmpDir 'bootanim.rc'),436,1000,1000),
            @('/android/system/etc/bsr_su',$BsrSu,3565,0,0),
            @('/android/system/bin/bindmount',(Join-Path $tmpDir 'bindmount'),493,0,0),
            @('/android/system/xbin/su',$BsrSu,3565,0,0)
        )
        foreach($file in $expected){ $cmds += "stat $($file[0])" }
        $out = Invoke-Debugfs $img $cmds
        Say $out DarkGray
        $good = $true
        foreach($file in $expected){
            if(-not(Test-BsrDebugfsFile $out $file[0] ([IO.FileInfo]$file[1]).Length $file[2] $file[3] $file[4])){
                Say "[!] failed to verify $($file[0]) (size/mode/owner)" Red; $good=$false
            }
        }
        if(-not $good){ Say '[!] prep verify FAILED' Red }
        return $good
    } $true
    if(-not $ok){ throw "Prep failed (Root.vhd not modified)." }
    Say '[+] PREP complete.' Green
}

function Do-Data([switch]$Prepared) {
    Ensure-MagiskApk
    Say '==== DATA (online, bootstrap su) ====' Cyan
    $stage = Join-Path $script:WorkDir 'databin'
    # Auto has already staged these files in this invocation's private directory.
    # Standalone Data still extracts its own complete set before booting.
    if(-not $Prepared){ Extract-MagiskApk $MagiskApk $stage }
    $serial = Boot-And-Wait
    # sanity: bootstrap su works
    $id = (AdbSu $serial 'id').Trim()
    if($id -notmatch 'uid=0'){ throw "bootstrap su not root (got '$id'). Prep/patch/conf issue." }
    Say "[+] bootstrap su OK: $id" Green
    # install Magisk manager app
    Say '[*] adb install Magisk APK...'
    Say ("    " + (AdbTry @('-s',$serial,'install','-r',$MagiskApk)).Trim()) DarkGray
    # push databin to /data/local/tmp then su-copy into /data/adb/magisk
    AdbShellRetry $serial 'rm -rf /data/local/tmp/bsrmbin; mkdir -p /data/local/tmp/bsrmbin' | Out-Null
    @((AdbTry @('-s',$serial,'push',(Fwd "$stage\."),'/data/local/tmp/bsrmbin/')) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1 | ForEach-Object { Say "    $($_.Trim())" DarkGray }
    $script = @'
set -e
mkdir -p /data/adb/magisk /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d
# per-instance ROOT FLAG: bsr_boot.sh on the shared master only activates Magisk on instances that
# carry this file on their OWN /data. This is what makes THIS instance rooted while others stay clean.
touch /data/adb/.bsr_root; chmod 600 /data/adb/.bsr_root
cp -f /data/local/tmp/bsrmbin/* /data/adb/magisk/
chown -R 0:0 /data/adb/magisk
chmod 0755 /data/adb/magisk/busybox /data/adb/magisk/magisk32 /data/adb/magisk/magisk64 /data/adb/magisk/magiskboot /data/adb/magisk/magiskinit /data/adb/magisk/magiskpolicy /data/adb/magisk/*.sh
chmod 0644 /data/adb/magisk/stub.apk
restorecon -R /data/adb 2>/dev/null || true
sync
echo BSR_DATA_OK
'@ -replace "`r`n","`n"
    $script | Set-Content -LiteralPath (Join-Path $script:WorkDir 'datapop.sh') -Encoding ascii -NoNewline
    AdbTry @('-s',$serial,'push',(Fwd (Join-Path $script:WorkDir 'datapop.sh')),'/data/local/tmp/bsr_pop.sh') | Out-Null
    $r = AdbSu $serial 'sh /data/local/tmp/bsr_pop.sh'
    Say $r DarkGray
    if($r -notmatch 'BSR_DATA_OK'){ throw "/data/adb/magisk populate failed." }
    # Keep both the script and its input files until its success reply arrives:
    # a lost reply must allow the entire population step to run again safely.
    AdbShellRetry $serial 'rm -f /data/local/tmp/bsr_pop.sh; rm -rf /data/local/tmp/bsrmbin' | Out-Null
    Say '[+] /data/adb/magisk populated. Rebooting so magiskd initializes (env now complete)...' Green
    AdbShellRetry $serial 'sync' | Out-Null; Start-Sleep 2; Kill-BlueStacks

    # second boot: magiskd should now start; bsr_su is still present so we can set the grant policy.
    $serial = Boot-And-Wait
    Start-Sleep 5
    $mg = (AdbSu $serial 'ps -A | grep -c magiskd').Trim()
    Say "    magiskd processes: $mg" $(if($mg -match '[1-9]'){'Green'}else{'Yellow'})
    # grant policy (allow shell uid 2000). The SQL has parens, which break through nested su -c '...'
    # quoting -> push it as a script FILE and run that (robust, same pattern as the populate step).
    $polSh = 'magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,0,0)"' + "`n" + 'echo POL_RC=$?' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $script:WorkDir 'polset.sh'), $polSh, (New-Object System.Text.UTF8Encoding($false)))
    AdbTry @('-s',$serial,'push',(Fwd (Join-Path $script:WorkDir 'polset.sh')),'/data/local/tmp/bsr_pol.sh') | Out-Null
    $pol = AdbSu $serial 'sh /data/local/tmp/bsr_pol.sh'
    Say "    policy: $(($pol -replace "`r?`n",' ').Trim())" DarkGray
    $mc = (AdbSu $serial 'magisk -c').Trim(); Say "    magisk -c: $mc"
    AdbSu $serial 'sync' | Out-Null
    if($mg -notmatch '^\d+$' -or [int]$mg -le 0){ throw 'magiskd not detected after populate+reboot -- check /cache/magisk.log' }
    if($pol -notmatch '(?m)^POL_RC=0\s*$'){ throw "Magisk shell grant policy failed: $pol" }
    AdbShellRetry $serial 'rm -f /data/local/tmp/bsr_pol.sh' | Out-Null
    Say '[+] DATA complete (/data/adb/magisk populated, magiskd up, policy set).' Green
    AdbShellRetry $serial 'sync' | Out-Null; Start-Sleep 2; Kill-BlueStacks
}

function Do-Clean {
    Ensure-Debugfs
    Say '==== CLEAN (offline: erase bootstrap su, restore stock bindmount) ====' Cyan
    Kill-BlueStacks
    $tmpDir = Join-Path $script:WorkDir 'sysfiles'; New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bindmount.orig'), $BINDMOUNT_ORIG, (New-Object System.Text.UTF8Encoding($false)))
    $ok = With-RootVhdExt4 {
        param($img)
        $cmds = @(
            'cd /android/system/etc','rm bsr_su',
            'cd /android/system/bin','rm bindmount',"write $(DfsPath (Join-Path $tmpDir 'bindmount.orig')) bindmount",
            'sif bindmount mode 0100775','sif bindmount uid 1000','sif bindmount gid 1000','sif bindmount links_count 1',
            # also scrub any leftover CLASSIC/engine su so Magisk is the SOLE root (no "Abnormal State")
            'cd /android/system/xbin','rm su','rm daemonsu',
            'stat /android/system/bin/bindmount','stat /android/system/etc/bsr_su','stat /android/system/xbin/su'
        )
        $out = Invoke-Debugfs $img $cmds
        Say $out DarkGray
        $bmOk = Test-BsrDebugfsFile $out '/android/system/bin/bindmount' ([IO.FileInfo](Join-Path $tmpDir 'bindmount.orig')).Length 509 1000 1000
        $suGone = $out -match '(?im)bsr_su:?\s*File not found'
        $xbinSuGone = $out -match '(?im)/android/system/xbin/su:?\s*File not found'
        if(-not $bmOk){ Say '[!] stock bindmount not detected after restore' Red }
        if(-not $xbinSuGone){ Say '[!] /system/xbin/su still present after scrub' Red }
        return ($bmOk -and $suGone -and $xbinSuGone)
    } $true
    if(-not $ok){ throw "Clean failed." }
    Say '[+] CLEAN complete (bsr_su removed, stock bindmount restored).' Green
}

function Do-Finalize {
    Say '==== FINALIZE (emulator root OFF + shareable master) ====' Cyan
    Set-ConfKeys ([ordered]@{ "bst.instance.$Instance.enable_root_access"='0'; 'bst.feature.rooting'='0' })
    # Ensure the shared master Root.vhd + fastboot.vdi are Readonly so MULTIPLE instances can attach
    # them at once (type="Normal" is exclusive -> a 2nd instance fails with VBOX_E_INVALID_OBJECT_STATE).
    # Data.vhdx stays Normal (per-instance, writable). This is the factory layout.
    $masterDir = Split-Path -Parent $Vhd
    $masterBstk = Join-Path $masterDir ((Split-Path -Leaf $masterDir) + '.bstk')
    $instanceBstk = Join-Path (Split-Path -Parent $Conf) "Engine\$Instance\$Instance.bstk"
    foreach($bstk in @($instanceBstk,$masterBstk) | Select-Object -Unique){
        if(-not(Test-Path -LiteralPath $bstk)){ continue }
        $raw=[IO.File]::ReadAllText($bstk)
        $updated=[regex]::Replace($raw, '(?s)<HardDisk\b[^>]*>', [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $tag=$match.Value
            $location=[regex]::Match($tag,'\blocation="([^"]+)"')
            if($location.Success -and [IO.Path]::GetFileName($location.Groups[1].Value.Replace('/','\')) -in @('Root.vhd','fastboot.vdi')){
                return [regex]::Replace($tag,'(?i)(\btype=")Normal(")','${1}Readonly${2}')
            }
            return $tag
        })
        if($updated -cne $raw){
            Copy-BsrBackupOnce $bstk "$bstk.bak"
            Write-BsrTextFile $bstk $updated
            Say "[+] shared disks set Readonly: $bstk" Green
        }
    }
    Say '[+] FINALIZE complete.' Green
}

# Classify a device su inventory (lines "<path>|link|<target>" or "<path>|file|") and return the
# NON-Magisk su paths. Magisk's own su are symlinks to its executable; a real su binary
# (or a symlink pointing elsewhere) is a COMPETING root -- that is exactly what trips Magisk's
# "Abnormal State -- a su binary not from Magisk has been detected". Pure/string-only => unit-testable.
function Test-MagiskSuTarget([string]$target){ $target -cmatch '(^|/)magisk(?:32|64)?$' }
function Find-StraySu([string]$scan){
    $stray=@()
    foreach($line in ($scan -split "`n")){
        $line=$line.Trim(); if(-not $line){ continue }
        $p=$line.Split('|')
        if($p.Count -lt 2){ continue }
        $path=$p[0].Trim(); $kind=$p[1].Trim(); $target= if($p.Count -ge 3){ $p[2].Trim() } else { '' }
        if(-not $path){ continue }
        if($kind -eq 'link'){ if(-not(Test-MagiskSuTarget $target)){ $stray+=$path } }
        elseif($kind -eq 'file'){ $stray+=$path }
    }
    ,$stray
}

function Do-Verify {
    Say '==== VERIFY (Magisk root) ====' Cyan
    $serial = Boot-And-Wait
    $id  = (AdbShellRetry $serial 'su -c id').Trim()
    $whi = (AdbShellRetry $serial 'readlink /system/bin/su').Trim()
    $selinux = (AdbShellRetry $serial 'getenforce').Trim()
    # Enumerate EVERY su in the standard PATH dirs and classify each: a symlink to magisk is ours,
    # anything else is a competing root (the cause of Magisk's "Abnormal State"). Pushed as a script
    # file (not inline su -c '...') because the loop's semicolons don't survive PS -> adb -> device quoting.
    $scanSh = @'
for f in /system/bin/su /system/xbin/su /sbin/su /vendor/bin/su /odm/bin/su /system_ext/bin/su /product/bin/su /debug_ramdisk/su; do
  if [ -L "$f" ]; then echo "$f|link|$(readlink "$f")"
  elif [ -e "$f" ]; then echo "$f|file|"
  fi
done
echo BSR_SCAN_DONE
'@ -replace "`r`n","`n"
    $scanFile = Join-Path $script:WorkDir 'bsr_suscan.sh'
    New-Item -ItemType Directory -Path (Split-Path $scanFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($scanFile,$scanSh,(New-Object System.Text.UTF8Encoding($false)))
    AdbTry @('-s',$serial,'push',(Fwd $scanFile),'/data/local/tmp/bsr_suscan.sh') | Out-Null
    $scan = AdbShellRetry $serial 'su -c "sh /data/local/tmp/bsr_suscan.sh"'
    AdbShellRetry $serial 'rm -f /data/local/tmp/bsr_suscan.sh' | Out-Null
    $stray = Find-StraySu $scan
    # Android's built-in find differs across versions. Use the bundled BusyBox,
    # and require both traversal and hashing to succeed before printing the marker.
    $sweepScript=@'
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || exit 1
set -- /system /data/adb
[ ! -d /data/downloads ] || set -- "$@" /data/downloads
files=$("$BB" find "$@" -type f -size 4968c) || exit 1
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  h=$("$BB" sha256sum "$f") || exit 1
  case "$h" in __BSR_HASH__*) echo "TRACE:$f";; esac
done || exit 1
echo SWEEPDONE
'@
    $sweepScript=$sweepScript.Replace('__BSR_HASH__',$BSR_SU_SHA) -replace "`r`n","`n"
    $sweepFile=Join-Path $script:WorkDir 'bsr_sweep.sh'
    [IO.File]::WriteAllText($sweepFile,$sweepScript,(New-Object Text.UTF8Encoding($false)))
    AdbTry @('-s',$serial,'push',$sweepFile,'/data/local/tmp/bsr_sweep.sh') | Out-Null
    $sweep = AdbShellRetry $serial 'su -c "sh /data/local/tmp/bsr_sweep.sh"'
    AdbShellRetry $serial 'rm -f /data/local/tmp/bsr_sweep.sh' | Out-Null
    Say ("  su -c id            : {0}" -f $id) $(if($id -match 'uid=0'){'Green'}else{'Red'})
    Say ("  /system/bin/su ->   : {0}" -f $whi)
    Say ("  SELinux (guest)     : {0}  (reported by BlueStacks; blueStackRoot does not change it)" -f $selinux) DarkGray
    Say  "  su inventory        :"
    foreach($l in ($scan -split "`n")){ $l=$l.Trim(); if($l){ Say "      $l" DarkGray } }
    if($stray.Count){ Say ("  competing su        : {0}  <-- NOT from Magisk" -f ($stray -join ', ')) Red }
    else            { Say  "  competing su        : none (good)" Green }
    Say ("  bsr_su sweep        : {0}" -f ($sweep -replace "`r?`n",' ').Trim())
    if($id -match 'uid=0' -and (Test-MagiskSuTarget $whi) -and $stray.Count -eq 0 -and $sweep -notmatch 'TRACE:' -and $scan -match '(?m)^BSR_SCAN_DONE\s*$' -and $sweep -match '(?m)^SWEEPDONE\s*$'){
        Say '[+] VERIFY PASS: Magisk is the sole root; no competing su, no bsr_su traces.' Green
    } else {
        Say '[!] VERIFY FAIL: review the above.' Red
        if($stray.Count){ Say '    -> a competing su is present; re-run Clean then reboot.' Yellow }
        throw 'Root verification failed or was incomplete.'
    }
}

function Do-Undo {
    Assert-BlueStacksHostTools
    if($Full){
        foreach($backup in @("$Vhd.bsrbak",(Join-Path $Install 'HD-Player.exe.bak'))){
            if(-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Item -LiteralPath $backup).Length -eq 0){
                throw "Full host scrub requires a complete backup: $backup"
            }
        }
    }
    # PER-INSTANCE unroot (multi-instance safe): just drop THIS instance's root flag + /data Magisk
    # state + app. The shared master /system and HD-Player patch are LEFT INTACT so any OTHER rooted
    # instances keep working. Use -Full to also scrub the master + un-patch (unroots ALL instances).
    Say "==== UNDO ($Instance) ====" Cyan
    Kill-BlueStacks; Start-Sleep 2
    $dataFailure=$null
    try {
        $serial = Boot-And-Wait 240
        # while the flag is still present this instance has working Magisk root, so its su can wipe /data/adb
        $rm = 'set -e; rm -f /data/adb/.bsr_root; rm -rf /data/adb/magisk /data/adb/magisk.db /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d; sync; echo BSR_RM_OK'
        $o1 = AdbShellRetry $serial "su -c '$rm'"
        if($o1 -notmatch '(?m)^BSR_RM_OK\s*$'){ $o1=AdbSu $serial $rm }
        if($o1 -notmatch '(?m)^BSR_RM_OK\s*$'){ throw "Could not confirm per-instance Magisk data removal: $o1" }
        $package=AdbShellRetry $serial 'pm path io.github.huskydg.magisk; echo BSR_PACKAGE_CHECK'
        if($package -notmatch '(?m)^BSR_PACKAGE_CHECK\s*$'){throw "Could not query the manager package: $package"}
        if($package -match 'package:'){ AdbTry @('-s',$serial,'uninstall','io.github.huskydg.magisk') | Out-Null }
        AdbShellRetry $serial 'sync' | Out-Null; Start-Sleep 2
        Say "[+] $Instance unrooted (flag + /data Magisk state removed, app uninstalled)." Green
    } catch { $dataFailure=$_.Exception.Message; Say "[!] per-instance cleanup failed: $dataFailure" Red }
    Kill-BlueStacks
    Set-ConfKeys ([ordered]@{ "bst.instance.$Instance.enable_root_access"='0'; 'bst.feature.rooting'='0' })

    if($Full){
        Say '[*] -Full: scrubbing shared master + un-patching HD-Player (unroots ALL instances)...' Yellow
        $bak = "$Vhd.bsrbak"
        if(Test-Path -LiteralPath $bak){ Copy-BsrFileAtomically $bak $Vhd -Replace; Say '[+] master Root.vhd restored from its backup.' Green }
        else { throw 'No Root.vhd.bsrbak: cannot complete a full host scrub.' }
        $hdp = Join-Path $Install 'HD-Player.exe'
        Say '[*] un-patching HD-Player.exe (-Exe last to avoid arg-glue)...'
        $restoreArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Engine,'-Action','Patch','-Restore','-Exe',$hdp)
        if($SelfCmd){$restoreArgs+=@('-SelfPath',$SelfCmd)}
        $restored=Invoke-BsrNative 'powershell.exe' $restoreArgs 120
        Say $restored.Output DarkGray
        if($restored.ExitCode){ throw 'Could not restore HD-Player.exe from its backup.' }
        if($dataFailure){ throw "Host files restored, but guest data cleanup failed: $dataFailure" }
        Say '[+] FULL host scrub complete (no instance rooted; HD-Player factory).' Green
    } else {
        if($dataFailure){ throw "Per-instance undo was incomplete: $dataFailure" }
        Say "[+] UNDO complete. Shared master + HD-Player patch left intact so other rooted instances keep working." Green
        Say "    For a full host scrub (no instances rooted, HD-Player un-patched), re-run Undo with -Full." DarkGray
    }
}

# Only dispatch when run normally (-File / &). When DOT-SOURCED (. bsr_magisk.ps1) -- e.g. by the test
# suite to unit-test the resolver functions -- skip the pipeline so nothing boots or writes.
if ($MyInvocation.InvocationName -ne '.') {
    $operationLock = $null
    try {
        $operationLock = Enter-BsrOperationLock
        switch($Action){
            'Prep'     { Do-Prep }
            'Data'     { Do-Data }
            'Clean'    { Do-Clean }
            'Finalize' { Do-Finalize }
            'Verify'   { Do-Verify }
            'Auto'     { Do-Prep; Do-Data -Prepared; Do-Clean; Do-Finalize; Do-Verify }
            'Undo'     { Do-Undo }
        }
    } catch {
        Say "[!] $($_.Exception.Message)" Red
        exit 1
    } finally {
        if(Test-Path -LiteralPath $script:WorkDir){
            $expectedParent = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'bsr_work')).TrimEnd('\') + '\'
            $resolvedWork = [IO.Path]::GetFullPath($script:WorkDir)
            if($resolvedWork.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and
               [IO.Path]::GetFileName($resolvedWork) -match '^session_[a-f0-9]{32}$'){
                Remove-Item -LiteralPath $resolvedWork -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # Free our private adb-server port on the way out. adb normally leaves its server running
        # forever; we only ever started one if Initialize-AdbServer ran (an online action), so tidy it
        # up so nothing of ours lingers on the port after the tool exits. (runs even if an action threw)
        if ($Script:AdbServerInit -and (Test-Path -LiteralPath $Adb)) { try { Stop-BsrAdbServer $Adb } catch { Say $_.Exception.Message Yellow } }
        if ($operationLock) { $operationLock.ReleaseMutex(); $operationLock.Dispose() }
    }
    # Explicit success code so the batch caller can trust %errorlevel% -- a native tool in the 'finally'
    # above otherwise leaves its own $LASTEXITCODE as the process exit code. The catch path already exits 1.
    exit 0
}
