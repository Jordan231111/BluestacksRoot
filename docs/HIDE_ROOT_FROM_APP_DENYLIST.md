# Hide root from an app with ReZygisk — the DenyList SQLite fix (verified end‑to‑end)

How to make a root‑detecting app (e.g. **LIAPP**‑protected games) launch on a **Magisk Kitsune + ReZygisk**
BlueStacks instance, by putting the app on ReZygisk's **DenyList** so its Magisk mounts are unmounted.

This was proven end‑to‑end on **BlueStacks `Tiramisu64_9` (Android 13, adb port 5645)** with
**Idle Poseidon** (`com.mouseduck.seawar`, LIAPP v5.1.1.200): before the fix the game detected root and
exited; after the fix ReZygisk unmounts root for it and it boots to its login screen and stays up.

> **The one thing to remember:** the **Magisk app's hide toggle does NOT do this** in this setup — it writes
> to the wrong table. You must put the app in the **`denylist`** table, and the only non‑GUI way on this
> Kitsune build is `magisk --sqlite`. See [Why the Magisk UI doesn't work](#why-the-magisk-ui-toggle-doesnt-work-but-the-sqlite-insert-does).

---

## TL;DR — the fix

From the host, with the instance running and rooted (substitute your adb port and package):

```powershell
# 1. add the app to the DenyList table ReZygisk actually reads
adb -s 127.0.0.1:5645 shell su -c "magisk --sqlite 'INSERT OR REPLACE INTO denylist (package_name,process) VALUES (\"com.mouseduck.seawar\",\"com.mouseduck.seawar\")'"

# 2. reboot the instance (ReZygisk's daemon reads the DenyList once, at boot)
adb -s 127.0.0.1:5645 reboot
```

After it boots, launch the app. Done. No Magisk‑app toggle, no "Enforce DenyList", no MagiskHide needed.

> ⚠️ On BlueStacks, `adb reboot` sometimes leaves the guest stuck (HD‑Player stays up but the guest never
> re‑binds adb). If that happens, close the instance from the Multi‑Instance Manager and reopen it — that
> cold‑boots it cleanly. The DenyList row is on disk (`magisk.db`) and survives.

> **Note — `blueStackRoot` v10+ bundles a Kitsune build that already fixes the GUI path.** If you rooted with
> the custom build shipped since CHANGELOG v10, Magisk's deny module stores entries in the `denylist` table,
> so you can simply **tick the app in the Magisk app's DenyList UI** (no SQL, no reboot quirk) and ReZygisk
> picks it up. The `magisk --sqlite` method above still works everywhere and is what you need on **stock /
> older** Kitsune, where the UI writes to `hidelist` (which ReZygisk ignores).

---

## Applies to

| Component | Value (verified) |
|---|---|
| Magisk | **Kitsune Mask / Magisk Delta v31** (`magisk -c` → `31.0-kitsune`, 31000) |
| Zygisk impl | **ReZygisk v1.0.0** (module id `rezygisk`) — replaces Magisk's built‑in Zygisk |
| Xposed | Vector / LSPosed (`zygisk_vector`) — present, not required for this fix |
| Built‑in Magisk Zygisk | **OFF** (ReZygisk provides Zygisk instead) |

If your build matches the first two rows, this procedure applies verbatim.

---

## Why it breaks "after working for a while"

The DenyList lives in `/data/adb/magisk.db` → table `denylist`. It is **wiped whenever the Magisk DB is
recreated**, which happens when you **re‑run the rooting tool** (fresh `magisk.db`) or, often, when you
**reinstall the target app**. Symptom: it "worked for several launches, then stopped." The row is simply
gone, so ReZygisk has nothing to hide and the app sees root again.

Re‑applying is just the [TL;DR](#tldr--the-fix) two‑liner.

---

## Step‑by‑step for ANY app

### 1. Find the package name
```bash
adb -s 127.0.0.1:5645 shell pm list packages -3 | sort   # third‑party packages
# or search: ... pm list packages | grep -i <keyword>
```

### 2. Find the process name(s) — usually you don't need to
ReZygisk's match query is a **prefix match on the `process` column**:
```sql
SELECT 1 FROM denylist WHERE "<runtime process>" LIKE process || '%' LIMIT 1
```
Because of the trailing `%`, a **single row with `process = <package>` also covers every child process**
(`com.pkg`, `com.pkg:gpu`, `com.pkg:push`, …). So for the vast majority of apps you only need one row:
`(package, package)`.

Only if an app runs a child process whose name does **not** start with the package name (rare) do you need
an extra row. To check what an app actually spawns, launch it and list its processes by uid:
```bash
uid=$(adb -s 127.0.0.1:5645 shell su -c "grep <pkg> /data/system/packages.list" | awk '{print $2}')
adb -s 127.0.0.1:5645 shell su -c "for p in \$(pgrep -u $uid); do tr '\0' ' ' </proc/\$p/cmdline; echo; done"
```

### 3. Insert the DenyList row
Cleanest from an interactive shell (avoids host quoting pain):
```bash
adb -s 127.0.0.1:5645 shell
su
magisk --sqlite "INSERT OR REPLACE INTO denylist (package_name,process) VALUES ('com.mouseduck.seawar','com.mouseduck.seawar')"
magisk --sqlite "SELECT * FROM denylist"     # verify the row is there
```

### 4. Reboot the instance
ReZygisk's daemon (`zygiskd`) reads the DenyList **once, at boot** (post‑fs‑data). Editing the table while
it's running has **no effect until the daemon re‑initializes** — so reboot (or cold‑restart) the instance.

### 5. Verify (see below) and launch the app.

---

## Why the Magisk UI toggle doesn't work, but the SQLite insert does

This is the confusing part, and it's **not a random bug** — it's two tables and a mode mismatch. Verified
on the live instance:

**Magisk Kitsune has three independent app lists, in three tables of `magisk.db`:**

| Table | Belongs to | Who enforces it |
|---|---|---|
| `hidelist` | **MagiskHide** (classic ptrace hide) | Magisk core, only when `settings.magiskhide = 1` |
| `denylist` | **Zygisk DenyList** | **ReZygisk** (reads this table directly) |
| `sulist` | SuList (whitelist) mode | ReZygisk, only when `settings.sulist = 1` |

**What the Magisk app's hide toggle actually writes.** ReZygisk **disables Magisk's own built‑in Zygisk**
(its `service.sh` literally relabels itself "❌ Disable Magisk's built‑in Zygisk"). With built‑in Zygisk
**off**, the Magisk Kitsune app falls back to presenting **MagiskHide**, so when you tick an app in the
app's hide list it writes the row into **`hidelist`** — *not* `denylist`.

We confirmed this directly: after only ever inserting into `denylist` via SQL, the `hidelist` table already
contained `com.mouseduck.seawar` — that row could only have come from an **earlier Magisk‑app toggle**. So
the app's toggle *was* doing something; it was just filling the wrong table:

```
denylist  → com.mouseduck.seawar   (our SQL insert — the table ReZygisk reads)   ✅ works
hidelist  → com.mouseduck.seawar   (the Magisk UI toggle — MagiskHide's table)   ❌ ReZygisk never reads it
```

**So the UI toggle fails for two compounding reasons:**
1. **Wrong table.** It populates `hidelist` (MagiskHide); ReZygisk only reads `denylist`.
2. **Even MagiskHide is off.** `settings.magiskhide = 0`, so the `hidelist` it wrote isn't being enforced by
   anything either.

**Why the SQLite insert works.** It writes straight into `denylist`, which is the exact table — and column,
with the exact prefix‑match semantics — that ReZygisk's daemon queries on every process spawn. It bypasses
the app's Zygisk‑mode gating entirely.

> Side note: the `magisk --denylist ...` **CLI applet is stripped out of this Kitsune build** (only `su` and
> `resetprop` are exposed). So even from a shell, `magisk --sqlite` is the only way to edit the DenyList
> without the GUI.

---

## Why "Enforce DenyList" and the MagiskHide toggle are irrelevant here

ReZygisk does **not** consult `settings.denylist` ("Enforce DenyList"). Pulled straight from the `zygiskd64`
binary, the only settings key it reads is `sulist` (to choose DenyList‑mode vs SuList‑mode):

```
SELECT 1 FROM denylist WHERE "%s" LIKE process || '%' LIMIT 1     ← decides hide/unmount
SELECT 1 FROM sulist   WHERE process="%s" LIMIT 1
select value from settings where key = 'sulist'                   ← only settings key it reads
```

Empirically:
- `settings.denylist` (Enforce DenyList) **resets to `0` on every boot** in this setup (built‑in Zygisk is
  off), and ReZygisk hides the app anyway. Toggling it on is pointless and doesn't stick.
- `settings.magiskhide = 0` and that's fine — MagiskHide is a different mechanism we're not using.

The **only** state that matters is: *is there a matching row in the `denylist` table when the daemon boots?*

---

## Verifying it worked

Right after launching the app, check the ReZygisk daemon log — this line is the proof it unmounted root for
the app's process:

```bash
adb -s 127.0.0.1:5645 shell su -c "logcat -d | grep -E 'Unmounting root|Unmounted /system/bin/magisk'"
```
Expected:
```
zygiskd64: [magisk] Unmounting root
zygiskd64: [magisk] Unmounted /sbin/magisk64 ... /system/bin/magisk ... /sbin
zygiskd64: [Magisk] Magisk Kitsune detected ... caching clean namespace fd.
```

Then confirm the app actually survives (root‑detectors usually kill within ~15 s of launch):
```bash
adb -s 127.0.0.1:5645 shell su -c "pidof <pkg>"        # still returns a pid after 20–30 s = good
adb -s 127.0.0.1:5645 exec-out screencap -p > check.png # eyeball it: real screen, not a block dialog
```

A handy negative signal: if `zygisk_vector` (LSPosed) is installed, the line
`VectorZygiskBridge: ... callerUid=<app uid>` in logcat means the module is **still being injected** into
the app — i.e. it is **not** being denylisted yet (fix not applied / not rebooted). Once denylisted, ReZygisk
neither injects modules nor leaves Magisk mounted for that process.

---

## Quick reference

```bash
# add (covers all child processes via prefix match)
magisk --sqlite "INSERT OR REPLACE INTO denylist (package_name,process) VALUES ('PKG','PKG')"
# list
magisk --sqlite "SELECT * FROM denylist"
# remove
magisk --sqlite "DELETE FROM denylist WHERE package_name='PKG'"
# ...then reboot the instance.
```

| Symptom | Cause | Action |
|---|---|---|
| App detects root again after a while | DenyList wiped by re‑root or app reinstall | Re‑insert the row + reboot |
| Edited DenyList, still detected | Daemon hasn't re‑read | Reboot / cold‑restart the instance |
| Magisk‑app hide toggle "does nothing" | It wrote to `hidelist`, not `denylist` | Use the SQL insert into `denylist` |
| `magisk --denylist` says "invalid applet" | CLI stripped in Kitsune | Use `magisk --sqlite` |

---

*Scope: this covers hiding **root/Magisk** from an app on BlueStacks via ReZygisk. Emulator‑fingerprint
detection (qemu props, RIL strings, device files, etc.) is a separate layer — see the MuMu notes — and is
not addressed by the DenyList.*
