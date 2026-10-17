#!/system/bin/sh
# crDroid garnet RAM Fix - uninstall
# Remove our DeviceConfig overrides so the system returns to its defaults,
# then delete the persistent directory. (resetprop changes are runtime-only and
# vanish at reboot; vm sysctls are reset by the vendor scripts / next boot.)

PERSIST_DIR=/data/adb/crdroid-garnet-ram-fix
DC=/system/bin/device_config

if command -v "$DC" >/dev/null 2>&1 || [ -x "$DC" ]; then
    # only keys this module manages (the ROM's own
    # persist.device_config.lmkd_native.thrashing_limit_critical is left alone)
    for key in compact_full_oom_adj compact_throttle_full_full use_compaction use_full_compaction use_recompression; do
        "$DC" delete activity_manager "$key" >/dev/null 2>&1
    done
    for key in thrashing_limit psi_partial_stall_ms psi_complete_stall_ms; do
        "$DC" delete lmkd_native "$key" >/dev/null 2>&1
    done
    # re-enable DeviceConfig sync
    "$DC" set_sync_disabled_for_tests none >/dev/null 2>&1
fi

rm -rf "$PERSIST_DIR"
exit 0
