# Changelog

`blueStackRoot` makes **Magisk Delta (Kitsune)** the sole, trace-free root on BlueStacks 5 / MSI App
Player — from one file, fully automatically. Releases are grouped by the BlueStacks version they target.

---

## v8 — Kitsune Mask v31 · 2026-06-01

Updates the bundled Magisk to **Kitsune Mask v31** (the `1q23lyc45/KitsuneMagisk` fork; `magisk -c` →
`2ef8f002`, versionCode 29999), replacing Magisk Delta v27.2-kitsune-4 (HuskyDG).

- 📦 **New embedded APK.** SHA-256 `e01648059a412fd9946a99801260dfde81c99def2512f161657faf404a280e05`
  (12,570,028 bytes); the `.cmd` shrinks ~261 KB of base64 text accordingly (the new APK is ~200 KB smaller).
- 🔁 **No pipeline logic changes.** The package id is unchanged (`io.github.huskydg.magisk`) and the APK's
  internal `lib/$ABI` + `assets/*.sh` layout is identical, so the version-agnostic extract/install/undo
  path roots exactly as before. (E2E `VERIFY PASS` should be re-confirmed on a live instance.)
- 🛠️ **New tooling.** `tools/reembed-apk.ps1` swaps the embedded APK at the byte level and verifies it
  round-trips by SHA-256; `tools/extract-databin.ps1` refreshes the `tools/magisk_databin/` reference set;
  `tests/Check-Embedded-Sync.ps1` now also asserts the embedded APK's SHA-256 (CI-enforced).

---

## v7 — BlueStacks 5.22.169 · Android 9 / 11 / 13 · 2026-05-31

A ground-up rewrite: the old junction / integrity-bypass method is gone. One self-contained
`blueStackRoot.cmd` now roots the **latest** BlueStacks with **real Magisk** — **no downgrade, no traces**.
Proven end-to-end (`VERIFY PASS`) on Android **9 / 11 / 13**: `su → uid=0`, the Magisk app shows
*Installed*, zero bootstrap-su left behind.

**Highlights**
- 📦 **One file, Magisk included.** The genuine Magisk Delta (Kitsune) v27.2-kitsune-4 APK is now
  **embedded inside the `.cmd`** — nothing else to download (older releases shipped Magisk separately).
- 🆕 **Roots the latest BlueStacks (5.22.169) without downgrading** — a one-byte HD-Player patch clears the
  *"Android system illegally tampered with"* shutdown.
- 🔑 **The breakthrough:** Magisk only comes alive once `/data/adb/magisk` is populated — the step the GUI
  *Install to System* silently leaves empty. Filling it from the APK is what makes Magisk actually work.
- 🧹 **Magisk as the _sole_ root, no traces:** every bootstrap/engine su is erased and stock files
  restored, so the app's "Abnormal State" warning never appears.
- 🪟 **Multi-instance:** run a rooted and an unrooted instance **side by side** (per-instance gate on the
  shared master disk).
- ⚡ **Fast, width-aware menu** with **no hardcoded paths or ports** (resolved from the registry + each
  instance's `bluestacks.conf`).

**Menu:** `1/2/3` root Android 9 / 11 / 13 · `4/5/6` undo each · `7` full host scrub · `8` custom folder ·
`0` exit.

> **Each option roots _one_ instance — the one of that Android type you opened most recently** (resolved
> from `Player.log`). So launch the exact instance you want **first**; with several clones of the same
> type it targets the last one you opened, not all of them.

**Removed:** Android 7 (32-bit — can't run the 64-bit binaries) and the entire legacy junction / `DiskRW`
method.

<details>
<summary><b>How it works under the hood (technical)</b></summary>

&nbsp;

- **Offline `Root.vhd` edit** via an embedded `debugfs` writes Magisk's `/system` payload + a hijacked
  `bootanim.rc` straight into the VHD — no ext4 driver, no `DiskRW`, no ramdisk.
- **Version-proof patch:** the HD-Player byte-scan follows RIP-relative `LEA`s to the disk-integrity anchor
  strings, so it locks onto the right call site across versions (`74 5B → 90 90`).
- **Transient bootstrap su** (`bsr_su`, delivered with a `CAP_FSETID` bind-mount trick) writes the
  root-owned `/data/adb/magisk`, then is **100% removed**.
- **Per-instance gate:** the shared master `Root.vhd` stays `Readonly`; `bootanim.rc` runs Magisk only on
  instances carrying `/data/adb/.bsr_root`, so unrooted instances stay clean and boot alongside rooted ones.
- **Robust adb:** per-instance port from `bluestacks.conf` (re-read live), pinned `127.0.0.1:<port>`
  transport, reconnect/retry across boot — never a hardcoded 5555.
- **Tested & RE'd:** the offline write is unit-tested byte-for-byte, CI runs real Windows tests, and the
  closed-source `BstkRooter.exe` is reproduced byte-exact in `recovered/`.

Full write-up: [`docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`](docs/BLUESTACKS_ROOTING_DEEP_DIVE.md) ·
runbook: [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

</details>

---

## Previous — BlueStacks ≤ 5.21.x (legacy, junction-based)

`bluestacks5.21_Major` and earlier use the legacy junction / integrity-bypass method and support only that
BlueStacks era and below. On 5.22.169, use v7 above.
