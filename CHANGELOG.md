# Changelog

`blueStackRoot` roots BlueStacks 5 / MSI App Player by making **Magisk Delta (Kitsune)** the sole root —
fully automatically, with no traces left behind. Releases are grouped by the BlueStacks version they
target.

---

## v7 — BlueStacks 5.22.169 · Android 9 / 11 / 13 · 2026-05-31

**This is a ground-up rewrite, not an increment on the older releases.** The legacy approach (NTFS
junctions, the standalone integrity-bypass scripts, and a classic injected `su`) is retired. In its place a
single self-contained `blueStackRoot.cmd` makes **Magisk Delta (Kitsune) v27.2-kitsune-4** the **sole,
trace-free root** on the **latest** BlueStacks (5.22.169) — **no downgrade required**. There was no prior
*Magisk* release, so almost everything below is new relative to the last public release
(`bluestacks5.21_Major`); the legacy method is summarised at the bottom for context.

Proven **end-to-end to `VERIFY PASS`** on **Android 9 (Pie64)**, **11 (Rvc64)** and **13 (Tiramisu64)** —
all 64-bit: `su -c id → uid=0`, `/system/bin/su → ./magisk`, the Magisk app shows **Installed** with no
"Abnormal State", and a full SHA sweep finds **zero** bootstrap-su traces.

### The breakthrough — what actually makes Magisk stick on BlueStacks 5.22
- **Populate `/data/adb/magisk` (the core discovery).** Magisk's daemon aborts with *"environment
  incomplete"* unless this root-owned dir holds `busybox` + the ABI binaries. The GUI *Install to System*
  builds the `/data/adb` skeleton but leaves this dir **empty** (a su chicken-and-egg), so Magisk stays
  dead. Filling it byte-for-byte from the APK (`busybox`, `magisk32/64`, `magiskboot`, `magiskinit`,
  `magiskpolicy`, `stub.apk`, `util_functions.sh`, `boot_patch.sh`, `addon.d.sh`) is what turns Magisk from
  dead to fully working. The whole tool is built around this.
- **One-byte HD-Player anti-tamper patch** (`74 5B → 90 90`). BlueStacks 5.22+ checks `Root.vhd` against
  `root.vhd.bvs` and rejects a modified disk — the cause of *"Android system has been illegally tampered
  with"* and the instance shutting down. A **version-proof byte scan** locks onto the integrity call site
  by following its RIP-relative `LEA`s to the disk-integrity anchor strings, then NOPs the conditional jump,
  so the **latest** BlueStacks boots a modified `/system` **without downgrading**. Re-audited: exactly one
  patch is needed — the missing piece was always data, not more code patches.
- **Offline `Root.vhd` editing via an embedded `debugfs`.** Magisk's `/system` payload + a hijacked
  `bootanim.rc` are written **directly into the VHD file** (file-level), so no Windows ext4 driver and **no
  `DiskRW`** are needed. `init` auto-parses `/system/etc/init/*.rc`, so `bootanim.rc` is the boot wiring —
  **no ramdisk required**.
- **A transient bootstrap su, then fully erased.** Writing the root-owned `/data/adb/magisk` needs root
  *before* Magisk's daemon exists (BlueStacks' own su is host-gated and `adb root` hangs). A tiny ungated
  setuid `bsr_su` is delivered via a `CAP_FSETID` bind-mount trick (a bind mount preserves the setuid bit
  that the host-gated `bindmount` can't `chmod`), used exactly once, then **100% removed**.
- **Sole root, no traces.** Cleanup removes the engine-injected `/system/xbin/su`, removes `bsr_su`,
  restores the **stock** `bindmount`, restores the factory `.xb` su, and sets `enable_root_access=0`. Net
  new su on the device: **only Magisk's** — the app's "Abnormal State / su not from Magisk" warning clears.

### The tool — one self-verifying pipeline
- **One file.** `blueStackRoot.cmd` (~20 MB) embeds the engine, `debugfs`, the bootstrap su, the
  orchestrator, and the **Magisk APK** — nothing to download, no internet. Drop a different `Magisk*.apk`
  next to it to use that build instead.
- **Phased, self-verifying flow:** `Prep` (offline: patch + conf + write Magisk `/system`) → `Data`
  (online: boot, `adb install`, populate `/data/adb/magisk`, set grant policy) → `Clean` (offline: remove
  bootstrap, restore stock `bindmount`) → `Finalize` (`enable_root_access=0`) → `Verify` (cold-boot checks)
  → ends on `[+] VERIFY PASS`. `Undo` reverses a single instance; `Undo -Full` is a full host scrub.
- **Version-agnostic.** The identical pipeline roots Android 9 / 11 / 13 — all three run end-to-end to a
  clean `VERIFY PASS`.
- **Grant policy** seeded via `magisk --sqlite` so `adb shell` / automation aren't prompted.

### Multi-instance (shared master, per-instance gate)
- **BlueStacks shares ONE master `Root.vhd`** across all instances (same disk UUID; each instance owns only
  its `Data.vhdx`). The master is kept **`Readonly`** (shareable) so multiple instances power up together —
  the old `DiskRW`→`Normal` made it exclusive and broke a 2nd instance with `VBOX_E_INVALID_OBJECT_STATE`.
- **Per-instance root gate.** Because `/system` is shared, the hijacked `bootanim.rc` calls `bsr_boot.sh`,
  which **no-ops unless that instance carries `/data/adb/.bsr_root`** on its own `/data`. Only flagged
  instances get `magiskd` / `su` / the app; the rest stay functionally clean — fixing the "Kitsune Mask
  leaked onto an unrooted instance" bug. A rooted and an unrooted instance run **simultaneously**, verified.

### Robustness & UX
- **No hardcoded paths.** Install/data locations are resolved from the registry (`BlueStacks_nxt` then
  `BlueStacks_msi5`, native and `WOW6432Node`), so a custom install location is honoured by the `.cmd`, the
  engine and the orchestrator alike.
- **Per-instance adb, never a hardcoded 5555.** The adb port is read from each instance's `bluestacks.conf`
  (`status.adb_port`, then `adb_port`) and **re-read live after launch** (BlueStacks writes the bound port
  during boot), and the connected device is verified to be the right instance — handling clones assigned
  5585 / 5595 / … and a foreign emulator squatting on 5555.
- **Reliable adb transport.** Pins to the stable `127.0.0.1:<port>` transport instead of the transient
  `emulator-5554` console transport, waits for adb to stabilise after boot, and reconnects/retries across
  the adbd restarts a fresh boot performs — fixing intermittent `device '…' not found` mid-run.
- **Fast start-up + width-aware menu.** The engine is extracted **lazily** (only when you actually
  root/unroot), so start-up no longer blocks on the ~20 MB self-read or extra PowerShell cold-starts —
  time-to-menu dropped from ~2.4 s in earlier builds to under 1 s. A single renderer scales the coloured
  banner and a two-/one-column menu to any window width; typos re-prompt instantly.
- **Robust APK paths.** An external Magisk APK under `Working Example & Fix\` (a path with `&` and spaces)
  is passed through intact.

### Menu
`1` / `2` / `3` root Android 9 / 11 / 13 · `4` / `5` / `6` undo each (per-instance, multi-instance safe) ·
`7` full host scrub (restore the pristine master `Root.vhd` **and** un-patch `HD-Player.exe`) · `8` set a
custom BlueStacks folder · `0` exit.

### Verification, tests & reverse-engineering
- **The offline `/system` write is unit-tested byte-for-byte** (`tests/test-magiskprep-offline.ps1`, PASS),
  alongside `gate-magisk.ps1`, `remove-bsr-su.ps1`, `rootvhd-hook.ps1`, and `Run-Resolve-Tests.ps1` (path +
  adb-port resolution: custom locations, `…\Engine` normalisation, non-5555 ports, stale `status.adb_port`).
- **CI runs real Windows tests** (replacing the previous no-op "compile and release" workflow).
- **Faithful RE of the closed-source `BstkRooter.exe`** kept in `recovered/BstkRooter/`: its decompiled
  Root path was reproduced byte-exact — the exe simply predates BlueStacks' newer `/data` overmount +
  daemon-su + host gate (and Magisk-to-system entirely). The environment changed, not the RE.
- Full technical write-up in `docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`; do-it-yourself steps in
  `docs/RUNBOOK.md`.

### Bug fixes hardened along the way (transparency log)
- Trailing-backslash registry `InstallDir` broke `-Install "...\nxt\"` (PowerShell read `\"` as an escaped
  quote) → strip the trailing `\` + a `Clean-Path` guard.
- `$ErrorActionPreference='Stop'` turned native `adb`/`debugfs` **stderr** into fatal errors → switch to
  `Continue` with explicit success-checks at each step.
- Grant-policy SQL broke through nested `su -c '…'` quoting → push the policy as a script file and run it.
- `-Exe "<path w/ space>" -Restore` glued `-Restore` onto the path during undo → pass `-Exe` last.

### Removed (vs the legacy releases)
- **Android 7 (Nougat32).** It is a 32-bit instance and every bundled binary (the `su` and all Magisk
  binaries) is 64-bit `x86_64`, so root cannot execute there. Recreate it as a 64-bit Android (9 / 11 / 13)
  from the Multi-Instance Manager.
- **The entire junction / integrity-bypass / `DiskRW` approach**, replaced by the Magisk pipeline above.

---

## Previous stable — BlueStacks ≤ 5.21.x (legacy, junction-based)

The earlier releases (`bluestacks5.21_Major` — "BlueStacks 5.13+ root major update" — and before) use the
legacy junction / integrity-bypass method. **They support only that BlueStacks era and below.** On
BlueStacks 5.22.169, use the current release above instead.
