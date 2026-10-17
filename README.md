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
| PSI tolerance | `lmkd_native/psi_complete_stall_ms` | → 900 (≤ PSI window) |
| Stop compaction churn | `activity_manager/use_compaction` | true → false |
| Cheap zram refaults | `vm.page-cluster` | 3 → 0 |
| Less aggressive swap | `vm.swappiness` | 100 → 60 |

Also runs `device_config set_sync_disabled_for_tests persistent` so GMS config sync
cannot overwrite the values, `setprop lmkd.reinit 1` so lmkd re-reads its
configuration, and deletes the dead keys written by v1.0.x/v1.1.x
(`compact_full_oom_adj`, `compact_throttle_full_full`, `use_full_compaction`,
`use_recompression` - see "Safety notes").

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
| `CFG_DISABLE_COMPACTION` | `1` | `use_compaction false` — stop CachedAppOptimizer app compaction (kills the refault loop at the source) |
| `CFG_FIX_LMKD` | `1` | `ro.lmk.medium` + `lmkd_native` tolerances |
| `CFG_FIX_VM` | `1` | `vm.page-cluster=0`, `vm.swappiness=60` |
| `CFG_WATCHDOG` | `1` | Keep re-applying settings if something resets them |
| `CFG_WATCHDOG_INTERVAL` | `60` | Watchdog period (seconds) |

v1.1.x configs are migrated automatically at install time (backup in
`config.sh.v1.1.bak`): the old `CFG_DISABLE_FULL_COMPACTION` intent maps onto
`CFG_DISABLE_COMPACTION` (see "Safety notes (v1.1.x dead keys)").

## Verify

- Action button shows before/after values and a live churn check (5 s `vmstat`
  delta: `pswpout`/`pswpin`/`workingset_refault_anon`/`pgmajfault` rates plus a
  verdict line).
- Log: `/data/adb/crdroid-garnet-ram-fix/logs/garnetfix.log` (only logs actual changes).
- Expected result after a day of use:
  - `pswpin ≈ 0` while idle; `am_compact` events stop entirely
  - no new `reason=3 (LOW_MEMORY)` entries in `dumpsys activity exit-info`
  - `use_compaction=false` under `Compaction settings` in `dumpsys activity -a`
  - `page-cluster=0`, `swappiness=60`, `ro.lmk.medium=800` in the sysctl/prop dumps

## Uninstall

`uninstall.sh` deletes the module's DeviceConfig overrides (only the keys the module
manages  the ROM's own `thrashing_limit_critical` override is left alone), re-enables
DeviceConfig sync and removes `/data/adb/crdroid-garnet-ram-fix`. Runtime `resetprop` and
sysctl changes vanish at reboot.

## Safety notes (v1.0.0 regression)

v1.0.0 set `lmkd_native/psi_complete_stall_ms=1500`. That value is **invalid**:
lmkd registers its PSI monitors with a fixed 1000 ms window
(`PSI_WINDOW_SIZE_MS`), and the kernel rejects a trigger whose stall threshold
exceeds its window (`psi_trigger_create()`: `threshold_us > window_us` →
`-EINVAL`). lmkd then cannot come up at all (its vmpressure fallback also fails
on memcg v2) and exits with *"New configuration is not supported. Exiting..."* —
on every restart, because the value is persisted in DeviceConfig.

A dead lmkd makes system_server block up to 3 s in
`LmkdConnection.waitForConnection()` **while holding the AMS lock** on every
OomAdj update (`ProcessList.writeLmkd`), so the whole framework grinds to a
halt: SystemUI lag, `Blocked in handler on ActivityManager for 15s` ANRs, and
`system_server_pre_watchdog` — with CPU and memory pressure near zero.

Since v1.1.0:

- all `psi_*_stall_ms` values are clamped to 1000 ms (`dc_put_bounded`);
- after every lmkd config change the module checks `init.svc.lmkd`; if lmkd is
  not `running`, it deletes the `lmkd_native` keys again, re-triggers
  `lmkd.reinit`, logs the rollback and creates
  `/data/adb/crdroid-garnet-ram-fix/.lmkd_rollback` so the watchdog stops
  re-applying the bad config (delete that file to retry);
- `action.sh` shows the lmkd service state.

To recover a device broken by v1.0.0: the bad value survives module removal
(it lives in `/data/system/users/0/settings_config.xml`), so delete the
`lmkd_native/*` DeviceConfig keys (`device_config delete`, or remove the
`<setting>` entries from `settings_config.xml` while booted in recovery) before
rebooting.

## Safety notes (v1.1.x dead keys)

v1.0.x/v1.1.x tried to "keep compaction but throttle it" with
`activity_manager/compact_full_oom_adj`, `compact_throttle_full_full`,
`use_full_compaction` and `use_recompression`. **Those keys do not exist in
Android 16's `CachedAppOptimizer`** — verified against the device's own
`/system/framework/services.jar` (zero occurrences). The class only reads
`use_compaction`, `compact_throttle_1..6`, `compact_throttle_min_oom_adj`,
`compact_throttle_max_oom_adj`, `compact_full_rss_throttle_kb`,
`compact_full_delta_rss_throttle_kb` and `compact_proc_state_throttle`.
`device_config put` accepts any key, so the writes "succeed" and simply sit in
the settings provider while compaction churns on unchanged — measured on-device:
v1.1.0 ran with its full config active and the refault loop continued at
`pswpin == workingset_refault_anon` ≈ 134 pages/s while idle.

There is no "disable FULL compaction only" switch to fall back to either:
`resolveCompactionProfile()` maps `SOME → NONE` and `FULL → ANON`
(`ENABLE_SHARED_AND_CODE_COMPACT=false`), so the only compaction that ever
executes is anon pageout into zram — the exact churn this module exists to stop.
Since v1.2.0 the module therefore uses the one verified master switch
(`use_compaction=false`) and deletes the dead keys it (and any community fix)
may have left behind.

Since v1.2.0:

- compaction fix = `activity_manager/use_compaction=false` (the only real
  switch on Android 16), dead keys removed on every apply;
- v1.1.x configs migrate automatically at install (`config.sh.v1.1.bak`);
- `action.sh` includes a live churn check (the refault-loop metric).

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
