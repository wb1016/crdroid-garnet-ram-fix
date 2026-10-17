#!/system/bin/sh
# crDroid garnet RAM Fix - action (run from the root manager's "Action" button)
# Shows the effective values and re-applies the fixes immediately.

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

load_config
mkdir -p "$LOG_DIR"

echo "=============================================="
echo " crDroid garnet RAM Fix - status & re-apply"
echo "=============================================="
echo
echo "[*] Effective values (before):"
print_status
echo
echo "[*] Re-applying fixes now..."
apply_all
echo
echo "[*] Effective values (after):"
print_status
echo
if [ "$CFG_WATCHDOG" = "1" ]; then
    echo "[i] Watchdog: ON (every ${CFG_WATCHDOG_INTERVAL}s, keeps values in place)"
else
    echo "[i] Watchdog: OFF"
fi
echo "[i] Config: $CONFIG_FILE"
echo "[i] Log:    $LOG_FILE"
echo "[✓] Done."
exit 0
