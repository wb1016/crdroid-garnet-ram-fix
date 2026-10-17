# crDroid garnet RAM Fix

Magisk / KernelSU / APatch module that fixes the silent background-app kills on crDroid 12.12 Redmi Note 13 Pro 5G (`garnet`). Social apps being killed in the background, notification-pinned services  dying silently, and "the app I just left is dead when I switch back", all while ~6 GB of RAM shows as free.

## Root cause (short version)

1. CachedAppOptimizer "FULL" compaction (`MADV_PAGEOUT`) pages cached apps out to
   zram while gigabytes of RAM are free (~2 GB swap used with ~7 GB available).
2. Background wakes (push notifications etc.) refault those pages → a permanent
   refault loop (`pswpin` ≈ 4200 pages/s, `workingset_refault_anon` ≈ `pswpin`,
   zero actual reclaim).
3. Android 16 `lmkd` (`lmkd_native`) scores that refault rate as "thrashing" and
   kills on thrashing / PSI-stall conditions → 605 `LOW_MEMORY` exits with free RAM.
4. `ro.lmk.medium=700` (AOSP default is 800) makes `PREVIOUS_APP_ADJ` killable at
   medium pressure → "the app I just switched away from gets killed".
5. Aggravators: `vm.page-cluster=3` (vendor intends 0; something resets it),
   `swappiness=100`, and the vendor `garnet` vs `garnet_global` product-name
   mismatch that silently disables the intended garnet tuning block.

## What the module does

Applied at boot (after the vendor post-boot scripts) and kept in place by a
watchdog, from `/data/adb/crdroid-garnet-ram-fix/`:

| Fix | Setting | Value (before → after) |
|---|---|---|
| Kill depth | `ro.lmk.medium` | 700 → 800 (AOSP default) |
| Thrashing tolerance | `lmkd_native/thrashing_limit` | 100 → 400 |
| PSI tolerance | `lmkd_native/psi_partial_stall_ms` | → 150 |
| PSI tolerance | `lmkd_native/psi_complete_stall_ms` | → 1500 |
| Stop compaction churn | `activity_manager/compact_full_oom_adj` | 900 → 999 |
| Throttle compaction | `activity_manager/compact_throttle_full_full` | → 20000 |
| Cheap zram refaults | `vm.page-cluster` | 3 → 0 |
| Less aggressive swap | `vm.swappiness` | 100 → 60 |

Also runs `device_config set_sync_disabled_for_tests persistent` so GMS config sync
cannot overwrite the values, and `setprop lmkd.reinit 1` so lmkd re-reads its
configuration.

The watchdog re-applies any setting that gets reset (default: every 60 s,
reads only while values are stable). This covers the unresolved "who resets
`vm.page-cluster` to 3" issue without having to identify the culprit.

## Install

1. Zip the module folder: `./build.sh`
2. Flash the zip from Magisk / KernelSU / APatch, reboot.
3. Optional: press the module's Action button any time to see the effective
   values and re-apply immediately.

## Configuration

`/data/adb/crdroid-garnet-ram-fix/config.sh` (created on install, editable any time):

| Key | Default | Meaning |
|---|---|---|
| `CFG_DISABLE_FULL_COMPACTION` | `1` | Stop FULL (`MADV_PAGEOUT`) compaction of cached apps |
| `CFG_DISABLE_COMPACTION` | `0` | Hard mode: `use_compaction false` (no compaction at all) |
| `CFG_FIX_LMKD` | `1` | `ro.lmk.medium` + `lmkd_native` tolerances |
| `CFG_FIX_VM` | `1` | `vm.page-cluster=0`, `vm.swappiness=60` |
| `CFG_WATCHDOG` | `1` | Keep re-applying settings if something resets them |
| `CFG_WATCHDOG_INTERVAL` | `60` | Watchdog period (seconds) |

If the gentle compaction fix is not enough, set `CFG_DISABLE_COMPACTION=1`, reboot.

## Verify

- Action button shows before/after values.
- Log: `/data/adb/crdroid-garnet-ram-fix/logs/garnetfix.log` (only logs actual changes).
- With `diag/pull_diag.sh` from this workspace, re-run the collector and check:
  - `pswpin ≈ 0` while idle, `workingset_refault_anon` no longer tracks `pswpin`
  - `am_compact FULL` events stop targeting active apps
  - no new `reason=3 (LOW_MEMORY)` entries in `dumpsys/exit_info.txt`
  - `page-cluster=0`, `swappiness=60`, `ro.lmk.medium=800` in the sysctl/prop dumps

## Uninstall

`uninstall.sh` deletes the module's DeviceConfig overrides (only the keys the module
manages  the ROM's own `thrashing_limit_critical` override is left alone), re-enables
DeviceConfig sync and removes `/data/adb/crdroid-garnet-ram-fix`. Runtime `resetprop` and
sysctl changes vanish at reboot.

## Layout

```
crdroid-garnet-ram-fix/
├── README.md
├── build.sh                  # packs module/ into a flashable zip
└── module/                   # <- the Magisk module (zip root)
    ├── META-INF/com/google/android/{update-binary,updater-script}
    ├── module.prop
    ├── customize.sh          # install wizard + default config
    ├── common.sh             # shared helpers (sourced by the scripts below)
    ├── post-fs-data.sh       # early: ro.lmk.medium before lmkd reads it
    ├── service.sh            # main fixes + watchdog
    ├── action.sh             # status + manual re-apply
    └── uninstall.sh          # cleanup
```
