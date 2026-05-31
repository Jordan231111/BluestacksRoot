# Investigate the RUNNING guest: where does /system really come from, and why does su return empty.
$ErrorActionPreference = 'Continue'
$Adb='C:\Program Files\BlueStacks_nxt\HD-Adb.exe'
$serial='emulator-5554'
function Sh($c){ $o = & $Adb @('-s',$serial,'shell',$c) 2>&1; ($o | Out-String) }
function H($t){ Write-Host "`n===== $t =====" -ForegroundColor Cyan }

& $Adb @('start-server') *>$null
& $Adb @('connect','127.0.0.1:5555') *>$null

H "current id"; Sh 'id'
H "/proc/mounts (system / android / root / dataFS)"; Sh 'cat /proc/mounts | grep -iE "system|android|dataFS| / |/root|loop|dm-" '
H "top-level /"; Sh 'ls -la / 2>/dev/null'
H "is /android present in guest?"; Sh 'ls -la /android 2>/dev/null; echo "--- /android/system/xbin/su:"; ls -l /android/system/xbin/su 2>/dev/null; echo END'
H "su locations + sizes"; Sh 'for f in /system/xbin/su /system/bin/su /sbin/su /debug_ramdisk/su /system/xbin/daemonsu; do ls -l $f 2>/dev/null; done; echo END'
H "what IS /system/xbin/su (head bytes + size)"; Sh 'ls -l /system/xbin/su; toybox stat -c "%s bytes" /system/xbin/su 2>/dev/null; head -c 20 /system/xbin/su | od -An -tx1 | head -1'
H "su -c id  (capture stderr + rc)"; Sh 'su -c id 2>&1; echo "rc=$?"'
H "su 0 id (stderr+rc)"; Sh 'su 0 id 2>&1; echo "rc=$?"'
H "printf id | su (stderr+rc)"; Sh 'printf "id\n" | su 2>&1; echo "rc=$?"'
H "su help/version"; Sh 'su --help 2>&1 | head -20; echo "---v---"; su -v 2>&1; su -V 2>&1'
H "is there a su daemon / magisk?"; Sh 'ps -A 2>/dev/null | grep -iE "magisk|daemonsu|su:|superuser" ; getprop | grep -iE "root_access|magisk|su\.|service.adb.root"; echo END'
H "system mount RO/RW + backing device"; Sh 'mount | grep -E " /system "; echo "---"; cat /proc/mounts | grep -E " /system "'
H "find any 2MB su (our injected one) anywhere"; Sh 'find /system /sbin /vendor /android -name su 2>/dev/null -exec ls -l {} \; ; echo END'
