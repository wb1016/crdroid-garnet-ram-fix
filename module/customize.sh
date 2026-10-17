#!/system/bin/sh
# crDroid garnet RAM Fix - installer

ui_print "****************************************"
ui_print "  crDroid garnet RAM Fix"
ui_print "  stop phantom LMK kills on garnet"
ui_print "****************************************"
ui_print ""

# abort in recovery
$BOOTMODE || abort "[!] Please install from the root manager (not recovery)"

ui_print "- Module Version: $(grep_prop version $MODPATH/module.prop)"
ui_print "- Device Brand:   $(getprop ro.product.brand)"
ui_print "- Device Model:   $(getprop ro.product.model)"
ui_print "- Device:         $(getprop ro.product.device) ($(getprop ro.product.name))"
ui_print "- Android:        $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
ui_print "- Kernel:         $(uname -r)"
ui_print "- Root:           $( [ "$KSU" = "true" ] && echo "KernelSU" ; [ "$APATCH" = "true" ] && echo "APatch" ; command -v magisk >/dev/null 2>&1 && echo "Magisk" )"
ui_print ""

device="$(getprop ro.product.device)"
if [ "$device" != "garnet" ]; then
    ui_print "[!] This module is tuned for Redmi Note 13 Pro 5G (garnet)."
    ui_print "[!] Detected device: '$device'. The fixes are generic and safe,"
    ui_print "    but they were not validated on this device. Continuing."
    ui_print ""
fi

# ---------------------------------------------------------------- config -----

ui_print "[*] Preparing config"
persist_dir="/data/adb/crdroid-garnet-ram-fix"
config_file="$persist_dir/config.sh"
mkdir -p "$persist_dir/logs"

if [ ! -f "$config_file" ]; then
    cat > "$config_file" <<'EOF'
# crDroid garnet RAM Fix configuration
# Edit (0 = off, 1 = on), then reboot - or press the module's Action button
# to re-apply immediately.

# 1 = stop CachedAppOptimizer FULL (MADV_PAGEOUT) compaction of cached apps.
#     This is the root cause: cached apps get paged to zram while GBs of RAM are
#     free, background wakes refault them in a loop, and lmkd scores that loop as
#     "thrashing" and kills apps (reason=LOW_MEMORY with ~6 GB free).
CFG_DISABLE_FULL_COMPACTION=1

# 1 = disable ALL app compaction (use_compaction false). Harsh; only enable if
#     the churn persists with the gentle fix above. Overrides the setting above.
CFG_DISABLE_COMPACTION=0

# 1 = restore sane lmkd kill depth & tolerances:
#     ro.lmk.medium 800 (AOSP default; the ROM ships 700 = PREVIOUS_APP_ADJ,
#     which is why "the app I just left" gets killed when switching)
#     lmkd_native: thrashing_limit 400, psi_partial_stall_ms 150,
#     psi_complete_stall_ms 900 (tolerate zram refaults instead of killing;
#     stall values are capped at 1000 = the PSI window lmkd uses)
CFG_FIX_LMKD=1

# 1 = cheap zram refaults: vm.page-cluster=0 (the vendor script intends this but
#     something resets it to 3, amplifying every refault 8x) and vm.swappiness=60
#     (ROM uses 100, the garnet block wants 120 - both are wrong for this bug)
CFG_FIX_VM=1

# 1 = watchdog: re-apply any setting that gets reset (runs every
#     CFG_WATCHDOG_INTERVAL seconds, reads only while values are stable)
CFG_WATCHDOG=1
CFG_WATCHDOG_INTERVAL=60
EOF
    ui_print "[i] Created default config: $config_file"
else
    ui_print "[i] Keeping existing config: $config_file"
fi

# ------------------------------------------------------------ permissions ----

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/post-fs-data.sh 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

ui_print ""
ui_print "[✓] Installed. Reboot to apply."
ui_print "[i] Fixes applied at every boot:"
ui_print "    - ro.lmk.medium 700 -> 800 (stop killing the previous app)"
ui_print "    - lmkd_native thrashing/PSI tolerances (stop kills with free RAM)"
ui_print "    - stop FULL compaction churn (cached apps stay in RAM)"
ui_print "    - vm.page-cluster=0, vm.swappiness=60 (cheap zram refaults)"
ui_print "[i] Verify after a day of use: action button, or"
ui_print "    /data/adb/crdroid-garnet-ram-fix/logs/garnetfix.log"
ui_print ""
