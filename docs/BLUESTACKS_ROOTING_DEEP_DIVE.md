# BlueStacks 5.22.169 Rooting — Full Deep Dive, the Magisk Breakthrough & the Minimal Workflow

**Target:** BlueStacks 5.22.169.1008, instance `Rvc64` (Android 11 / "R" / `rvc`, x86_64), Windows.
The same pipeline is **version‑agnostic** and has since been proven end‑to‑end on **Pie64 (Android 9)** and
**Tiramisu64 (Android 13)** too — both 64‑bit; the analysis below uses `Rvc64` as the worked example.
**Goal:** **Magisk** is the sole, self‑sustaining root — app shows **Installed** after a cold boot — with **no trace** of our bootstrap su or any other rooting cruft. `Ramdisk: Yes/No` is irrelevant (Magisk works either way here).
**Status: ACHIEVED and PROVEN (cold‑boot, emulator‑root OFF):** `su → /system/bin/su → magisk`, `uid=0`; `magiskd` running; Magisk app Home clean (no "Abnormal State"); our `bsr_su` and the engine‑injected `/system/xbin/su` fully erased; stock `bindmount` restored; HD‑Player anti‑tamper patch intact.

> Single source of truth for how rooting works on this build, every wall we hit, the breakthrough, the su‑source investigation, and the minimal end‑to‑end workflow the `.cmd` automates.

---

## 0. TL;DR — what actually makes Magisk stick

1. **One byte patch** on `HD-Player.exe` (anti‑tamper bypass) so a modified `Root.vhd` is accepted and a tampered `/system` boots. **Must stay applied.**
2. **Magisk system‑mode files on Root.vhd** — `/system/etc/init/magisk/{magisk32,magisk64,magiskinit,magiskpolicy,config,stub.apk}` + a **hijacked `/system/etc/init/bootanim.rc`** (Android `init` auto‑parses `/system/etc/init/*.rc`; that's the wiring — no ramdisk needed).
3. **THE BREAKTHROUGH: populate `/data/adb/magisk`.** Magisk's daemon aborts with *"environment incomplete"* unless `/data/adb/magisk/` holds `busybox` + the ABI binaries. The GUI "Install to System" created the `/data/adb` skeleton but **never populated this dir** (a su chicken‑and‑egg, see §4). Filling it from the APK is what turns Magisk from dead to fully working.
4. **A transient bootstrap root** (our setuid `bsr_su`) is needed exactly once — to write the root‑owned `/data/adb/magisk` — then it is **completely removed**.
5. **No traces:** remove `bsr_su`, restore the stock `bindmount`, remove the engine‑injected `/system/xbin/su`, restore the factory su in `.xb`, set `enable_root_access=0`. Magisk becomes the only root.

**The encrypted `BstkRooter.exe` verdict:** the RE was faithful; **BlueStacks changed the logic** (added the `/data` overmount + daemon‑su + host gate) long after the exe was written. The exe also predates Magisk‑to‑system entirely. (§8)

---

## 1. Storage & boot architecture (verified live)

### 1.1 Host files (`C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\`)
| File | Role |
|---|---|
| `Root.vhd` (8 GB virt, ~2.2 GB on disk) | Android **system** image; ext4 with the Android tree under **`/android/system`** |
| `Data.vhdx` (128 GB virt) | Per‑instance **/data** (writable) |
| `fastboot.vdi` (~11 MB) | Kernel + initrd boot helper (IDE boot disk) |
| `Rvc64.bstk` | VirtualBox machine config (regenerated from `Android.bstk.in` at launch) |
| `root.vhd.bvs` (288 B) | Root.vhd integrity signature (checked by HD‑Player) |

### 1.2 `.bstk` disk modes — factory vs. ours
| Disk | Factory | After our `DiskRW` | Needed for the minimal flow |
|---|---|---|---|
| `fastboot.vdi` | `Readonly` | `Normal` | **Readonly** (leave factory) |
| `Root.vhd` | `Readonly` | `Normal` | **Readonly** — we edit the `.vhd` **offline** (file‑level), which works regardless of `.bstk` mode |
| `Data.vhdx` | `Normal` | `Normal` | `Normal` (already factory — that's where `/data/adb` is populated at runtime) |

> **Minimization:** because Magisk's persistent `/system` files are written **offline** (debugfs into the Root.vhd file) and the only runtime writes go to `/data` (factory‑writable), **`DiskRW` is not required at all.** Leaving the `.bstk` factory ("no BlueStacks bogus rooting") is cleaner and avoids a host‑file write.

### 1.3 Disk → guest device mapping
- `Root.vhd` → SATA0 → **`/dev/sda`** (`sda1` = 8 GB ext4) → `/system` (ro) + `/boot/android`
- `Data.vhdx` → SATA1 → **`/dev/sdb`** (`sdb1` ext4) → `/data` (rw)
- `fastboot.vdi` → IDE0 → `/dev/sdc`

### 1.4 The mount layout (`/proc/self/mountinfo`)
```
/dev/sda1  /system        ext4 ro    /android/system        <- system = Root.vhd:/android/system
/dev/sda1  /boot/android  ext4 ro    /                      <- Root.vhd ext4 root (android/, dataFS/)
/dev/sdb1  /data          ext4 rw                           <- /data = Data.vhdx
/dev/sdb1  /system/xbin   ext4 rw    /downloads/.xb         <- ONLY when emulator root is ON: xbin overmounted from /data/downloads/.xb
magisk     /system/bin    tmpfs                             <- Magisk magic‑mount overlay (su -> magisk lives here, recreated each boot)
magisk     /sbin          tmpfs                             <- Magisk sbin (setup-sbin)
```
**Key facts**
- The Android system tree lives at **`/android/system`** inside Root.vhd's ext4 (so `/system/bin/x` == ext4 `/android/system/bin/x`).
- **`/system/xbin` is overmounted from `/data/downloads/.xb` only while emulator root is ON** (`bst.config.bindmount` set). With root OFF it is Root.vhd's native xbin (busybox applets + a `bstk/` subdir).
- `/system/bin` and `/sbin` are **Magisk tmpfs** at runtime — Magisk's `su` symlinks there are **not** persistent files; `setup-sbin` rebuilds them every boot from `/system/etc/init/magisk`.

### 1.5 `bindmount` — BlueStacks' own root helper
`/system/bin/bindmount` (stock, 1339 B, uid 1000) is started by init `on property:bst.config.bindmount=*`. Stock logic: when `bst.config.bindmount>0` and `/data/downloads/.xb` exists → `mount -o bind /data/downloads/.xb/ /system/xbin/` then `/system/xbin/su --auto-daemon &`. `bst.config.bindmount` is set to 1 when `bst.instance.<inst>.enable_root_access=1`. BlueStacks' `su` is a **host‑gated daemon** (`daemonsu`); it will not grant `adb shell` su — which is why we needed a bootstrap su of our own (§3).

### 1.6 Guest security posture (helps us)
- `getenforce` = **Disabled** (SELinux off) → setuid binaries + our edits honored without policy.
- `ro.secure=0`, `ro.debuggable=1`, but **`adb root` hangs** (adbd won't restart as root).
- `/system`, `/system/xbin` are **not** `nosuid` → setuid execution works.

---

## 2. The single byte patch (HD‑Player anti‑tamper) — what & why

BlueStacks verifies `Root.vhd` against `root.vhd.bvs`; an unpatched player **rejects/ignores** a modified Root.vhd, so neither our su nor Magisk's `/system` files would survive. **This patch is mandatory for Magisk too** (Magisk modifies `/system`).

- **Signature (version‑proof byte scan):** `E8 ?? ?? ?? ?? 84 C0 74 ??` = `CALL <integrity_check>; TEST AL,AL; JZ <fail>`. The scan validates the match by following the RIP‑relative `LEA` operands to the disk‑integrity **anchor strings**, so it locks onto the right call site even if offsets shift between versions.
- **The patch:** NOP the conditional jump — `74 5B → 90 90`. Now the result of the integrity check is ignored and boot proceeds with the modified disk.
- **Verified site (this build):** file offset `0xB46E8` (within the `… 84 C0` at `0xB46E6`), va `0x1400B52E6`.
  - Patched `HD-Player.exe`: `… 84 C0 90 90 …`
  - Pristine `HD-Player.exe.bak`: `… 84 C0 74 5B …`
- **Why only one patch?** We re‑audited the binary; **no additional byte patches are needed.** Earlier notes speculated we might need "aggressive" patching — that turned out false. The real missing piece was data, not code: the empty `/data/adb/magisk` (§4). One anti‑tamper NOP + correct files = working Magisk.

---

## 3. The transient bootstrap su (needed once, then erased)

To write the **root‑owned** `/data/adb/magisk` we need a working root **before** Magisk's daemon is alive — a chicken‑and‑egg the GUI can't break. BlueStacks' own su is host‑gated, `adb root` hangs, and Data.vhdx can't be edited offline (128 GB; `debugfs` short‑reads the raw device). So we use a tiny **ungated, daemonless setuid su** at runtime, then remove every trace.

- **`tools/su_src/bsr_su.c`** (~5 KB, x86_64, NDK clang `--target=x86_64-linux-android30`): `setresgid(0,0,0); setresuid(0,0,0);` then `exec`s the requested command/shell. No hypercall, no daemon, no policy → always grants when setuid‑root.
- **Delivery (the `CAP_FSETID` trick):** `bindmount` runs as root but **without `CAP_FSETID`**, so it cannot `chmod` the setuid bit (a copied su came out `0755` → uid 2000). Fix: write `bsr_su` to `/android/system/etc/bsr_su` **with the setuid bit set offline**, and have a **hijacked `bindmount`** `mount -o bind` it over `/system/xbin/su` **after** the `.xb` overmount — a **bind mount preserves the setuid bit**. Verified: `su -c id → uid=0`, persistent.
- This bootstrap is **100 % removed** at the end (§5). It exists only during the install.

---

## 4. THE BREAKTHROUGH — `/data/adb/magisk` was empty

A manual Magisk Delta ("Kitsune") **Install → Install to System** set up most of Magisk correctly but left it **dead**. The decisive log:

```
# /cache/magisk.log  (before the fix)
E: * Magisk environment incomplete, abort
W: pkg: cannot find io.github.huskydg.magisk for user=[0]
W: su: request rejected (2000)
E: write failed with 32: Broken pipe
```

### 4.1 What the GUI install got RIGHT (all persisted on Root.vhd / Data.vhdx)
- `/system/etc/init/magisk/{magisk32,magisk64,magiskinit,magiskpolicy,config,stub.apk}` (config = `SYSTEMMODE=true / RECOVERYMODE=false`).
- **`/system/etc/init/bootanim.rc` hijacked** — the original 185‑B boot‑anim service file replaced with Magisk's boot sequence (`magiskpolicy --live`; `magisk64 --setup-sbin … /sbin`; `--post-fs-data`; `--service`; `--boot-complete`; zygote‑restart hooks), original saved as `bootanim.rc.gz`. **This is the init wiring** — `init` auto‑parses `/system/etc/init/*.rc`, so no ramdisk is required. (The earlier doc's claim that the hook was "unwired" was wrong; it was wired via `bootanim.rc`.)
- `/data/adb/{magisk(empty), modules, post-fs-data.d, service.d}` + `magisk.db`.

### 4.2 What it got WRONG (the whole failure)
**`/data/adb/magisk/` was EMPTY.** `magisk --post-fs-data` runs `magisk_env()`, which does `if (access(DATABIN "/busybox", X_OK)) return false;` → **"environment incomplete, abort."** The installer couldn't populate this root‑owned dir because the only su in `$PATH` at install time was Magisk's own half‑installed `/system/bin/su → magisk` (daemon dead) → `su: request rejected` → `Broken pipe` → dir left empty. Classic chicken‑and‑egg.

### 4.3 The fix (proven)
Populate `/data/adb/magisk` with the **canonical 64‑bit install set**, copied byte‑for‑byte from the matching APK (`MagiskMyStableBuild.apk`, `lib/$ABI` renamed + `assets/*.sh`):
```
busybox  magisk32  magisk64  magiskboot  magiskinit  magiskpolicy  stub.apk
util_functions.sh  boot_patch.sh  addon.d.sh   (root:root, 0755 / stub 0644)
```
Then set a grant policy so shell/automation aren't prompted:
```
magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,0,0)"   # 2 = allow
```
**Result, after a true cold boot:**
```
magiskd started; ** post-fs-data → Magic Mount Setup → Initializing Magisk environment
** late_start service → ** boot-complete triggered → * Mount MagiskSU
su -c id  →  uid=0(root)        # via /system/bin/su -> magisk, even with emulator root OFF
```

---

## 5. Resolving the su conflict — making Magisk the SOLE root with no traces

After the fix, the Magisk app showed **"Abnormal State — A 'su' binary not from Magisk has been detected."** Investigation (full factory‑vs‑live diff):

### 5.1 Source of the competing su — **it was our engine, not a config, not BlueStacks**
- Pristine factory `Root.vhd` (`bsrbak`, pre‑everything) has **no `/system/xbin/su` at all**. Factory only ships `/system/xbin/bstk/su` (41160 B, in a `bstk/` subdir that is **not** in `$PATH`).
- The competing `/system/xbin/su` was a **2 MB setuid binary, SHA `185106357…`** — exactly the **embedded su in `bsr_engine.ps1`** (`$SuSha256`). `Edit-Ext4` writes it via `write … /android/system/xbin/su` (the engine's `Root` action). It was injected during an earlier `Root` run (hence today's timestamp).
- Proof it's not config‑driven: removed it, booted with emulator root **OFF** → it **never reappeared**, and the "Abnormal State" **cleared**.

### 5.2 Every trace and how it was erased
| Trace (ours) | Location | Disk | Removal |
|---|---|---|---|
| engine 2 MB su (`185106357…`) | `/system/xbin/su` | Root.vhd | `bsr_engine.ps1 -Action Unroot` (`rm /android/system/xbin/su`) |
| bootstrap `bsr_su` (4968 B, `7eb6380e…`) | `/system/etc/bsr_su` | Root.vhd | offline `debugfs rm` |
| modified `bindmount` | `/system/bin/bindmount` | Root.vhd | offline restore of stock (1339 B, uid 1000, 0775) |
| `bsr_su` copies | `/data/downloads/.xb/su`, `.xb/bstk/su` | Data.vhdx | runtime `cp` of factory su (41160 B) over them |
| emulator root flag | `bst.instance.Rvc64.enable_root_access` | conf | set `0` (modify‑only, no BOM) |

**Kept (intentional):** Magisk's files (`/system/etc/init/magisk/*`, hijacked `bootanim.rc`, `/data/adb/*`), the factory `/system/xbin/bstk/su`, and the HD‑Player patch. A full SHA sweep for `bsr_su` across `/system` + `/data` returns **zero hits**. Magisk app Home is clean.

---

## 6. The MINIMAL end‑to‑end workflow (what the `.cmd` does)

Designed for **fewest persistent read/writes** to reach the exact proven state. Host‑side writes: **HD‑Player (2 bytes)** + **conf (`enable_root_access`)**. Disk writes: **two offline Root.vhd carves** (prep, then cleanup) + a **runtime `/data/adb` populate**. `.bstk` is **left factory** (no DiskRW).

```
PHASE A — OFFLINE PREP   (instance down; edits HD-Player, conf, and the Root.vhd file directly)
  A1  Patch HD-Player anti-tamper           (idempotent; keep HD-Player.exe.bak)
  A2  conf: enable_root_access=1, enable_adb_access=1   (modify-only, UTF-8 no BOM)
  A3  ONE Root.vhd carve+debugfs+writeback, writing:
        - Magisk system files -> /android/system/etc/init/magisk/{magisk32,magisk64,
          magiskinit,magiskpolicy,config,stub.apk}        (from the APK)
        - hijacked /android/system/etc/init/bootanim.rc  (+ bootanim.rc.gz = gz of original)
        - bootstrap: /android/system/etc/bsr_su (setuid) + hijacked /android/system/bin/bindmount

PHASE B — BOOT + ONLINE  (bootstrap su active over adb)
  B1  launch instance; wait for sys.boot_completed=1
  B2  adb install Magisk APK (the manager app)
  B3  via /system/xbin/su (bsr_su):
        - mkdir /data/adb/{magisk,modules,post-fs-data.d,service.d}
        - populate /data/adb/magisk from the APK (busybox, magisk32/64, magiskboot,
          magiskinit, magiskpolicy, stub.apk, util_functions.sh, boot_patch.sh, addon.d.sh)
        - magisk.db: REPLACE INTO policies … VALUES(2000,2,0,0,0)
        - sync

PHASE C — OFFLINE CLEANUP (instance down; ONE Root.vhd carve+writeback + conf)
  C1  Root.vhd: rm /android/system/etc/bsr_su ; restore stock bindmount (1339 B, uid 1000, 0775)
  C2  runtime-erase happens earlier/at boot: restore factory su over /data/downloads/.xb/{su,bstk/su}
  C3  conf: enable_root_access=0

PHASE D — VERIFY (cold boot)
  D1  launch; su -c id -> uid=0 (Magisk); /system/xbin/su absent; bsr_su sweep clean;
      bindmount=1339; HD-Player=84 C0 90 90; Magisk app: Installed, no warning.
```

Notes:
- **Graceful shutdown** between phases (`adb shell sync` then close window) — repeated *hard* kills corrupt Android settings XMLs (Android self‑heals them, but it's noise; `/data/local/tmp/corrupt_files_deleted` is that, **not** anti‑tamper).
- The APK is the single external input (provides both the manager app and every Magisk binary). The `.cmd` is the one orchestrator file.

---

## 7. Where ALL the useful logs are

### Host (Windows)
| Path | Shows |
|---|---|
| `…\Logs\Player.log` | Instance boot, `Verified the disk integrity!`, `bvs` warnings, app launches |
| `…\Engine\Rvc64\Logs\BstkCore.log` | VirtualBox VM log (disk attach, devices, VM state) |

### Guest (`HD-Adb.exe`; prefix bash with `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`)
| Command | Shows |
|---|---|
| `adb shell getprop bst.config.bindmount / sys.boot_completed` | root‑helper trigger / boot stage |
| `adb shell dmesg` | kernel log; a hijacked `bindmount` echoes here |
| `adb shell cat /proc/self/mountinfo` | the overmount/bind topology |

### Magisk (decisive)
| Path / command | Shows |
|---|---|
| **`/cache/magisk.log`** | the whole story: `environment incomplete, abort` (before) → `daemon started … Mount MagiskSU` (after) |
| `magisk -c` / `-V` | daemon version the app reads to show *Installed* |
| `magisk --sqlite "SELECT * FROM policies"` | grant policy |
| `/data/adb/magisk/`, `/system/etc/init/magisk/` | runtime binaries / system‑mode binaries |

---

## 8. The encrypted `BstkRooter.exe` — faithful RE; BlueStacks changed the logic

Re‑verified from `recovered/BstkRooter/` (decompiled "Root" `fcn.14001d370` + string tables). The Root routine: kill procs → `FindResourceA(101)` decrypt embedded su → open Root.vhd, find ext4, mount → create `/android/system/xbin`, copy su → `chmod 06755`/chown → set `bst.instance.<inst>.enable_root_access=`. We reproduced this **byte‑exact** (inode/mode/SHA matched — in fact `bsr_engine.ps1` *is* that reproduction, which is why its `Root` action injected the `/system/xbin/su` we later had to remove).

- **Faithful:** the decompilation + strings give the complete Root path; our reproduction matched on disk. No skipped branch.
- **The exe is blind to the new mechanism:** a whole‑binary search finds **no** `/data`, `downloads`, `.xb`, `bindmount`, `--auto-daemon`, or daemon‑su strings. It only knows `/android/system/xbin/su` + `enable_root_access`. You can't fail to RE handling for identifiers that don't exist in the program.
- **The live build uses a newer design** that post‑dates the exe: `/system/xbin` overmounted from `/data/downloads/.xb` (shadowing the exe's su), a host‑gated daemon‑su, `bst.feature.rooting` force‑reset to 0 each launch — and Magisk‑to‑system didn't exist in the exe's world at all.
- **Why it worked on older "anti‑tampered" builds:** older 5.x / Android‑7 "Nougat" instances kept `/system/xbin` **directly on Root.vhd** with no overmount, so injected‑su + integrity bypass sufficed. The Android‑11 line added the overmount/daemon/gate to defeat exactly that.

**Verdict: the environment changed, not your RE.**

---

## 9. Key artifacts & repro details (sizes / SHAs / offsets)

(For the folder layout of the whole repo, see §12.)

| Item | Path |
|---|---|
| Bootstrap su source / binary | `tools/su_src/bsr_su.c` / `tools/su_src/bsr_su` (4968 B, `7eb6380e…`) |
| Stock bindmount (extracted from factory) | `tools/su_src/bindmount.orig` (1339 B) |
| Modified bindmount (bootstrap) | `tools/su_src/bindmount.mod` |
| Magisk databin (extracted from APK) | `tools/magisk_databin/` |
| Magisk APK (manager + all binaries) | `Working Example & Fix/MagiskMyStableBuild.apk` |
| Engine (patch, conf, ext4, Root/Unroot) | `tools/bsr_engine.ps1` (embedded in `blueStackRoot.cmd`) |
| Offline su inject (bootstrap) | `tests/rootvhd-hook.ps1` |
| Offline bsr_su remove + stock bindmount restore | `tests/remove-bsr-su.ps1` |
| Factory‑inventory investigation | `tests/investigate-factory-root.ps1` |
| HD‑Player patch site | file `0xB46E8` / va `0x1400B52E6` (`74 5B → 90 90`) |
| Backups | `Root.vhd.bsrbak` (pristine, pre‑all), `Root.vhd.magiskgood` (Magisk‑good), `Rvc64.bstk.bsrbak` |
| Magisk log | `/cache/magisk.log` |

---

## 10. Multi‑instance: shared master + the per‑instance gate

**BlueStacks shares ONE master `Root.vhd` across all instances** (verified: `Rvc64`, `Rvc64_3..7`
all attach the *same* disk UUID `{85c80f25}`; each instance only owns its `Data.vhdx`). Two facts fall out:

- **Simultaneous launch needs `type="Readonly"`.** A `Normal` (writable) disk is exclusive — a 2nd
  instance fails to power up with `VBOX_E_INVALID_OBJECT_STATE`. Factory is `Readonly` (shareable); the
  old `DiskRW`→`Normal` broke it. The Magisk pipeline keeps/sets the master **Readonly** (Finalize);
  `Data.vhdx` stays `Normal` (per‑instance, writable).
- **Rooting the shared `/system` would root every instance.** Magisk's `/system` payload + the hijacked
  `bootanim.rc` live on the master, so `magiskd` (and its manager‑app install) would run on *every*
  instance — the "Kitsune Mask leaked onto an unrooted instance" bug.

**Fix — a per‑instance gate (no separate disk):** the hijacked `bootanim.rc` execs
`/system/etc/init/magisk/bsr_boot.sh <stage>`, which **exits immediately unless THIS instance carries
`/data/adb/.bsr_root`** (a flag on its own, per‑instance `/data`). So:

| | rooted instance (flag + `/data/adb/magisk`) | unrooted instance (no flag) |
|---|---|---|
| `bsr_boot.sh` | runs the magisk boot stages | `exit 0` immediately |
| `magiskd` / `/system/bin/su` / app | present (root works) | **none** |

Per‑instance root = presence of `/data/adb/.bsr_root`. **Proven:** `Rvc64` (flag) and `Rvc64_3`
(no flag) boot **simultaneously** — Rvc64 `uid=0`, Rvc64_3 has `magiskd=0`, no `su`, no app.

> Caveat: an instance that was rooted/leaked *before* the gate keeps an inert, root‑owned `/data/adb`
> on its `Data.vhdx` (the gate never executes it; removing it needs root). Freshly‑created instances
> never get it. A *bit‑pristine* `/system` on unrooted instances would require a dedicated per‑instance
> Root.vhd (separate VHD + UUID) — avoided here; the gate makes unrooted instances **functionally** clean.

---

## 11. Bugs found & fixed while hardening the `.cmd` (transparency log)

| Bug | Cause | Fix |
|---|---|---|
| Option 3 died: `...nxt"\HD-Adb.exe` not found | registry `InstallDir` ends in `\`; `-Install "...\nxt\"` → PowerShell reads `\"` as an escaped quote | `.cmd` strips the trailing `\`; `bsr_magisk` `Clean-Path` defends (strips stray `"`/`\`) |
| Pipeline aborted on `adb`/`debugfs` output | `$ErrorActionPreference='Stop'` turns native **stderr** into a fatal error | global `Continue` + explicit success‑checks/`throw` at each step |
| Grant policy not set | SQL parens broke through nested `su -c '…'` quoting | push the policy as a **script file**, run that |
| Undo left HD‑Player patched | `-Exe "<path w/ space>" -Restore` glued `-Restore` onto the path | pass `-Exe` **last** |
| 2nd instance "couldn't launch" | shared master `Root.vhd` was `type="Normal"` (exclusive) | set master **Readonly** (Finalize) |
| Kitsune Mask leaked to unrooted instances | shared `/system` ⇒ `magiskd` ran everywhere | per‑instance gate (`bsr_boot.sh` + `/data/adb/.bsr_root`) |

---

## 12. Current state & file map

**DONE & PROVEN (cold boot, emulator root OFF):** Magisk is the **sole working root** on
flagged instances (`su → magisk`, `uid=0`); unrooted instances are functionally clean (no daemon/su/app);
both run **simultaneously**. Zero traces of our bootstrap/engine su; stock `bindmount`; factory `.xb` su;
HD‑Player patch intact; backups retained. (Bundled Magisk: **Kitsune Mask v31** — `magisk -c` → `31.0-kitsune` / 31000; the breakthrough was originally proven on Magisk Delta v27.2-kitsune-4, and the pipeline is version-agnostic.)

**Single‑file tool:** `blueStackRoot.cmd` (≈20 MB) embeds the engine + debugfs + bootstrap su + the
orchestrator + the Magisk APK. **Option 3** = root Android‑11 (Rvc64) with Magisk; **Option 6** = unroot.

| Item | Path |
|---|---|
| One‑file tool | `blueStackRoot.cmd` |
| Orchestrator | `tools/bsr_magisk.ps1` (Prep/Data/Clean/Finalize/Verify/Undo, gate + flag) |
| Engine (patch, conf, ext4, Root/Unroot) | `tools/bsr_engine.ps1` |
| Build/embed helper | `tools/build.ps1` |
| Bootstrap su + bindmount templates | `tools/su_src/` |
| Magisk databin / artifacts (from APK) | `tools/magisk_databin/`, `tools/magisk_artifacts/` |
| Embedded debugfs bundle | `tools/debugfs/` |
| Magisk APK + working reference | `Working Example & Fix/` |
| Proven dev/test scripts | `tests/` (gate‑magisk, remove‑bsr‑su, rootvhd‑hook, test‑magiskprep‑offline, …) |
| RE of the original exe | `recovered/BstkRooter/` |
| Superseded code (reference only) | `archive/` (see `archive/README.md`) |
| Docs | `docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`, `docs/RUNBOOK.md` |
| HD‑Player patch site | file `0xB46E8` / va `0x1400B52E6` (`74 5B → 90 90`) |
| Backups | `Root.vhd.bsrbak` (pristine), `Root.vhd.magiskgood`, `Rvc64.bstk.bsrbak` |
