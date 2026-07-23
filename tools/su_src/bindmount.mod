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
