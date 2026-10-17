#!/system/bin/sh
# crDroid garnet RAM Fix - late_start service
#
# Applies the fixes AFTER the vendor post-boot scripts (init.kernel.post_boot.sh,
# init.qti.kernel.sh) have done their writes, then keeps them in place with a
# lightweight watchdog (something resets vm.page-cluster back to 3 on this device,
# and the vendor scripts would otherwise restore swappiness=100).

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

load_config
mkdir -p "$LOG_DIR"
trim_log

VER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
log INFO "---- crdroid-garnet-ram-fix $VER service start ----"

# ---- wait for boot ----------------------------------------------------------

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
    sleep 1
    i=$((i + 1))
done

# ---- wait for the vendor kernel post-boot scripts to finish -----------------
# They write zram/swappiness/min_free_kbytes/page-cluster; applying before them
# would get overwritten.

for svc in kernel-post-boot kernel-boot post-boot; do
    i=0
    while [ "$(getprop init.svc.$svc)" = "running" ] && [ "$i" -lt 90 ]; do
        sleep 1
        i=$((i + 1))
    done
done

# small grace period so the last writes of those scripts have settled
sleep 5

# ---- apply ------------------------------------------------------------------

apply_all
log INFO "initial apply done ($CHANGED setting(s) changed)"

# ---- watchdog ---------------------------------------------------------------
# Setters only write on drift, so a steady-state pass is a handful of reads.
# Covers the unresolved "who resets page-cluster to 3" and any ROM/vendor
# component that reapplies its own lmkd/compaction config later in the boot.

if [ "$CFG_WATCHDOG" = "1" ]; then
    interval=$CFG_WATCHDOG_INTERVAL
    [ -n "$interval" ] || interval=60
    log INFO "watchdog started (every ${interval}s)"
    (
        while :; do
            sleep "$interval"
            load_config
            [ "$CFG_WATCHDOG" = "1" ] || break
            apply_all
        done
    ) >/dev/null 2>&1 &
fi

log INFO "service.sh finished"
exit 0
