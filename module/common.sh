#!/system/bin/sh
# crDroid garnet RAM Fix - shared helpers (sourced by post-fs-data.sh / service.sh / action.sh)
#
# Root cause this module addresses (see CONTEXT.md):
#   1. CachedAppOptimizer "FULL" compaction (MADV_PAGEOUT) pushes cached apps into zram
#      while GBs of RAM are free, causing a permanent swap-refault loop.
#   2. Android 16 lmkd (lmkd_native) scores that refault rate as "thrashing" and kills
#      processes (LOW_MEMORY exits) even with ~6 GB free.
#   3. ro.lmk.medium=700 (AOSP default 800) extends medium-pressure kills to the
#      previously used app -> "the app I just left is killed when switching".
#   4. page-cluster=3 / swappiness=100 make every zram refault expensive.

PERSIST_DIR="${PERSIST_DIR:-/data/adb/crdroid-garnet-ram-fix}"
LOG_DIR="$PERSIST_DIR/logs"
CONFIG_FILE="$PERSIST_DIR/config.sh"
LOG_FILE="$LOG_DIR/garnetfix.log"

# resetprop / busybox live outside the default PATH on Magisk / KernelSU / APatch
PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/system/xbin:$PATH"
export PATH

# Number of settings changed in the current apply pass (used to gate side effects)
CHANGED=0

# ---------------------------------------------------------------- logging ----

log() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
    _lvl="$1"
    shift
    _line="$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*"
    echo "$_line"
    echo "$_line" >> "$LOG_FILE" 2>/dev/null
}

# Keep the log from growing forever (called on boot)
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    _sz=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' \t')
    [ -n "$_sz" ] && [ "$_sz" -gt 262144 ] || return 0
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
}

# ---------------------------------------------------------------- config -----

load_config() {
    # defaults
    CFG_DISABLE_FULL_COMPACTION=1
    CFG_DISABLE_COMPACTION=0
    CFG_FIX_LMKD=1
    CFG_FIX_VM=1
    CFG_WATCHDOG=1
    CFG_WATCHDOG_INTERVAL=60
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

# -------------------------------------------------------------- helpers ------

find_resetprop() {
    RESETPROP=""
    command -v resetprop >/dev/null 2>&1 && RESETPROP="resetprop"
    [ -z "$RESETPROP" ] && [ -x /data/adb/magisk/magisk ] && RESETPROP="/data/adb/magisk/magisk resetprop"
    [ -z "$RESETPROP" ] && [ -x /data/adb/magisk/resetprop ] && RESETPROP="/data/adb/magisk/resetprop"
    [ -z "$RESETPROP" ] && [ -x /data/adb/ksu/bin/resetprop ] && RESETPROP="/data/adb/ksu/bin/resetprop"
    [ -z "$RESETPROP" ] && [ -x /data/adb/ap/bin/resetprop ] && RESETPROP="/data/adb/ap/bin/resetprop"
    [ -z "$RESETPROP" ] && log WARN "resetprop not found (ro.* props cannot be changed)"
}

# set_sysctl <vm.page-cluster> <value> - only writes on drift
# takes the dotted sysctl(8) name, maps it to /proc/sys/<subsys>/<key>
set_sysctl() {
    _path="/proc/sys/$(echo "$1" | tr . /)"
    _want="$2"
    if [ ! -e "$_path" ]; then
        log WARN "$1 not present, skipped"
        return 1
    fi
    _cur=$(cat "$_path" 2>/dev/null)
    [ "$_cur" = "$_want" ] && return 0
    if echo "$_want" > "$_path" 2>/dev/null; then
        log INFO "$1: '${_cur:-?}' -> '$_want'"
        CHANGED=$((CHANGED + 1))
    else
        log ERROR "cannot write $_path (SELinux?)"
        return 1
    fi
}

# set_ro_prop <key> <value> - read-only prop via resetprop, only on drift
set_ro_prop() {
    _key="$1"
    _want="$2"
    _cur=$(getprop "$_key")
    [ "$_cur" = "$_want" ] && return 0
    if [ -n "$RESETPROP" ] && $RESETPROP "$_key" "$_want" >/dev/null 2>&1; then
        log INFO "$_key: '${_cur:-<unset>}' -> '$_want'"
        CHANGED=$((CHANGED + 1))
    else
        log ERROR "failed to set $_key='$_want' (stays '${_cur:-<unset>}')"
        return 1
    fi
}

# dc_put <namespace> <key> <value> - DeviceConfig, only on drift
dc_put() {
    _ns="$1"
    _key="$2"
    _want="$3"
    command -v device_config >/dev/null 2>&1 || { log ERROR "device_config not found"; return 1; }
    _cur=$(device_config get "$_ns" "$_key" 2>/dev/null)
    [ "$_cur" = "$_want" ] && return 0
    if device_config put "$_ns" "$_key" "$_want" >/dev/null 2>&1; then
        log INFO "device_config $_ns/$_key: '${_cur:-<unset>}' -> '$_want'"
        CHANGED=$((CHANGED + 1))
    else
        log ERROR "device_config put $_ns $_key failed"
        return 1
    fi
}

# ------------------------------------------------------------ the fixes -----

# Stop DeviceConfig from syncing our values away (GMS) - once per install
ensure_sync_disabled() {
    command -v device_config >/dev/null 2>&1 || return 1
    [ -f "$PERSIST_DIR/.sync_disabled" ] && return 0
    if device_config set_sync_disabled_for_tests persistent >/dev/null 2>&1; then
        log INFO "device_config sync disabled (persistent)"
        touch "$PERSIST_DIR/.sync_disabled"
    else
        log WARN "could not disable device_config sync"
    fi
}

# Fix 1: stop CachedAppOptimizer FULL (MADV_PAGEOUT) compaction churn
apply_compaction() {
    [ "$CFG_DISABLE_FULL_COMPACTION" = "1" ] || [ "$CFG_DISABLE_COMPACTION" = "1" ] || return 0
    ensure_sync_disabled
    if [ "$CFG_DISABLE_COMPACTION" = "1" ]; then
        # hard mode: no compaction at all
        dc_put activity_manager use_compaction false
        dc_put activity_manager use_full_compaction false
        dc_put activity_manager use_recompression false
    else
        # gentle: FULL compaction effectively off for cached apps (adj 900-999),
        # throttle the remaining FULL events to at most one per 20 s
        dc_put activity_manager compact_full_oom_adj 999
        dc_put activity_manager compact_throttle_full_full 20000
    fi
}

# Fix 2: sane lmkd kill depth + tolerances
apply_lmkd() {
    [ "$CFG_FIX_LMKD" = "1" ] || return 0
    _before=$CHANGED
    ensure_sync_disabled
    # AOSP default; 700 = PREVIOUS_APP_ADJ (the app you just left becomes killable)
    set_ro_prop ro.lmk.medium 800
    # stop "thrashing" kills while GBs of RAM are free (refaults != pressure)
    dc_put lmkd_native thrashing_limit 400
    dc_put lmkd_native psi_partial_stall_ms 150
    dc_put lmkd_native psi_complete_stall_ms 1500
    if [ "$CHANGED" -gt "$_before" ]; then
        setprop lmkd.reinit 1 >/dev/null 2>&1 && log INFO "lmkd.reinit triggered"
    fi
}

# Fix 3: make zram refaults cheap (matches vendor intent: init.qti.kernel.sh writes
# page-cluster 0; init.kernel.post_boot-parrot.sh garnet block wants a lower
# swappiness than the generic 100 - both are broken/overridden on garnet_global)
apply_vm() {
    [ "$CFG_FIX_VM" = "1" ] || return 0
    set_sysctl vm.page-cluster 0
    set_sysctl vm.swappiness 60
}

apply_all() {
    find_resetprop
    apply_compaction
    apply_lmkd
    apply_vm
}

# ---------------------------------------------------------------- status -----

print_status() {
    echo "  vm.page-cluster                     = $(cat /proc/sys/vm/page-cluster 2>/dev/null)"
    echo "  vm.swappiness                       = $(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "  ro.lmk.medium                       = $(getprop ro.lmk.medium)"
    echo "  lmkd.reinit                         = $(getprop lmkd.reinit)"
    echo "  activity_manager/compact_full_oom_adj    = $(device_config get activity_manager compact_full_oom_adj 2>/dev/null)"
    echo "  activity_manager/compact_throttle_full_full = $(device_config get activity_manager compact_throttle_full_full 2>/dev/null)"
    echo "  activity_manager/use_compaction          = $(device_config get activity_manager use_compaction 2>/dev/null)"
    echo "  lmkd_native/thrashing_limit         = $(device_config get lmkd_native thrashing_limit 2>/dev/null)"
    echo "  lmkd_native/psi_partial_stall_ms    = $(device_config get lmkd_native psi_partial_stall_ms 2>/dev/null)"
    echo "  lmkd_native/psi_complete_stall_ms   = $(device_config get lmkd_native psi_complete_stall_ms 2>/dev/null)"
}
