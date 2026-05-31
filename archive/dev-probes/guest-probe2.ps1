$ErrorActionPreference='Continue'
$Adb='C:\Program Files\BlueStacks_nxt\HD-Adb.exe'; $serial='emulator-5554'
function Sh($c){ (& $Adb @('-s',$serial,'shell',$c) 2>&1 | Out-String) }
function Sec($t){ Write-Host "`n===== $t =====" -ForegroundColor Cyan }
& $Adb @('start-server') *>$null

Sec 'proc/partitions (sizes of sda/sdb/...)' ; Sh 'cat /proc/partitions'
Sec 'ALL mounts' ; Sh 'cat /proc/mounts'
Sec 'fstab.rvc' ; Sh 'cat /fstab.rvc 2>/dev/null; cat /system/etc/fstab* 2>/dev/null; echo END'
Sec '/dev/block/by-name (partition labels -> devices)' ; Sh 'ls -la /dev/block/by-name/ 2>/dev/null; echo "--- platform ---"; ls -la /dev/block/platform/*/by-name/ 2>/dev/null; echo END'
Sec 'top of /system' ; Sh 'ls -la /system/ 2>/dev/null'
Sec '/system/xbin contents (the rw sdb1 partition)' ; Sh 'ls -la /system/xbin/ 2>/dev/null'
Sec '/system/xbin/bstk' ; Sh 'ls -la /system/xbin/bstk/ 2>/dev/null; echo END'
Sec 'is there an /android dir anywhere mounted?' ; Sh 'grep -i android /proc/mounts; ls -ld /android 2>/dev/null; echo END'
Sec 'why does su deny? strace-ish: run su, check logcat' ; Sh 'su -c id; echo "rc=$?"; logcat -d -t 40 2>/dev/null | grep -iE "su|root|denied|bstk" | tail -20; echo END'
Sec 'props controlling root' ; Sh 'getprop | grep -iE "root|bstk|debuggable|secure|adb" ; echo END'
Sec 'what is /system/xbin/su (strings: gate hints)' ; Sh 'strings /system/xbin/su 2>/dev/null | grep -iE "enable_root|denied|grant|bstk|property|persist|allow" | head -20; echo END'
