#!/system/bin/sh
if [ -d "/data/adb" ]; then su -c "rm -rf /data/adb"; fi
if [ -d "/sbin" ]; then su -c "rm -rf /sbin"; fi
su -c "pm uninstall --user 0 io.github.huskydg.magisk"
