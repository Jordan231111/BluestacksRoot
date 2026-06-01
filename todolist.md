# Todo List

## Done
- [x] **bumped bundled Magisk → Kitsune Mask v31** (`1q23lyc45` fork; `magisk -c` 2ef8f002 / 29999) via new
      `tools/reembed-apk.ps1` (byte-level splice + SHA-256 round-trip); refreshed `tools/magisk_databin/`
      (`tools/extract-databin.ps1`); `tests/Check-Embedded-Sync.ps1` now guards the embedded APK SHA. No
      pipeline logic change (same package id `io.github.huskydg.magisk` + identical APK layout); live-instance
      E2E re-confirm pending.
- [x] kill processes with one scoped call  (now a single PowerShell match on `^(HD-|Bstk|BlueStacks)` — comprehensive, no overkill; no BlueStacks Windows service to fight)
- [x] fix up unused commands/comments  (blueStackRoot.cmd is a clean single-file orchestrator)
- [x] bypass newest security  (version-proof HD-Player integrity bypass; verified on 5.22.169)
- [x] su install without a manually-installed debugfs  (embedded `debugfs` + offline ext4 writes)
- [x] real Windows `debugfs` in the repo  (Cygwin 1.44.5 + 10 DLLs, embedded; writes su/files + SHA-match)
- [x] **Magisk as the FINAL, sole root on Android 11 (Rvc64)** — proven cold-boot: `su → magisk` `uid=0`,
      app *Installed*, no "Abnormal State", zero traces of bootstrap/engine su
- [x] **the breakthrough:** populate `/data/adb/magisk` (the GUI install leaves it empty → daemon aborts)
- [x] **no traces:** remove bootstrap `bsr_su`, restore stock `bindmount`, remove engine `/system/xbin/su`,
      restore factory `.xb` su, `enable_root_access=0`
- [x] **single self-contained `.cmd`** — engine + debugfs + bootstrap su + orchestrator + Magisk APK all
      embedded (~20 MB); option 3 = Magisk root (Rvc64), option 6 = unroot; routed under existing options
- [x] **full E2E proven** through the embedded path (Prep→Data→Clean→Finalize→Verify = PASS)
- [x] **multi-instance: rooted + unrooted simultaneously** — shared master set Readonly + per-instance gate
      (`bsr_boot.sh` + `/data/adb/.bsr_root`); proven two instances at once (Rvc64 rooted, Rvc64_3 inert)
- [x] **leak fixed** — Kitsune Mask no longer installs on unrooted instances (the gate stops `magiskd` there)
- [x] hardening bug-fixes: trailing-backslash `InstallDir`, native-stderr-as-fatal, policy-paren quoting,
      `-Restore` arg-glue, Normal-disk multi-instance lock (see deep-dive §11)
- [x] docs current (`docs/RUNBOOK.md`, `docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`); repo organized (`archive/`)
- [x] **Android 9 (Pie64) + 13 (Tiramisu64) on the SAME Magisk pipeline as Android 11** — the offline
      ext4 carve + gated bootanim.rc + bootstrap-su path is version-agnostic; both proven **full E2E to
      `VERIFY PASS`** (Magisk sole root, `su -c id` uid=0, `/system/bin/su -> ./magisk`, no bsr_su traces)
- [x] **menu reworked:** 1/2/3 root Pie64/Rvc64/Tiramisu64, 4/5/6 undo each, 7 = full host scrub
      (`-Full`: restore master + un-patch HD-Player), 8 = custom path, 0 = exit — all via the Magisk path
- [x] **removed Android 7 (Nougat32):** it is a 32-bit instance and every bundled binary (su + magisk) is
      64-bit x86_64, so root cannot run there; README points 32-bit users at recreating as 64-bit
- [x] **adb robustness (found via the 9/13 E2E):** prefer the stable `127.0.0.1:<port>` transport over the
      transient `emulator-XXXX` (which adb drops mid-run); `Boot-And-Wait` now stabilizes (3 consecutive
      reachable shells) before returning, and shell/su/push go through reconnect-on-drop retries — fixes
      first-boot "device '127.0.0.1:5555' not found" on a fresh instance
- [x] **fast start-up + new front-end:** the start-up path no longer does the ~20 MB self-read or the
      `BaseDir` PowerShell call (engine is extracted lazily via `:ensure_engine`; DataDir display is a cheap
      batch `\Engine` strip), cutting time-to-menu from ~2.4 s to <1 s.  `:draw_menu` is one width-aware
      renderer: full ASCII art >=93 cols, boxed title 50-92, compact <50; two-column menu >=62 cols, single
      column below; coloured via PowerShell `Write-Host` so box-drawing renders regardless of code page.
      Typos re-prompt instantly (`:prompt`) instead of a full redraw.  (Menu lives in the batch portion, so
      no re-embed is needed for these changes.)
- [x] **CI replaced:** dropped the bogus `Compile and Release` workflow (it `g++`-compiled a since-deleted
      `Magisk.cpp` -- always failing -- and its release step would have clobbered hand-cut releases with
      nonexistent `magisk.exe`/`NewblueStacksRoot.cmd`).  New `.github/workflows/tests.yml` runs on push/PR
      to `main`: `tests/Run-Tests.ps1` (28) + `tests/Run-Resolve-Tests.ps1` (22) on windows-latest, plus a
      new `tests/Check-Embedded-Sync.ps1` guarding that the embedded engine/orchestrator still match
      `tools\bsr_engine.ps1`/`bsr_magisk.ps1`.  No auto-compile, no auto-release (releases are cut by hand).

## Open / nice-to-have
- [ ] optional: dedicated per-instance Root.vhd (separate VHD + UUID) for a *bit-pristine* `/system` on
      unrooted instances (the gate already makes them functionally clean; this only removes inert files)
- [ ] update `tools/build.ps1` to assemble the current Magisk build end-to-end (it predates the Magisk
      pipeline). Re-embedding is now scripted piecewise — `tools/reembed.ps1` (engine + orchestrator) and
      `tools/reembed-apk.ps1` (the Magisk APK) — so the remaining gap is a single full-assemble entry point.

## Notes
- The `.cmd` embeds, between marker lines: the engine (`tools/bsr_engine.ps1`), the orchestrator
  (`tools/bsr_magisk.ps1`, `__BSR_MAGISK_*`), `debugfs` (`__BSR_DFS_*`), bootstrap su (`__BSR_BSRSU_*`),
  and the Magisk APK (`__BSR_APK_*`). To iterate: edit `tools/bsr_magisk.ps1` (or `bsr_engine.ps1`), then
  run `tools/reembed.ps1` to re-sync the engine/orchestrator blocks into the `.cmd` (byte-level splice +
  verify). To swap the bundled Magisk, run `tools/reembed-apk.ps1 -Apk <new.apk>` (byte-level splice +
  SHA-256 round-trip) and `tools/extract-databin.ps1 -Apk <new.apk>` to refresh the reference set;
  `tests/Check-Embedded-Sync.ps1` (CI) asserts the engine, orchestrator, and APK all match.
- Per-instance root = presence of `/data/adb/.bsr_root` on that instance's own `/data`. The shared
  master `Root.vhd` must stay `type="Readonly"` so instances can run concurrently.
- Legacy junction/integrity scripts moved to `archive/` (kept for reference, not used).
