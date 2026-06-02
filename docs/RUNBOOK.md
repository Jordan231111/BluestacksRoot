# RUNBOOK — Make Magisk the sole root on BlueStacks 5 (Android 9 / 11 / 13), no traces

This is the full, do‑it‑yourself runthrough. It takes a clean (or messy) BlueStacks instance to the
**proven end state**: Kitsune Mask v31 is the only working root (`su → magisk`, `uid=0`), the app
shows **Installed** with no warning, emulator root is OFF, and there is **zero trace** of any bootstrap su.

> The steps below are written for `Rvc64` (Android 11), but the pipeline is **version‑agnostic** and the
> exact same flow has been run end‑to‑end to `VERIFY PASS` on **Pie64 (Android 9)** and **Tiramisu64
> (Android 13)**. Substitute the instance name (and its own `Root.vhd`/adb port) throughout.

Everything here is built from steps proven on this machine; the one offline step (writing Magisk's
`/system` files into Root.vhd) is unit‑tested byte‑for‑byte (`tests/test-magiskprep-offline.ps1`, PASS).

---

## 0. Prerequisites (once)

- **Run as Administrator** (offline VHD editing needs it).
- **Matching Magisk APK present.** Use the same build you want installed, e.g.
  `Working Example & Fix\MagiskMyStableBuild.apk`. This single file provides both the manager app
  and every Magisk binary. (A different Magisk version → pass that APK; nothing else changes.)
  > The bundled `MagiskMyStableBuild.apk` is a **custom Kitsune v31 build** (a 3-line `denylist`-table patch so
  > Magisk's in-app DenyList works with ReZygisk/NeoZygisk) — see the README "Is this safe?" section and
  > CHANGELOG v10. To use stock upstream Magisk instead, just pass its APK here.
- **Know your instance name** (default `Rvc64`) and paths:
  - Root.vhd: `C:\ProgramData\BlueStacks_nxt\Engine\<Instance>\Root.vhd`
  - conf: `C:\ProgramData\BlueStacks_nxt\bluestacks.conf`
  - BlueStacks install: `C:\Program Files\BlueStacks_nxt`
- **Backups (auto + manual).** A pristine `Root.vhd.bsrbak` and a Magisk‑good `Root.vhd.magiskgood`
  already exist. If starting fresh, make one: copy `Root.vhd` → `Root.vhd.bsrbak` while BlueStacks is closed.

> **Ramdisk note:** `Ramdisk: Yes` *or* `No` in the Magisk app is fine — it does **not** matter here.
> Do not chase a "ramdisk fix"; it is irrelevant on BlueStacks.

---

## 1. The one‑shot run (recommended)

### 1a. Single file — `blueStackRoot.cmd` (the dream: nothing else needed)
The `.cmd` is fully self‑contained (engine + debugfs + bootstrap su + the orchestrator + the **Magisk APK** are all embedded — 20 MB). Copy it anywhere and:

1. **Right‑click → Run as administrator** (it self‑elevates too).
2. Pick **option 3 — `Apply … Android 11 Rvc64`**. On Rvc64 this runs the full **Magisk‑as‑final‑root** pipeline automatically.
3. Wait for `VERIFY PASS`. Done. (Option **6** = `Undo … Android 11 Rvc64` fully restores factory.)

No other files, no internet. (If you drop a different `Magisk*.apk` next to the `.cmd`, it uses that instead of the embedded one.)

### 1b. Or run the orchestrator directly (from the repo)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 `
    -Action Auto -Instance Rvc64 `
    -MagiskApk "Working Example & Fix\MagiskMyStableBuild.apk"
```

Either way, the pipeline runs and ends with a self‑verify:

| Phase | Disk activity | What it does |
|---|---|---|
| **Prep** (offline) | 1 Root.vhd carve+writeback (~1–2 min) | HD‑Player anti‑tamper patch; conf `enable_root_access=1`; writes Magisk `/system` files + hijacked `bootanim.rc` + bootstrap `bsr_su` + hijacked `bindmount` |
| **Data** (online) | runtime `/data` only | boots; `adb install` the APK; via bootstrap su populates `/data/adb/magisk` (busybox + ABI binaries + scripts) and sets the grant policy |
| **Clean** (offline) | 1 Root.vhd carve+writeback | removes `bsr_su`; restores the **stock** `bindmount` |
| **Finalize** | conf only | `enable_root_access=0` (emulator root OFF) |
| **Verify** (online) | read‑only | cold boots; checks `su → magisk` `uid=0`, `/system/xbin/su` absent, `bsr_su` sweep clean |

Total wall time ≈ 8–12 min (two cold boots + two carves). When it prints
`[+] VERIFY PASS: Magisk is the sole root; no bsr_su traces.` you are done.

---

## 2. Step‑by‑step (if you prefer to drive it yourself)

Run the same script one phase at a time (lets you inspect between steps):

```powershell
$apk = "Working Example & Fix\MagiskMyStableBuild.apk"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 -Action Prep     -Instance Rvc64 -MagiskApk $apk
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 -Action Data     -Instance Rvc64 -MagiskApk $apk
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 -Action Clean    -Instance Rvc64
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 -Action Finalize -Instance Rvc64
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bsr_magisk.ps1 -Action Verify   -Instance Rvc64
```

After **Data** you can open the Magisk app — it should show *Installed* with **no "Abnormal State"** dialog
(if you see that dialog, you ran an older engine `Root`; it is fixed automatically by **Clean** which removes
the competing `/system/xbin/su`). After **Finalize + Verify**, emulator root is off and Magisk stands alone.

---

## 3. Manual verification (anytime)

With the instance booted (`HD-Adb.exe` is in the BlueStacks dir):

```bash
ADB="/c/Program Files/BlueStacks_nxt/HD-Adb.exe"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
S=$("$ADB" devices | awk '/device$/{print $1;exit}')

"$ADB" -s $S shell 'su -c id'                       # -> uid=0(root)  (Magisk)
"$ADB" -s $S shell 'readlink /system/bin/su'        # -> ./magisk
"$ADB" -s $S shell 'su -c "ls /system/xbin/su"'     # -> No such file or directory  (good)
"$ADB" -s $S shell 'getprop bst.instance.Rvc64.enable_root_access'   # -> 0
# Magisk daemon + app:
"$ADB" -s $S shell 'su -c "magisk -c"'              # -> 31.0-kitsune ...
```

In the Magisk app: **Magisk → Installed — Kitsune Mask v31**, no warning dialog. (Grant Superuser to apps
from the app's Superuser tab as usual; `adb shell` is already allowed by the policy.)

---

## 4. Safety, rollback, and good hygiene

- **Don't revert the HD‑Player patch.** It must stay applied or BlueStacks rejects the modified Root.vhd
  (and Magisk's `/system` changes) and root silently disappears. The patch is idempotent and keeps a
  `HD-Player.exe.bak`.
- **Graceful shutdown.** Close the instance window / let it `sync` rather than force‑killing repeatedly;
  repeated hard kills corrupt Android settings XMLs (`/data/local/tmp/corrupt_files_deleted` — Android
  self‑heals them; it is **not** anti‑tamper). The script syncs before stopping.
- **Unroot one instance (option 6 / `-Action Undo`):** uninstalls the Magisk app, removes that
  instance's `/data/adb` + root flag, sets `enable_root_access=0`. The **shared master and HD‑Player
  patch are left intact** so any *other* rooted instances keep working (multi‑instance safe).
- **Full factory scrub (all instances):** `tools\bsr_magisk.ps1 -Action Undo -Instance Rvc64 -Full` —
  additionally restores `Root.vhd` from the pristine `Root.vhd.bsrbak` and un‑patches `HD-Player.exe`.
  Result: stock BlueStacks, no instance rooted.
- **Manual rollback:** close BlueStacks, then `copy /Y Root.vhd.bsrbak Root.vhd`, restore
  `HD-Player.exe.bak` over `HD-Player.exe`, set the conf flag to `0`. `Root.vhd.magiskgood` restores the
  Magisk‑good state without re‑running the pipeline.
- **`.bstk` disk modes are left factory** (`Root.vhd=Readonly`), so no "writable system" trace remains;
  the Magisk files live inside the Root.vhd file itself and are read read‑only at runtime.

---

## 5. What "minimal read/writes" means here

Persistent changes from factory, and nothing more:

| Change | Where | Why |
|---|---|---|
| 2 bytes (`74 5B → 90 90`) | `HD-Player.exe` (+ `.bak`) | accept modified Root.vhd / boot tampered `/system` |
| `enable_root_access` 1→(install)→0 | `bluestacks.conf` | drive bootstrap su during install, off afterward |
| 6 Magisk files + `bootanim.rc` | Root.vhd `/system/etc/init/...` | Magisk system‑mode payload + init wiring |
| `/data/adb/magisk/*` + policy | Data.vhdx (runtime) | **the breakthrough** — makes `magiskd` start |

Transient (added then fully erased): `bsr_su` + hijacked `bindmount` (bootstrap root). Net new su on the
device after completion: **only Magisk's**. No DiskRW, no engine‑su, no daemon‑su of ours.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap su not root` during **Data** | patch didn't apply, or `enable_root_access≠1`, or `bindmount` not hijacked | re‑run **Prep**; confirm `HD-Player.exe` = `84 C0 90 90` |
| Magisk app: *Magisk environment incomplete* | `/data/adb/magisk` not populated | re‑run **Data** (it populates it) |
| Magisk app: *Abnormal State — a su binary not from Magisk* | a **competing `/system/xbin/su`** on the shared master (an old non‑Magisk/classic root, e.g. a prior engine root or the legacy live‑E2E) — Magisk's own su are `/system/bin/su`→magisk + `/sbin/su`→magisk | **fixed in v12**: Prep/Clean now scrub `/system/xbin/su` and Verify FAILS on any non‑Magisk su. To repair an existing instance, **re‑run Clean** (it removes the stray su) and reboot |
| `su` returns nothing / `uid=2000` after Finalize | shell took BlueStacks' gated su; Magisk daemon down | check `/cache/magisk.log`; ensure `/data/adb/magisk/busybox` exists |
| Instance won't boot after edits | HD‑Player patch missing | restore `HD-Player.exe.bak`, re‑apply patch, retry |
| `instance '<x>' did not boot / become adb‑reachable within N s` — **but the instance is up** (Home visible, Magisk installed) | a **system `adb` of a different version** (e.g. Android SDK platform‑tools **v1.0.41**) keeps killing BlueStacks' **HD‑Adb v1.0.36** server on the shared port 5037 — *"adb server version doesn't match this client; killing…"* — so `getprop` calls fail | **fixed in v11**: the tool pins HD‑Adb to its own server port (`ANDROID_ADB_SERVER_PORT=15037`) so the two never collide, and also tries the **live‑bound** adb port, not just `bluestacks.conf`. Update the tool. (Diagnose: compare `adb version` on `PATH` vs `"…\BlueStacks_nxt\HD-Adb.exe" version`.) |

---

## 7. Multiple instances — rooted + unrooted at the same time

**BlueStacks shares ONE master `Root.vhd`** across all instances (same disk UUID; each instance only
has its own `Data.vhdx`). Two consequences the tool handles:

1. **Simultaneous launch:** the master must be **`type="Readonly"`** in the `.bstk` (shareable). The old
   `DiskRW` set it `Normal` (exclusive) → a 2nd instance fails with `VBOX_E_INVALID_OBJECT_STATE`
   ("couldn't launch"). The Magisk pipeline keeps it **Readonly** (Finalize enforces it). `Data.vhdx`
   stays `Normal` (per‑instance).

2. **Per‑instance root gate:** because `/system` is shared, Magisk's boot hooks live on the master and
   would run on *every* instance (leaking `magiskd` + the Kitsune Mask app onto unrooted ones). So the
   hijacked `bootanim.rc` calls **`/system/etc/init/magisk/bsr_boot.sh`**, which **no‑ops unless the
   instance carries `/data/adb/.bsr_root`** on its own (per‑instance) `/data`.
   - **Rooted instance:** has `/data/adb/.bsr_root` + populated `/data/adb/magisk` → `magiskd`, `su`, app.
   - **Unrooted instance:** no flag → `bsr_boot.sh` exits → **no `magiskd`, no `/system/bin/su`, no app** → fully clean.

**To root one instance, leave others clean:** run option **3** on the target only (creates its flag).
Other instances stay unrooted automatically. Launch them all together (MultiInstance Manager, or
`HD-Player.exe --instance <name>` each) — verified: a rooted + an unrooted instance run concurrently.

**To unroot one instance** (option **6** / `-Action Undo -Instance <name>`): removes just that instance's
flag + `/data/adb` + app; the shared master and other rooted instances are untouched.
**Full host scrub** (un‑patch HD‑Player + restore the pristine master, unrooting ALL): `Undo -Full`.

> Note: a *truly pristine* `/system` on unrooted instances (zero dormant Magisk files) would require a
> dedicated per‑instance Root.vhd (separate VHD + UUID). The gate avoids that complexity: unrooted
> instances are **functionally** clean (no daemon/su/app); only inert, never‑executed files sit in the
> shared `/system/etc/init/magisk` (not in `$PATH`, never run without the flag).
