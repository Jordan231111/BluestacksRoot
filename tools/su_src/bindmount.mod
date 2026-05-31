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
