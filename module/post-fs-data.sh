#!/system/bin/sh
# crDroid garnet RAM Fix - post-fs-data
# Runs as early as possible: make ro.lmk.medium correct before lmkd picks it up.
# Everything else is applied from service.sh (after the vendor post_boot scripts
# have written their sysctls) and kept in place by the watchdog.

MODDIR="${0%/*}"
PERSIST_DIR=/data/adb/crdroid-garnet-ram-fix
. "$MODDIR/common.sh"

load_config
[ "$CFG_FIX_LMKD" = "1" ] || exit 0

mkdir -p "$LOG_DIR"
find_resetprop
set_ro_prop ro.lmk.medium 800
exit 0
