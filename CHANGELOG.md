# Changelog

`blueStackRoot` roots BlueStacks 5 / MSI App Player by making **Magisk Delta (Kitsune)** the sole root —
fully automatically, with no traces left behind. Releases are grouped by the BlueStacks version they
target.

---

## Current — BlueStacks 5.22.169 · Android 9 / 11 / 13

One automated Magisk pipeline now roots **Android 9 (Pie64)**, **11 (Rvc64)**, and **13 (Tiramisu64)**.
All three were proven **end-to-end to `VERIFY PASS`**: Magisk is the sole root, `su -c id` returns
`uid=0`, `/system/bin/su → ./magisk`, and no bootstrap-su traces remain.

### Added
- **Android 13 (Tiramisu64)** support — same fully-automated pipeline as Android 11.
- **Android 9 (Pie64)** now uses the automated Magisk pipeline (previously a manual "open Magisk 25.2 →
  Install to System" step).
- Menu **option 7 — Full host scrub**: restores the master `Root.vhd` to factory **and** un-patches
  `HD-Player.exe`, unrooting every instance of the chosen version in one step.
- `tests/Run-Resolve-Tests.ps1` — unit tests for path + adb-port resolution (custom install/data
  locations, `…\Engine` normalization, non-5555 ports, stale `status.adb_port`).

### Changed
- **Menu**: `1/2/3` root Android 9 / 11 / 13, `4/5/6` undo each (per-instance, multi-instance safe),
  `7` full host scrub, `8` set a custom BlueStacks folder, `0` exit.
- **No hardcoded install/data paths** — they are resolved from the registry (`BlueStacks_nxt` then
  `BlueStacks_msi5`, in the native and `WOW6432Node` views), so a custom BlueStacks install location is
  honoured by the `.cmd`, the engine, and the Magisk orchestrator alike.
- **The adb port is no longer assumed to be 5555.** It is taken per-instance from `bluestacks.conf`
  (`status.adb_port`, then `adb_port`), **re-read live after launch** because BlueStacks writes the
  actual bound port during boot, and the connected device is verified to be the right BlueStacks
  instance. This handles clones assigned 5585 / 5595 / … and a foreign emulator squatting on 5555.

### Fixed
- **adb transport reliability** — pin to the stable `127.0.0.1:<port>` transport instead of the transient
  `emulator-5554` console transport (which adb can drop the moment the TCP one connects); wait for adb to
  stabilise after boot; reconnect-and-retry across the adbd restarts a freshly-booted instance performs.
  Fixes intermittent `device '…' not found` failures mid-run (seen on first boots).
- **APK path containing `&` or spaces** — an external Magisk APK under `Working Example & Fix\` is now
  passed to the orchestrator intact (a quoted, delayed-expansion argument) instead of breaking the
  command line.

### Removed
- **Android 7 (Nougat32).** It is a 32-bit instance, and every binary bundled in the tool (the `su` and
  all Magisk binaries) is 64-bit `x86_64`, so root cannot execute there. If you need root, recreate the
  instance as a 64-bit Android (9 / 11 / 13) from the Multi-Instance Manager.

---

## Previous stable — BlueStacks ≤ 5.21.x (legacy, junction-based)

The earlier releases (`bluestacks5.21_Major` — "BlueStacks 5.13+ root major update" — and before) use the
legacy junction / integrity-bypass method. **They support only that BlueStacks era and below.** On
BlueStacks 5.22.169, use the current release above instead.
