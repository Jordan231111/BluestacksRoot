# Todo List

## Done
- [x] **adb: heal the wedged "device offline" transport on slow / low-end PCs (#18)** — on a multi-minute
      boot the per-instance adb transport opens during early boot and wedges `offline` (socket up, handshake
      never finalized); a plain `connect` no-ops on it (`already connected`), so `Boot-And-Wait` polled
      `getprop` over a dead transport until timeout though the guest had booted. Fix: on a non-`device`
      candidate, **`disconnect`+`connect` to force a fresh handshake** (deterministic form of the manual
      `kill-server; connect`); gate "booted" on a host-side **`Player.log [Ready]`** signal; base liveness on
      the conf adb port / Player.log (not the WMI command-line read alone — a false zero on some hosts → no
      more `retrying launch` spam); fail fast when nothing is alive, cap the post-`[Ready]` wait, tolerate
      multi-minute boots. `AdbShellRetry`/`AdbTry` heal on drops too. Added a standalone read-only
      **`debug.cmd`** diagnostic (tests the heal live, writes one redacted log); production `blueStackRoot.cmd`
      logs to the terminal only. +unit tests (`Parse-AdbState`, Player.log parsers); all suites green
      (Magisk 256, engine 29, resolver 49, patch 24; embedded in sync). Confirmed on the reporter's 2013 PC. → v17.
- [x] **Magisk is the SOLE root: scrub any competing su + Verify catches it** — an instance could show
      "Abnormal State — su not from Magisk" when the shared master still carried a classic/engine
      `/system/xbin/su` (old non-Magisk root / the **legacy classic-su live-E2E**, which injected one).
      Git shows no commit changed su handling; the v11 adb fix just let the pipeline complete so Magisk
      booted and flagged the leftover. Fix: **Prep + Clean now scrub `/system/xbin/su`** (+daemonsu);
      **Verify enumerates every su and FAILS on any non-Magisk one** (pure `Find-StraySu`, +7 unit tests
      → 38). Rewrote `tests/Run-Live-E2E.ps1` to drive the real Magisk pipeline (`-Action Auto`) and
      assert no competing su across a reboot (it previously ran the classic-su path and planted the su).
      Live-verified on Tiramisu64_9: stray su scrubbed → **VERIFY PASS**. Re-embedded; all suites green (28+38).
- [x] **adb robustness: immune to adb-version conflicts + live-bound port detection** — `Boot-And-Wait`
      was timing out ("did not become adb-reachable") on hosts that also have a *different-version* system
      `adb` (Android SDK v1.0.41 vs BlueStacks HD-Adb v1.0.36) fighting over the default server port 5037
      (*"server version doesn't match; killing…"*). Fixed by pinning HD-Adb to a private
      a private `ANDROID_ADB_SERVER_PORT` (auto-picked FREE from 15037-15057, so it never collides with
      something already on 15037) + only ever using `HD-Adb.exe`, and by merging the **live-bound**
      listening port into `Get-AdbPortCandidates` (rescues a stale `status.adb_port`). Proven live: 30/30
      isolated getprop OK with a v41 server on 5037 (0/12 on the shared port), 20/20 stable port detection,
      free-port probe steps 15037->15038 around a stranger, full Boot-And-Wait end-to-end PASS. +9 resolve
      tests (31), re-embedded, all suites green (28+31).
- [x] **bundled a custom Kitsune v31 build so the in-app DenyList works with ReZygisk/NeoZygisk** — the deny
      module now stores entries in the `denylist` table (not `hidelist`), built from
      `Jordan231111/KitsuneMagisk@25fa2159f`. Re-embedded (`reembed-apk.ps1`, SHA `fac319d2…`, round-trip OK),
      refreshed `tools/magisk_databin/`, bumped `tests/Check-Embedded-Sync.ps1`, replaced the reference APK,
      README transparency note + CHANGELOG v10. (live-instance E2E re-confirm pending)
- [x] **bumped bundled Magisk → Kitsune Mask v31** (`1q23lyc45` fork; `magisk -c` 31.0-kitsune / 31000) via new
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
