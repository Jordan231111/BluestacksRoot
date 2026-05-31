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
# NOTE: 'Continue' (not 'Stop') because native tools (adb, debugfs) write normal output to
# stderr, which under 'Stop' becomes a fatal NativeCommandError. Every critical step below has
# an explicit success check + throw, and disk cmdlets use -ErrorAction Stop, so failures still abort.
$ErrorActionPreference = 'Continue'
$Self = $MyInvocation.MyCommand.Path
$Here = Split-Path -Parent $Self

# --------- the bsr_su grant policy / known signatures ----------
$BSR_SU_SHA = '7eb6380ee26ce0b68d9f3f23ac04f50e0dfdd49359ef17d1a4978be1795913dd'

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }

# --------- normalize incoming paths (callers may pass a trailing '\' or a stray '"') ----------
# A registry InstallDir like  C:\Program Files\BlueStacks_nxt\  becomes  -Install "...\nxt\"  on the
# command line, and PowerShell -File treats the \" as an escaped quote -> the value arrives as
# '...\nxt"'.  Strip stray quotes and any trailing slash/space so Join-Path stays clean.
function Clean-Path($p){ if($null -eq $p){return $p}; ($p -replace '"','').Trim().TrimEnd('\') }
$Install = Clean-Path $Install
$Engine  = Clean-Path $Engine
$Debugfs = Clean-Path $Debugfs
$Vhd     = Clean-Path $Vhd
$Conf    = Clean-Path $Conf
$SelfCmd = Clean-Path $SelfCmd

# --------- registry discovery (NO hardcoded install/data paths) ----------
# BlueStacks records its real install/data folders in the registry; honour a custom install location by
# reading them instead of assuming C:\Program Files\.. / C:\ProgramData\.. . nxt (BlueStacks 5) first,
# then msi5 (MSI App Player), under both the native and WOW6432Node views.
function Get-RegBlueStacks{
    foreach($k in @('HKLM:\SOFTWARE\BlueStacks_nxt','HKLM:\SOFTWARE\BlueStacks_msi5',
                    'HKLM:\SOFTWARE\WOW6432Node\BlueStacks_nxt','HKLM:\SOFTWARE\WOW6432Node\BlueStacks_msi5')){
        try{
            $p=Get-ItemProperty -Path $k -ErrorAction Stop
            if($p -and ($p.InstallDir -or $p.DataDir -or $p.UserDefinedDir)){
                return [pscustomobject]@{ InstallDir=$p.InstallDir; DataDir=$p.DataDir; UserDefinedDir=$p.UserDefinedDir }
            }
        }catch{}
    }
    return $null
}
# Folder that actually holds bluestacks.conf + Engine\. Newer BlueStacks reports DataDir as ...\Engine.
function Get-DataRoot($reg){
    $d = if($reg){ if($reg.DataDir){$reg.DataDir}elseif($reg.UserDefinedDir){$reg.UserDefinedDir}else{$null} } else { $null }
    if(-not $d){ $d = Join-Path $env:ProgramData 'BlueStacks_nxt' }
    if($d -match '(?i)[\\/]engine[\\/]?$'){ $d = $d -replace '(?i)[\\/]engine[\\/]?$','' }
    $d.TrimEnd('\','/')
}

$reg = Get-RegBlueStacks
if (-not $Install) { $Install = if($reg -and $reg.InstallDir){ $reg.InstallDir.TrimEnd('\') } else { Join-Path $env:ProgramFiles 'BlueStacks_nxt' } }
$DataRoot = Get-DataRoot $reg
if (-not $Engine)  { $Engine  = Join-Path $Here 'bsr_engine.ps1' }
if (-not $Debugfs) {
    foreach($c in @((Join-Path $Here 'debugfs\debugfs.exe'), (Join-Path $env:TEMP 'bsr_work\debugfs\debugfs.exe'))){ if(Test-Path $c){ $Debugfs=$c; break } }
}
if (-not $Conf)    { $Conf = Join-Path $DataRoot 'bluestacks.conf' }
if (-not $Vhd -and $Instance) { $Vhd = Join-Path $DataRoot "Engine\$Instance\Root.vhd" }
$Adb    = Join-Path $Install 'HD-Adb.exe'
$Player = Join-Path $Install 'HD-Player.exe'
$BsrSu  = if($BsrSuPath){$BsrSuPath}else{ Join-Path $Here 'su_src\bsr_su' }   # the setuid bootstrap su (4968 B)

# ---- embedded-payload self-extraction (only used when -SelfCmd <blueStackRoot.cmd> is given) ----
function Extract-Block($cmdPath,$begTok,$endTok){
    $t=[System.IO.File]::ReadAllText($cmdPath)
    $b="__BSR_${begTok}_"+"BEGIN__"; $e="__BSR_${endTok}_"+"END__"
    $i=$t.IndexOf($b); $j=$t.IndexOf($e)
    if($i -lt 0 -or $j -le $i){ return $null }
    $i=$t.IndexOf([char]10,$i)+1
    $t.Substring($i,$j-$i)
}
function Ensure-Debugfs {
    if($script:Debugfs -and (Test-Path $script:Debugfs)){ return }
    foreach($c in @((Join-Path $Here 'debugfs\debugfs.exe'), (Join-Path $env:TEMP 'bsr_work\debugfs\debugfs.exe'))){ if(Test-Path $c){ $script:Debugfs=$c; return } }
    if($SelfCmd -and (Test-Path $SelfCmd)){
        $b64=Extract-Block $SelfCmd 'DFS' 'DFS'
        if($b64){ $b64=($b64 -replace '[^A-Za-z0-9+/=]',''); $d=Join-Path $env:TEMP 'bsr_work\debugfs'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $zip=Join-Path $d '_d.zip'; [System.IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($b64)); Add-Type -AssemblyName System.IO.Compression.FileSystem; $za=[System.IO.Compression.ZipFile]::OpenRead($zip); try{ foreach($en in $za.Entries){ if(-not $en.Name){continue}; $tp=Join-Path $d $en.FullName; $dd=Split-Path -Parent $tp; if(-not(Test-Path $dd)){New-Item -ItemType Directory -Path $dd -Force|Out-Null}; [System.IO.Compression.ZipFileExtensions]::ExtractToFile($en,$tp,$true) } } finally { $za.Dispose() }; Remove-Item $zip -Force -EA SilentlyContinue; $exe=Join-Path $d 'debugfs.exe'; if(Test-Path $exe){ $script:Debugfs=$exe } }
    }
    if(-not ($script:Debugfs -and (Test-Path $script:Debugfs))){ throw "debugfs.exe not found (pass -Debugfs or -SelfCmd)." }
}
function Ensure-BsrSu {
    if($script:BsrSu -and (Test-Path $script:BsrSu)){ return }
    if($SelfCmd -and (Test-Path $SelfCmd)){
        $b64=Extract-Block $SelfCmd 'BSRSU' 'BSRSU'
        if($b64){ $b64=($b64 -replace '[^A-Za-z0-9+/=]',''); $gz=[Convert]::FromBase64String($b64); $in=New-Object System.IO.MemoryStream(,$gz); $z=New-Object System.IO.Compression.GZipStream($in,[System.IO.Compression.CompressionMode]::Decompress); $out=New-Object System.IO.MemoryStream; $buf=New-Object byte[] 65536; while(($n=$z.Read($buf,0,$buf.Length)) -gt 0){ $out.Write($buf,0,$n) }; $z.Close(); $in.Close(); $d=Join-Path $env:TEMP 'bsr_work'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $p=Join-Path $d 'bsr_su'; [System.IO.File]::WriteAllBytes($p,$out.ToArray()); $out.Close(); $script:BsrSu=$p }
    }
    if(-not ($script:BsrSu -and (Test-Path $script:BsrSu))){ throw "bootstrap su (bsr_su) not found (pass -BsrSuPath or -SelfCmd)." }
}
function Ensure-MagiskApk {
    if($script:MagiskApk -and (Test-Path $script:MagiskApk)){ return }
    # an external APK next to the .cmd already resolved by the caller; otherwise extract the EMBEDDED one
    if($SelfCmd -and (Test-Path $SelfCmd)){
        $b64=Extract-Block $SelfCmd 'APK' 'APK'
        if($b64){ $b64=($b64 -replace '[^A-Za-z0-9+/=]',''); $d=Join-Path $env:TEMP 'bsr_work'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $p=Join-Path $d 'magisk.apk'; [System.IO.File]::WriteAllBytes($p,[Convert]::FromBase64String($b64)); $script:MagiskApk=$p; Say "[*] using embedded Magisk APK ($([Math]::Round((Get-Item $p).Length/1MB,1)) MB)." DarkGray }
    }
    if(-not ($script:MagiskApk -and (Test-Path $script:MagiskApk))){ throw "Magisk APK not found (pass -MagiskApk or -SelfCmd with an embedded APK)." }
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
# Rooting helper: bindmount /data/downloads/.xb over /system/xbin, then bind our setuid su.
MAXSIZE=100000
MARKER_FILE="/data/downloads/.bm"
to_mount=$(getprop bst.config.bindmount)
echo "to_mount=$to_mount" > /dev/kmsg
mounted=`mountpoint -q /system/xbin && echo "1" || echo "0"`
echo "mounted=$mounted" > /dev/kmsg
FILESIZE=$(stat -c%s "$MARKER_FILE")
echo "Size of $MARKER_FILE = $FILESIZE bytes." > /dev/kmsg
if (( FILESIZE > MAXSIZE )); then
    rm $MARKER_FILE
    touch $MARKER_FILE
fi
if [ $to_mount -gt 0 ] && [ $mounted -le 0 ] && [ -d /data/downloads/.xb ]; then
    echo "Bind mounting..." > /dev/kmsg
    mount -o bind /data/downloads/.xb/ /system/xbin/ > /dev/kmsg
    echo "`date` bindmount" >> $MARKER_FILE
    if [ -f /system/etc/bsr_su ]; then
        mount -o bind /system/etc/bsr_su /system/xbin/su
        mount -o bind /system/etc/bsr_su /system/xbin/bstk/su
        echo "bsr: ungated setuid su bind-mounted" > /dev/kmsg
    fi
    /system/xbin/su --auto-daemon &
elif [ $to_mount -le 0 ] && [ $mounted -gt 0 ]; then
    for pid in `pgrep daemonsu`
    do
        kill -9 $pid
    done
    sleep 3
    echo "`date` unbindmount" >> $MARKER_FILE
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
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }
function Copy-DeviceToFile($dev,$start,$len,$out){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $fs.Position=$start; $o=[System.IO.File]::Open($out,'Create','Write','None'); try{ $buf=New-Object byte[] (16MB); [long]$rem=$len; while($rem -gt 0){ $w=[int][Math]::Min([long]$buf.Length,$rem); $n=$fs.Read($buf,0,$w); if($n -le 0){break}; $o.Write($buf,0,$n); $rem-=$n } } finally{ $o.Close() } } finally{ $fs.Close() } }
function Copy-FileToDevice($inf,$dev,$start){ $fs=[System.IO.File]::Open($dev,'Open','ReadWrite','ReadWrite'); try{ $fs.Position=$start; $i=[System.IO.File]::OpenRead($inf); try{ $buf=New-Object byte[] (16MB); while(($n=$i.Read($buf,0,$buf.Length)) -gt 0){ if(($n%512)-ne 0){$n+=(512-($n%512))}; $fs.Write($buf,0,$n) }; $fs.Flush() } finally{ $i.Close() } } finally{ $fs.Close() } }

function Kill-BlueStacks {
    # Kill ONLY BlueStacks-owned processes (names start with HD-, Bstk, or BlueStacks):
    # HD-Player/Adb/Agent/MultiInstanceManager/CommonLoader, BstkSVC, BlueStacksHelper/Web/Services...
    # This is scoped (no unrelated services are touched) and complete (BstkSVC holds the .bstk/conf
    # lock, so it MUST go or config edits won't persist -- verified). BlueStacks 5 has no auto-restart
    # Windows service, so killing the processes is sufficient.
    $killed = Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match '^(HD-|Bstk|BlueStacks)' }
    if($killed){ $killed | Stop-Process -Force -EA SilentlyContinue }
    Start-Sleep 4
}

# Run a debugfs command-list against an ext4 image file; returns combined output.
function Invoke-Debugfs($img,[string[]]$cmds){
    if(-not $Debugfs -or -not (Test-Path $Debugfs)){ throw "debugfs.exe not found (pass -Debugfs)." }
    $scr = Join-Path $env:TEMP ("bsr_work\dfs_{0}.txt" -f (Get-Random))
    New-Item -ItemType Directory -Path (Split-Path $scr) -Force | Out-Null
    Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
    $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
    $out = & $Debugfs @('-w','-f',$scr,(Fwd $img)) 2>&1 | Out-String
    $ErrorActionPreference=$eap
    Remove-Item $scr -Force -EA SilentlyContinue
    $out
}

# Attach Root.vhd, carve ext4 -> temp img, run $editScriptBlock(img), then (optionally) write back.
function With-RootVhdExt4([scriptblock]$edit,[bool]$writeBack){
    if(-not (Test-Path $Vhd)){ throw "Root.vhd not found: $Vhd" }
    $attached=$false
    try{
        Say "[*] attach $Vhd (RW)..." Cyan
        Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true
        $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Vhd -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
        if($null -eq $dn){ throw 'no disk number' }
        $tgt=$null
        foreach($p in @(Get-Partition -DiskNumber $dn | Sort-Object Offset)){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $tgt=@{Device=$d;Start=[long]0;Length=[long]$p.Size}; break } }catch{} }
        if(-not $tgt){ throw 'no ext4 partition (0xEF53) in Root.vhd' }
        Say "[*] ext4 device=$($tgt.Device) size=$([Math]::Round($tgt.Length/1GB,2))GB"
        $img=Join-Path $env:TEMP 'bsr_work\rootvhd_ext4.img'; New-Item -ItemType Directory -Path (Split-Path $img) -Force | Out-Null
        Say "[*] carve ext4 region (~1-2 min)..." Cyan
        Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img
        $ok = & $edit $img
        if($writeBack -and $ok){
            Say "[*] write modified ext4 back into Root.vhd..." Cyan
            Copy-FileToDevice $img $tgt.Device $tgt.Start
            Say "[+] Root.vhd updated." Green
        } elseif($writeBack){
            Say "[!] edit reported failure -- NOT writing back (Root.vhd unchanged)." Red
        }
        Remove-Item $img -Force -EA SilentlyContinue
        return $ok
    } finally {
        if($attached){ try{ Dismount-DiskImage -ImagePath $Vhd | Out-Null; Say "[*] detached Root.vhd" }catch{ Say 'WARN detach failed' Red } }
    }
}

# Extract the canonical /data/adb/magisk + /system/etc/init/magisk file set from a Magisk APK.
function Extract-MagiskApk($apk,$dst){
    if(-not (Test-Path $apk)){ throw "Magisk APK not found: $apk" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if(Test-Path $dst){ Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $zip=[System.IO.Compression.ZipFile]::OpenRead($apk)
    try{
        # lib name -> output name (x86_64 set, plus magisk32 from x86)
        $map=@{
            'lib/x86_64/libbusybox.so'='busybox'; 'lib/x86_64/libmagisk64.so'='magisk64';
            'lib/x86_64/libmagiskboot.so'='magiskboot'; 'lib/x86_64/libmagiskinit.so'='magiskinit';
            'lib/x86_64/libmagiskpolicy.so'='magiskpolicy'; 'lib/x86/libmagisk32.so'='magisk32';
            'assets/stub.apk'='stub.apk'; 'assets/util_functions.sh'='util_functions.sh';
            'assets/boot_patch.sh'='boot_patch.sh'; 'assets/addon.d.sh'='addon.d.sh'
        }
        foreach($e in $zip.Entries){
            if($map.ContainsKey($e.FullName)){
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dst $map[$e.FullName]), $true)
            }
        }
    } finally { $zip.Dispose() }
    $need=@('busybox','magisk32','magisk64','magiskboot','magiskinit','magiskpolicy','stub.apk','util_functions.sh','boot_patch.sh','addon.d.sh')
    $missing = $need | Where-Object { -not (Test-Path (Join-Path $dst $_)) }
    if($missing){ throw "APK missing expected members: $($missing -join ', ')" }
    Say "[+] extracted Magisk databin ($($need.Count) files) from APK." Green
}

# ---- conf edit: set a per-instance key (modify-only, UTF-8 no BOM) ----
function Set-ConfKey($key,$val){
    if(-not (Test-Path $Conf)){ throw "conf not found: $Conf" }
    $raw=[System.IO.File]::ReadAllText($Conf)
    $pat = [regex]::Escape($key) + '="\d"'
    if($raw -notmatch $pat){ Say "[~] conf key $key not present; leaving conf unchanged." Yellow; return }
    $new=[regex]::Replace($raw, $pat, ($key + '="' + $val + '"'))
    if($new -ne $raw){ [System.IO.File]::WriteAllText($Conf,$new,(New-Object System.Text.UTF8Encoding($false))); Say "[+] conf: $key=$val" Green }
    else { Say "[*] conf: $key already $val" DarkGray }
}

# ---- adb helpers ----
function Adb([string[]]$a){ (& $Adb @a 2>&1 | Out-String) }
# Candidate adb ports for THIS instance, in priority order, from BlueStacks' OWN conf -- NEVER hardcoded
# to 5555. status.adb_port is the runtime port BlueStacks writes on boot; adb_port is the Multi-Instance
# Manager's assigned port (clones get 5585/5595/...); 5555 is only a last-resort fallback. Boot-And-Wait
# tries each AND verifies identity, so a stale status value or a foreign emulator on a port can't mislead.
function Get-AdbPortCandidates{
    $cands=New-Object System.Collections.Generic.List[string]
    if($Conf -and (Test-Path $Conf)){
        try{
            $ct=[IO.File]::ReadAllText($Conf); $esc=[regex]::Escape($Instance)
            foreach($key in @('status\.adb_port','adb_port')){
                $m=[regex]::Match($ct,'(?im)^\s*bst\.instance\.'+$esc+'\.'+$key+'\s*=\s*"?(\d+)"?')
                if($m.Success){ [void]$cands.Add($m.Groups[1].Value) }
            }
        }catch{}
    }
    [void]$cands.Add('5555')
    $seen=@{}; $out=@(); foreach($c in $cands){ if(-not $seen.ContainsKey($c)){ $seen[$c]=$true; $out+=$c } }
    ,$out
}
# Is the device on $serial actually a BlueStacks instance (vs a foreign emulator squatting the port)?
# BlueStacks exposes bst.* props + the bst service manager (init.svc.bstsvcmgrtest); a stock AVD has neither.
function Is-BlueStacks([string]$serial){
    $all=(& $Adb @('-s',$serial,'shell','getprop') 2>&1 | Out-String)
    return ($all -match '\[(bst\.|init\.svc\.bst|ro\.bst)')
}
$Script:AdbSerial = $null   # the pinned 127.0.0.1:<port> transport for the current boot
function AdbConnect{ $s = if($Script:AdbSerial){$Script:AdbSerial}else{"127.0.0.1:$((Get-AdbPortCandidates)[0])"}; & $Adb @('connect',$s) *>$null }
# False if adb reported a transient transport/device error (common while a freshly-booted instance
# is still restarting adbd). Such output should be retried after a reconnect, not trusted.
function AdbOk([string]$o){ -not ($o -match "device '.*' not found" -or $o -match 'device .* not found' -or $o -match 'no devices/emulators found' -or $o -match 'device offline' -or $o -match 'error: closed') }
# Run an adb shell command, reconnecting + retrying on a dropped transport.
function AdbShellRetry([string]$serial,[string]$cmd,[int]$tries=6){
    $o=''
    for($k=0;$k -lt $tries;$k++){
        $o=(& $Adb @('-s',$serial,'shell',$cmd) 2>&1 | Out-String)
        if(AdbOk $o){ return $o }
        Start-Sleep 3; & $Adb @('start-server') *>$null; AdbConnect
    }
    $o
}
# Run any adb subcommand (install/push/...) with the same reconnect-on-drop retry.
function AdbTry([string[]]$a,[int]$tries=4){
    $o=''
    for($k=0;$k -lt $tries;$k++){
        $o=(& $Adb @($a) 2>&1 | Out-String)
        if(AdbOk $o){ return $o }
        Start-Sleep 3; & $Adb @('start-server') *>$null; AdbConnect
    }
    $o
}
function AdbSu([string]$serial,[string]$cmd){ AdbShellRetry $serial "/system/xbin/su -c '$cmd'" }
function Boot-And-Wait([int]$timeoutSec=300){
    Say "[*] launching instance $Instance ..." Cyan
    Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null
    # Find the adb endpoint from BlueStacks' OWN per-instance conf ports (re-read each pass: BlueStacks
    # writes the actual bound port during boot). Try each candidate, require boot_completed=1, and confirm
    # it is really our BlueStacks instance -- so neither a stale port nor a foreign emulator on 5555 can
    # mislead us. We pin to that 127.0.0.1:<port> transport (never the transient emulator-XXXX serial).
    $serial=$null; $fallback=$null
    for($i=0;$i -lt ($timeoutSec/3) -and -not $serial;$i++){
        Start-Sleep 3; & $Adb @('start-server') *>$null
        foreach($port in (Get-AdbPortCandidates)){
            $cand="127.0.0.1:$port"
            & $Adb @('connect',$cand) *>$null
            # boot_completed must be EXACTLY "1" on its own line -- a "device '...:port' not found" error
            # contains the port digits and would false-positive a naive -match '1'.
            $out=(& $Adb @('-s',$cand,'shell','getprop','sys.boot_completed') 2>&1 | Out-String)
            if(-not (($out -split "`n" | ForEach-Object { $_.Trim() }) -contains '1')){ continue }
            if(Is-BlueStacks $cand){ $serial=$cand; break }      # confirmed: our instance
            elseif(-not $fallback){ $fallback=$cand }            # booted, but identity unconfirmed
        }
    }
    if(-not $serial -and $fallback){ Say "[~] using booted device $fallback (BlueStacks marker not seen)." Yellow; $serial=$fallback }
    if(-not $serial){ throw "instance '$Instance' did not boot / become adb-reachable within $timeoutSec s" }
    $Script:AdbSerial=$serial
    # Stabilize: a freshly-booted instance (esp. a first boot) restarts adbd a few times, which drops the
    # transport -> the next call fails with "device '127.0.0.1:<port>' not found". Wait until a plain shell
    # is reliably reachable (3 consecutive hits, reconnecting each time) before handing the serial to callers.
    $stable=0
    for($s=0;$s -lt 30 -and $stable -lt 3;$s++){
        AdbConnect
        $t=(& $Adb @('-s',$serial,'shell','echo BSR_RDY') 2>&1 | Out-String)
        if($t -match 'BSR_RDY'){ $stable++ } else { $stable=0; Start-Sleep 3 }
    }
    Say "[+] booted: $serial" Green
    Start-Sleep 4
    $serial
}

# ====================================================================
#  ACTIONS
# ====================================================================
function Do-Prep {
    Ensure-MagiskApk; Ensure-BsrSu; Ensure-Debugfs
    Say '==== PREP (offline) ====' Cyan
    Kill-BlueStacks

    # 0) one-time pristine safety backup (so Undo can fully restore)
    $bak = "$Vhd.bsrbak"
    if(-not $NoBackup -and -not (Test-Path $bak)){
        try { Say "[*] one-time pristine backup -> $bak ..." ; Copy-Item -LiteralPath $Vhd -Destination $bak -Force; Say "[+] backup done." Green }
        catch { Say "[~] could not create backup: $($_.Exception.Message)" Yellow }
    } else { Say "[*] pristine backup present (or -NoBackup): $bak" DarkGray }

    # 1) HD-Player anti-tamper patch (proven, via engine; engine Patch requires -Exe)
    Say '[*] HD-Player anti-tamper patch (engine Patch)...'
    $hdp = Join-Path $Install 'HD-Player.exe'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Action Patch -Exe $hdp 2>&1 | ForEach-Object { Say "    $_" DarkGray }

    # 2) conf: emulator root ON (so the bootstrap bindmount runs) + adb on
    Set-ConfKey "bst.instance.$Instance.enable_root_access" 1
    Set-ConfKey "bst.enable_adb_access" 1

    # 3) stage files
    $stage = Join-Path $env:TEMP 'bsr_work\databin'
    Extract-MagiskApk $MagiskApk $stage
    $tmpDir = Join-Path $env:TEMP 'bsr_work\sysfiles'; New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bootanim.rc'), $BOOTANIM_RC, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'config'),      $MAGISK_CONFIG, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bindmount'),   $BINDMOUNT_MOD, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bsr_boot.sh'), $BSR_BOOT_SH,   (New-Object System.Text.UTF8Encoding($false)))

    # 4) ONE offline carve: Magisk /system files + bootanim hijack + bootstrap su + hijacked bindmount
    $ok = With-RootVhdExt4 {
        param($img)
        $sysM = Fwd (Join-Path $stage 'magisk32'); $null=$sysM
        $cmds = @(
            'mkdir /android','mkdir /android/system','mkdir /android/system/etc','mkdir /android/system/etc/init',
            'mkdir /android/system/etc/init/magisk','cd /android/system/etc/init/magisk'
        )
        foreach($f in 'magisk32','magisk64','magiskinit','magiskpolicy','stub.apk'){
            $cmds += @("rm $f","write $(Fwd (Join-Path $stage $f)) $f","sif $f mode 0100700","sif $f uid 0","sif $f gid 0","sif $f links_count 1")
        }
        $cmds += @("rm config","write $(Fwd (Join-Path $tmpDir 'config')) config","sif config mode 0100700","sif config uid 0","sif config gid 0","sif config links_count 1")
        # per-instance gate script (root-owned 0700, alongside the magisk binaries)
        $cmds += @("rm bsr_boot.sh","write $(Fwd (Join-Path $tmpDir 'bsr_boot.sh')) bsr_boot.sh","sif bsr_boot.sh mode 0100700","sif bsr_boot.sh uid 0","sif bsr_boot.sh gid 0","sif bsr_boot.sh links_count 1")
        # hijack bootanim.rc (system:system 0664) -- now the GATED version
        $cmds += @('cd /android/system/etc/init','rm bootanim.rc',"write $(Fwd (Join-Path $tmpDir 'bootanim.rc')) bootanim.rc",'sif bootanim.rc mode 0100664','sif bootanim.rc uid 1000','sif bootanim.rc gid 1000','sif bootanim.rc links_count 1')
        # bootstrap su template (setuid root)
        $cmds += @('cd /android/system/etc','rm bsr_su',"write $(Fwd $BsrSu) bsr_su",'sif bsr_su mode 0106755','sif bsr_su uid 0','sif bsr_su gid 0','sif bsr_su links_count 1')
        # hijacked bindmount
        $cmds += @('cd /android/system/bin','rm bindmount',"write $(Fwd (Join-Path $tmpDir 'bindmount')) bindmount",'sif bindmount mode 0100755','sif bindmount uid 0','sif bindmount gid 0','sif bindmount links_count 1')
        # verify
        $cmds += @('stat /android/system/etc/init/magisk/magisk64','stat /android/system/etc/init/bootanim.rc','stat /android/system/etc/bsr_su','stat /android/system/bin/bindmount')
        $out = Invoke-Debugfs $img $cmds
        Say $out DarkGray
        $good = ($out -match '(?s)bsr_su.*?Inode:\s*\d') -and ($out -match '(?s)bootanim\.rc.*?Inode:\s*\d') -and ($out -match '(?s)magisk64.*?Inode:\s*\d')
        if(-not $good){ Say '[!] prep verify FAILED' Red }
        return $good
    } $true
    if(-not $ok){ throw "Prep failed (Root.vhd not modified)." }
    Say '[+] PREP complete.' Green
}

function Do-Data {
    Ensure-MagiskApk; Ensure-Debugfs
    Say '==== DATA (online, bootstrap su) ====' Cyan
    $stage = Join-Path $env:TEMP 'bsr_work\databin'
    if(-not (Test-Path (Join-Path $stage 'busybox'))){ Extract-MagiskApk $MagiskApk $stage }
    $serial = Boot-And-Wait
    # sanity: bootstrap su works
    $id = (AdbSu $serial 'id').Trim()
    if($id -notmatch 'uid=0'){ throw "bootstrap su not root (got '$id'). Prep/patch/conf issue." }
    Say "[+] bootstrap su OK: $id" Green
    # install Magisk manager app
    Say '[*] adb install Magisk APK...'
    Say ("    " + (AdbTry @('-s',$serial,'install','-r',$MagiskApk)).Trim()) DarkGray
    # push databin to /data/local/tmp then su-copy into /data/adb/magisk
    AdbTry @('-s',$serial,'shell','rm -rf /data/local/tmp/bsrmbin; mkdir -p /data/local/tmp/bsrmbin') | Out-Null
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
rm -rf /data/local/tmp/bsrmbin
sync
echo BSR_DATA_OK
'@ -replace "`r`n","`n"
    $script | Set-Content -LiteralPath (Join-Path $env:TEMP 'bsr_work\datapop.sh') -Encoding ascii -NoNewline
    AdbTry @('-s',$serial,'push',(Fwd (Join-Path $env:TEMP 'bsr_work\datapop.sh')),'/data/local/tmp/bsr_pop.sh') | Out-Null
    $r = AdbSu $serial 'sh /data/local/tmp/bsr_pop.sh; rm -f /data/local/tmp/bsr_pop.sh'
    Say $r DarkGray
    if($r -notmatch 'BSR_DATA_OK'){ throw "/data/adb/magisk populate failed." }
    Say '[+] /data/adb/magisk populated. Rebooting so magiskd initializes (env now complete)...' Green
    & $Adb @('-s',$serial,'shell','sync') *>$null; Start-Sleep 2; Kill-BlueStacks

    # second boot: magiskd should now start; bsr_su is still present so we can set the grant policy.
    $serial = Boot-And-Wait
    Start-Sleep 5
    $mg = (AdbSu $serial 'ps -A | grep -c magiskd').Trim()
    Say "    magiskd processes: $mg" $(if($mg -match '[1-9]'){'Green'}else{'Yellow'})
    # grant policy (allow shell uid 2000). The SQL has parens, which break through nested su -c '...'
    # quoting -> push it as a script FILE and run that (robust, same pattern as the populate step).
    $polSh = 'magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,0,0)"' + "`n" + 'echo POL_RC=$?' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'bsr_work\polset.sh'), $polSh, (New-Object System.Text.UTF8Encoding($false)))
    AdbTry @('-s',$serial,'push',(Fwd (Join-Path $env:TEMP 'bsr_work\polset.sh')),'/data/local/tmp/bsr_pol.sh') | Out-Null
    $pol = AdbSu $serial 'sh /data/local/tmp/bsr_pol.sh; rm -f /data/local/tmp/bsr_pol.sh'
    Say "    policy: $(($pol -replace "`r?`n",' ').Trim())" DarkGray
    $mc = (AdbSu $serial 'magisk -c').Trim(); Say "    magisk -c: $mc"
    AdbSu $serial 'sync' | Out-Null
    if($mg -notmatch '[1-9]'){ Say '[!] magiskd not detected after populate+reboot -- check /cache/magisk.log' Yellow }
    Say '[+] DATA complete (/data/adb/magisk populated, magiskd up, policy set).' Green
    & $Adb @('-s',$serial,'shell','sync') *>$null; Start-Sleep 2; Kill-BlueStacks
}

function Do-Clean {
    Ensure-Debugfs
    Say '==== CLEAN (offline: erase bootstrap su, restore stock bindmount) ====' Cyan
    Kill-BlueStacks
    $tmpDir = Join-Path $env:TEMP 'bsr_work\sysfiles'; New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmpDir 'bindmount.orig'), $BINDMOUNT_ORIG, (New-Object System.Text.UTF8Encoding($false)))
    $ok = With-RootVhdExt4 {
        param($img)
        $cmds = @(
            'cd /android/system/etc','rm bsr_su',
            'cd /android/system/bin','rm bindmount',"write $(Fwd (Join-Path $tmpDir 'bindmount.orig')) bindmount",
            'sif bindmount mode 0100775','sif bindmount uid 1000','sif bindmount gid 1000','sif bindmount links_count 1',
            'stat /android/system/bin/bindmount','stat /android/system/etc/bsr_su'
        )
        $out = Invoke-Debugfs $img $cmds
        Say $out DarkGray
        # stock bindmount is ~1339B; accept the byte-exact range (template is 1339, tolerate +/-2)
        $bmOk = ($out -match '(?s)/android/system/bin/bindmount[\s\S]*?Size:\s*(133[0-9]|134[01])')
        $suGone = ($out -match 'bsr_su:\s*File not found') -or ($out -match 'File not found by ext2_lookup')
        if(-not $bmOk){ Say '[!] stock bindmount not detected after restore' Red }
        return ($bmOk -and $suGone)
    } $true
    if(-not $ok){ throw "Clean failed." }
    Say '[+] CLEAN complete (bsr_su removed, stock bindmount restored).' Green
}

function Do-Finalize {
    Say '==== FINALIZE (emulator root OFF + shareable master) ====' Cyan
    Set-ConfKey "bst.instance.$Instance.enable_root_access" 0
    # Ensure the shared master Root.vhd + fastboot.vdi are Readonly so MULTIPLE instances can attach
    # them at once (type="Normal" is exclusive -> a 2nd instance fails with VBOX_E_INVALID_OBJECT_STATE).
    # Data.vhdx stays Normal (per-instance, writable). This is the factory layout.
    $bstk = Join-Path (Split-Path $Vhd) ("$Instance.bstk")
    if(Test-Path $bstk){
        $t=[System.IO.File]::ReadAllText($bstk); $o=$t
        $t=[regex]::Replace($t,'(location="Root\.vhd"[^>]*?type=")Normal(")','${1}Readonly${2}')
        $t=[regex]::Replace($t,'(location="fastboot\.vdi"[^>]*?type=")Normal(")','${1}Readonly${2}')
        if($t -ne $o){ [System.IO.File]::WriteAllText($bstk,$t); Say '[+] master Root.vhd + fastboot.vdi set Readonly (multi-instance shareable).' Green }
        else { Say '[*] master disks already Readonly (or not declared in this .bstk).' DarkGray }
    }
    Say '[+] FINALIZE complete.' Green
}

function Do-Verify {
    Say '==== VERIFY (cold boot) ====' Cyan
    $serial = Boot-And-Wait
    $id  = (& $Adb @('-s',$serial,'shell','su -c id') 2>&1 | Out-String).Trim()
    $whi = (& $Adb @('-s',$serial,'shell','readlink /system/bin/su') 2>&1 | Out-String).Trim()
    $xb  = (& $Adb @('-s',$serial,'shell','su -c "ls /system/xbin/su 2>&1"') 2>&1 | Out-String).Trim()
    $sweep = (& $Adb @('-s',$serial,'shell',"su -c `"find /system /data/adb /data/downloads -type f -size 4968c 2>/dev/null | while read f; do [ \`"`$(sha256sum `$f|cut -d' ' -f1)\`" = '$BSR_SU_SHA' ] && echo TRACE:`$f; done; echo SWEEPDONE`"") 2>&1 | Out-String)
    Say ("  su -c id            : {0}" -f $id) $(if($id -match 'uid=0'){'Green'}else{'Red'})
    Say ("  /system/bin/su ->   : {0}" -f $whi)
    Say ("  /system/xbin/su     : {0}  (want: not found)" -f $xb)
    Say ("  bsr_su sweep        : {0}" -f ($sweep -replace "`r?`n",' ').Trim())
    if($id -match 'uid=0' -and $whi -match 'magisk' -and $sweep -notmatch 'TRACE:'){ Say '[+] VERIFY PASS: Magisk is the sole root; no bsr_su traces.' Green }
    else { Say '[!] VERIFY: review the above.' Yellow }
}

function Do-Undo {
    # PER-INSTANCE unroot (multi-instance safe): just drop THIS instance's root flag + /data Magisk
    # state + app. The shared master /system and HD-Player patch are LEFT INTACT so any OTHER rooted
    # instances keep working. Use -Full to also scrub the master + un-patch (unroots ALL instances).
    Say "==== UNDO ($Instance) ====" Cyan
    Kill-BlueStacks; Start-Sleep 2
    if(-not (Test-Path $Player)){ Say "[!] HD-Player.exe not found at '$Player'." Red; return }
    try {
        $serial = Boot-And-Wait 240
        & $Adb @('-s',$serial,'uninstall','io.github.huskydg.magisk') 2>&1 | Out-Null
        # while the flag is still present this instance has working Magisk root, so its su can wipe /data/adb
        $rm = 'rm -f /data/adb/.bsr_root; rm -rf /data/adb/magisk /data/adb/magisk.db /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d 2>/dev/null; sync; echo BSR_RM_OK'
        $o1 = (& $Adb @('-s',$serial,'shell',"su -c '$rm'") 2>&1 | Out-String)
        if($o1 -notmatch 'BSR_RM_OK'){ AdbSu $serial $rm | Out-Null }
        & $Adb @('-s',$serial,'shell','sync') *>$null; Start-Sleep 2
        Say "[+] $Instance unrooted (flag + /data Magisk state removed, app uninstalled)." Green
    } catch { Say "[~] could not boot to unroot /data: $($_.Exception.Message)" Yellow }
    Kill-BlueStacks
    Set-ConfKey "bst.instance.$Instance.enable_root_access" 0

    if($Full){
        Say '[*] -Full: scrubbing shared master + un-patching HD-Player (unroots ALL instances)...' Yellow
        $bak = "$Vhd.bsrbak"
        if(Test-Path $bak){ Copy-Item -LiteralPath $bak -Destination $Vhd -Force; Say '[+] master Root.vhd restored to factory.' Green }
        else { Say '[~] no Root.vhd.bsrbak; master left as-is (gated Magisk stays dormant).' Yellow }
        $hdp = Join-Path $Install 'HD-Player.exe'
        Say '[*] un-patching HD-Player.exe (-Exe last to avoid arg-glue)...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Action Patch -Restore -Exe $hdp 2>&1 | ForEach-Object { Say "    $_" DarkGray }
        Say '[+] FULL host scrub complete (no instance rooted; HD-Player factory).' Green
    } else {
        Say "[+] UNDO complete. Shared master + HD-Player patch left intact so other rooted instances keep working." Green
        Say "    For a full host scrub (no instances rooted, HD-Player un-patched), re-run Undo with -Full." DarkGray
    }
}

# Only dispatch when run normally (-File / &). When DOT-SOURCED (. bsr_magisk.ps1) -- e.g. by the test
# suite to unit-test the resolver functions -- skip the pipeline so nothing boots or writes.
if ($MyInvocation.InvocationName -ne '.') {
    switch($Action){
        'Prep'     { Do-Prep }
        'Data'     { Do-Data }
        'Clean'    { Do-Clean }
        'Finalize' { Do-Finalize }
        'Verify'   { Do-Verify }
        'Auto'     { Do-Prep; Do-Data; Do-Clean; Do-Finalize; Do-Verify }
        'Undo'     { Do-Undo }
    }
}
