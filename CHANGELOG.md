# Changelog

`blueStackRoot` makes **Magisk Delta (Kitsune)** the sole, trace-free root on BlueStacks 5 / MSI App
Player — from one file, fully automatically. Releases are grouped by the BlueStacks version they target.

---

## v16 — ⚡ The HD-Player integrity patch is ~80× faster (byte-for-byte identical) · 2026-06-03

Pure performance + test-coverage release. **No rooting-behavior, Magisk APK, su, debugfs, or disk-payload
changes** — identical inputs produce identical outputs, *proven byte-for-byte* against the original algorithm.

- ⚡ **Anti-tamper patch: whole-file scan ~20 s → ~0.25 s (~80×); the patch step drops from ~23 s to under 2 s.**
  The patch only ever flips **2 bytes**, yet it used to read, scan, and rewrite the entire ~27 MB
  `HD-Player.exe`. The 6× whole-file anchor-string scan + the `.text` `CALL;TEST;JZ` scan ran byte-by-byte
  in interpreted PowerShell (~177 M iterations); they now use native `[Array]::IndexOf` to jump straight to
  each candidate byte (measured on a real 27 MB binary: **20,159 ms → 248 ms**).
- 💾 **Writes 2 bytes, not 27 MB.** The validated `90 90` is now written in place via a `FileStream` seek
  instead of rewriting the whole file — same output, a fraction of the disk I/O.
- 📦 **Reads the 21 MB single-file `.cmd` once, not 3×.** The orchestrator memoizes the self-read used to
  extract the embedded debugfs / su / APK blobs.
- 🧰 **Zero new dependencies.** Everything rides on the in-box Windows PowerShell / .NET runtime the tool
  already uses — nothing to install, nothing from BlueStacks.
- 🧪 **Proven, not promised.** New `tests\Run-Patch-Equivalence.ps1` keeps a *frozen copy of the original
  algorithm* as an oracle and asserts the optimized engine produces byte-identical results across synthetic
  PEs **and the real `HD-Player.exe`** (same 1675 candidates, same validated site, same patched bytes —
  including a full-scale re-patch) and prints the before/after timing. Wired into CI next to the engine,
  resolver, and Magisk suites (all green).
- 🔎 **Same update-proof matching as before** — dynamic PE parse + the stable `CALL;TEST;JZ` idiom +
  `"Verified/Failed the disk integrity!"` anchor validation. Only the *iteration* changed, never *what* is
  matched, so version-proofness is unchanged.
- Re-embedded the optimized engine + orchestrator into `blueStackRoot.cmd`.

---

## v15 — Fix malformed adb serial when multiple Rvc64 adb ports are candidates · 2026-06-03

Fixes the reproduced DATA-stage failure where progress output showed `candidates=System.Object[]` and adb
was called with a malformed serial like `127.0.0.1:5555 5557`, producing `error: unknown host service`.

- `Get-AdbPortCandidates` now returns a flat string list instead of one nested PowerShell array object.
- `Boot-And-Wait` now tries candidate ports separately (`127.0.0.1:5555`, then `127.0.0.1:5557`, etc.)
  instead of accidentally joining them into one invalid serial.
- Resolver tests now assert the candidate list shape, and CI now runs a heavier pure-unit suite for the
  Magisk orchestrator covering candidate-port matrices, log redaction, adb server-port selection,
  HD-Player instance matching, adb retry classifiers, and stray `su` parsing.
- Re-embedded the updated orchestrator into `blueStackRoot.cmd`. No Magisk APK, su, debugfs, disk payload,
  or rooting-pipeline changes beyond the adb candidate-list fix.

---

## v14 — Privacy: redact user-profile paths in logs · 2026-06-03

Masks Windows/macOS user-profile directories in runtime and helper output so logs show
`C:\Users\xxxxx\...` or `/Users/xxxxx/...` instead of the local account name.

- Redacts normal runtime logging in `bsr_magisk.ps1` and `bsr_engine.ps1`.
- Redacts top-level failure messages so PowerShell exceptions do not print raw workspace paths.
- Redacts the `.cmd` menu path display (`DataDir`, `Install`, `debugfs`) and the `.bstk not found` path.
- Removes hardcoded local `C:\Users\...` paths from older test/dev probe scripts and derives them from the
  repo location instead.
- Adds resolver tests for Windows, slash-style Windows, and Unix-style user-profile redaction.
- Re-embedded the updated runtime scripts into `blueStackRoot.cmd`. No Magisk APK, su, debugfs, or disk
  payload changes.

---

## v13 — Android 11 launch/boot-wait hardening after Rvc64 timeout reports · 2026-06-03

Follow-up to the v12 reports where PREP succeeded but DATA failed with
`instance 'Rvc64' did not boot / become adb-reachable within 300 s`. The issue discussion showed ADB
works once the Android 11 instance is manually opened (`127.0.0.1:5555 device`), so the remaining weak
spot was host-side launch/wait behavior rather than the offline image prep or Magisk payload.

- 🚀 **Boot wait now keeps the host launch alive.** `Boot-And-Wait` logs progress every ~30s, retries the
  `HD-Player --instance ...` launch if no player process is present, and extends the wait only when the
  target instance is visibly alive but ADB is still not ready. The liveness check is scoped to the requested
  Android 11 instance, so another running BlueStacks instance cannot mask an Rvc64 launch miss. Normal boots
  do not get slower; dead launches still fail on the original timeout.
- 🧯 **Inherited shared adb port 5037 is ignored.** A stale `ANDROID_ADB_SERVER_PORT=5037` no longer pulls
  the tool back onto the shared SDK/HD-Adb conflict port. Private overrides such as `15040` are still
  honored.
- ⏱️ **Shutdown handling is less racy.** `Kill-BlueStacks` waits only as long as needed, up to 20s, for
  BlueStacks-owned processes to exit. This avoids a stale listener briefly holding `5555` and forcing the
  next Android 11 launch onto an alternate live port.
- 🔎 **Failure output is actionable.** Timeout errors now include the HD-Adb server port, candidate device
  ports, HD-Player process count, and the last connect/getprop result, so future logs show whether launch,
  bind, or boot completion is the failing stage.
- 🧪 **Validated on Android 11 / Rvc64 only.** Live boot tested with a foreign listener on 5037; Rvc64 still
  booted through the private HD-Adb server and reached `sys.boot_completed=1`. Parser checks, resolver
  tests, synthetic tests, and embedded-sync checks all pass. No Magisk APK or disk payload changes.

---

## v12 — Magisk is the SOLE root: scrub any competing su + Verify fails on one · 2026-06-02

Fixes Magisk reporting **"Abnormal State — a su binary not from Magisk has been detected"** on an instance
whose shared master `Root.vhd` still carried a **classic/engine `su`** at `/system/xbin/su` (the old
non-Magisk root method — e.g. left behind by the legacy live-E2E harness). The Magisk pipeline scrubbed
its own *bootstrap* su but never removed a pre-existing `/system/xbin/su`, and **Verify only swept for the
bootstrap su's hash**, so a competing su passed silently. (Git shows **no commit ever changed su handling**;
the v11 adb fix simply let the pipeline *complete*, so Magisk finally booted and flagged the leftover.)

- 🧹 **Prep + Clean now scrub `/system/xbin/su`** (and `daemonsu`) from the master, so Magisk's own su
  (`/system/bin/su` → magisk, `/sbin/su` → magisk) is the only one. **Re-running Clean repairs an
  already-rooted instance** — verified live: the stray su was removed and the instance returned to a clean
  state.
- 🔎 **Verify now FAILS on ANY competing su.** It enumerates every su in the standard PATH dirs and flags
  anything that isn't a symlink to magisk (new pure, unit-tested `Find-StraySu`). No more silent PASS with
  a foreign su present.
- 🧪 **Live-E2E rewritten + de-footgunned.** `tests/Run-Live-E2E.ps1` used to root via the engine's
  **legacy classic-su path** (`-Action AdbRoot`) — which *installs* a competing `/system/xbin/su` and is
  not what the tool ships. It now drives the real `bsr_magisk.ps1 -Action Auto` pipeline, **asserts VERIFY
  PASS + no competing su** (across a reboot), uses the correct package `io.github.huskydg.magisk`, and
  reverts via Magisk **Undo**.
- ✅ **Tests:** `Run-Resolve-Tests.ps1` +7 `Find-StraySu` cases (38 total); `Run-Tests.ps1` (28) and
  `Check-Embedded-Sync.ps1` green; re-embedded into `blueStackRoot.cmd`.

---

## v11 — adb robustness: immune to adb-version conflicts + live-bound port detection · 2026-06-02

Fixes a report where a **fully-booted** instance (Home visible, Magisk installed) still failed with
`instance '<name>' did not boot / become adb-reachable within 300 s`. Root cause was **not** the instance:
a **system `adb` of a different version** on the host (Android SDK platform-tools **v1.0.41**) and
BlueStacks' bundled **HD-Adb v1.0.36** were killing each other's adb **server** on the shared default port
5037 (*"adb server version doesn't match this client; killing…"*), so the tool's `getprop sys.boot_completed`
calls failed forever and `Boot-And-Wait` timed out.

- 🛡️ **Version-conflict immunity.** The tool now pins BlueStacks' HD-Adb onto its **own private adb server
  port** and only ever uses `HD-Adb.exe` (never a system `adb.exe`). A foreign-version adb on 5037 can no
  longer touch our server. *Proven on this machine:* with a v41 server deliberately running on 5037, HD-Adb
  `getprop` on the private port succeeded **30/30**; on the shared 5037 port it failed **0/12** with the
  exact reporter error; the full `Boot-And-Wait` then booted the instance end-to-end despite the v41
  competitor.
- 🔌 **Free-port selection (no new collisions).** The private port is **chosen free** from `15037–15057`:
  if something already holds `15037` before the run — a non-adb app *or* a foreign-version adb — the tool
  steps to the next free port instead of colliding with it (and reuses its own HD-Adb server if one is
  already up). An explicit `ANDROID_ADB_SERVER_PORT` always wins. *Verified live:* a non-adb listener on
  15037 → tool picks 15038; its own server on 15037 → reused. The private server is **released when the
  tool exits** (`kill-server` in a `finally`), so nothing of ours lingers on the port.
- 🎯 **Port detection hardened.** `Get-AdbPortCandidates` now also consults the **actually-bound listening
  port** (`Get-NetTCPConnection`, band 5550-5900), merged *after* the `bluestacks.conf`
  `status.adb_port`/`adb_port` values (which stay authoritative). This rescues the boot wait when the conf
  is stale — verified live: conf said `status.adb_port=5646` while the instance was really on **5645**, and
  the live scan found 5645 on **20/20** runs.
- 🧪 **Tests.** `tests/Run-Resolve-Tests.ps1` gains a deterministic seam + 3 new cases for the conf+live
  merge/dedup order (25 checks); `Run-Tests.ps1` (28) and `Check-Embedded-Sync.ps1` still pass. Re-embedded
  into `blueStackRoot.cmd` (engine + orchestrator back in sync).
- 📄 **No** change to the rooting pipeline, the embedded Magisk APK, or any on-disk format — purely
  host-side adb plumbing in `tools/bsr_magisk.ps1` (+ a one-line mirror in `tools/bsr_engine.ps1`).

---

## v10 — Custom Kitsune build: the in-app DenyList now works with ReZygisk · 2026-06-02

Swaps the bundled Magisk for a **custom build of Kitsune Mask v31** (still `31.0-kitsune`, versionCode
31000) that fixes a long-standing table mismatch. Kitsune's DenyList UI/CLI wrote app entries to the
`hidelist` table, but external ptrace-Zygisk modules (**ReZygisk / NeoZygisk**) read the `denylist` table —
so toggling an app in Magisk's own hide list had **no effect** under those modules, and you had to run
`magisk --sqlite "INSERT INTO denylist ..."` by hand.

- 🩹 **The patch (3 lines).** In `native/src/core/deny/utils.cpp` the deny module's default table is now
  `denylist` instead of `hidelist` (SuList mode still uses `sulist`, which those modules also read). Built from
  [`Jordan231111/KitsuneMagisk@25fa2159f`](https://github.com/Jordan231111/KitsuneMagisk/tree/kitsune), a fork
  of `1q23lyc45/KitsuneMagisk`. Result: the **in-app DenyList toggle now actually hides root** for
  ReZygisk/NeoZygisk-protected apps — no SQLite editing needed.
- 📦 **New embedded APK.** SHA-256 `fac319d2de262fcfff1684e13e1a5c61c486d2a773a7a8ffcfdbfe6f763a7fd4`
  (12,574,128 bytes — same size as the stock v31 APK, since `"hidelist"`→`"denylist"` is byte-length-neutral).
  Verified **rebuilt, not re-signed**: `lib/x86_64/libmagisk64.so` and `lib/x86/libmagisk32.so` both differ
  from the stock APK.
- 🔁 **No blueStackRoot pipeline change.** Package id (`io.github.huskydg.magisk`) and the APK's `lib/$ABI` +
  `assets/*.sh` layout are unchanged, so the version-agnostic extract/install/undo path roots exactly as before.
- 🛠️ **Repo kept in sync + transparent.** Re-spliced with `tools/reembed-apk.ps1` (byte-level, SHA-256
  round-trip); refreshed `tools/magisk_databin/` via `tools/extract-databin.ps1`; updated the embedded-APK hash
  asserted by `tests/Check-Embedded-Sync.ps1`; replaced the reference `Working Example & Fix/MagiskMyStableBuild.apk`;
  README "Is this safe?" now states plainly that the APK is a custom build and links the source/diff. (Live E2E
  `VERIFY PASS` to be re-confirmed on an instance.)

---

## v9 — Kitsune Mask v31 (release build) · 2026-06-02

Re-bundles **Kitsune Mask v31** using the version-tagged **31.0-kitsune** (versionCode 31000) build,
replacing the commit-named build (`magisk -c` → `2ef8f002`, versionCode 29999) shipped in v8. Same
`1q23lyc45/KitsuneMagisk` fork and Magisk version — only the APK bytes differ.

- 📦 **New embedded APK.** SHA-256 `f554c9643a527cda4910e1a044a2bfabd5f034f456587bc995895092dfe9b933`
  (12,574,128 bytes); `blueStackRoot.cmd` grows ~5 KB of base64 text accordingly.
- 🔁 **No pipeline logic changes.** The package id (`io.github.huskydg.magisk`) and the APK's internal
  `lib/$ABI` + `assets/*.sh` layout are unchanged, so the version-agnostic extract/install/undo path roots
  exactly as before.
- 🛠️ **Repo kept in sync.** Re-spliced with `tools/reembed-apk.ps1` (byte-level, SHA-256 round-trip
  verified); refreshed `tools/magisk_databin/` via `tools/extract-databin.ps1`; updated the embedded-APK
  hash asserted by `tests/Check-Embedded-Sync.ps1`; the bundled reference APK is now
  `Working Example & Fix/MagiskMyStableBuild.apk`. (E2E `VERIFY PASS` to be re-confirmed on a live instance.)

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
