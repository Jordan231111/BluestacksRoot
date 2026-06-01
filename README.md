# Root BlueStacks 5 with Magisk — blueStackRoot (Android 9, 11 & 13)

<p align="center">
  <a href="https://github.com/Jordan231111/BluestacksRoot/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/Jordan231111/BluestacksRoot?style=flat&logo=github"></a>
  <a href="https://github.com/Jordan231111/BluestacksRoot/network/members"><img alt="Forks" src="https://img.shields.io/github/forks/Jordan231111/BluestacksRoot?style=flat&logo=github"></a>
  <img alt="BlueStacks" src="https://img.shields.io/badge/BlueStacks%205-5.22.169%20%E2%9C%93-blue">
  <img alt="Magisk" src="https://img.shields.io/badge/Magisk-Delta%20v27.2--kitsune--4-brightgreen">
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey"></a>
</p>

**Root BlueStacks 5 / MSI App Player with real Magisk — from one file, with no traces left behind.**
**Run `blueStackRoot.cmd` as administrator, pick your Android version, and you're rooted.**
**The genuine Magisk Delta (Kitsune) APK is now bundled inside the `.cmd` itself** — no separate Magisk
download, no other files, nothing to install. Works on the latest BlueStacks (5.22.169).

---

## ⚡ Quick Start

Works on the 64-bit BlueStacks instances — **Android 9, 11, and 13**.

**⬇️ [Download `blueStackRoot.cmd`](https://github.com/Jordan231111/BluestacksRoot/releases/download/v7/blueStackRoot.cmd)** — one file (~20 MB) with the **real Magisk APK embedded inside** — nothing else to download. *(All versions: [Releases page](https://github.com/Jordan231111/BluestacksRoot/releases).)*

1. **First, open the instance you want to root at least once** — launch it from the Multi-Instance Manager so BlueStacks finishes creating it.
2. **Right-click `blueStackRoot.cmd` → Run as administrator.** (If Windows shows a blue **"Windows
   protected your PC"** box, click **More info → Run anyway** — see
   [Is this safe?](#-is-this-safe-will-my-antivirus-flag-it) below.)
3. A small menu opens. **Find your instance's Android version below, type that number, and press Enter:**

   | If your instance is… | Type | What happens |
   |---|:---:|---|
   | **Android 9** (Pie64) | **1** | Magisk is installed and set up **automatically** — just wait for **`VERIFY PASS`** ✅ |
   | **Android 11** (Rvc64) | **2** | Magisk is installed and set up **automatically** — just wait for **`VERIFY PASS`** ✅ |
   | **Android 13** (Tiramisu64) | **3** | Magisk is installed and set up **automatically** — just wait for **`VERIFY PASS`** ✅ |

That's it — every version installs **Magisk** as the final root, fully automatically. Open the **Magisk
app** to confirm it shows **Installed**, then grant root to any app you like. BlueStacks' own "root access"
toggle is safely turned back **off**, and no leftover files are left behind for games to detect.

> **💡 Not sure which Android version your instance is?** It's shown next to each instance in the
> BlueStacks **Multi-Instance Manager** (or open the instance → **Settings → About phone**).

> **💡 Seeing "Ramdisk: No" in Magisk?** That's totally fine and expected on BlueStacks — root works
> perfectly without it. Don't go looking for a "ramdisk fix".

<details>
<summary><b>How do I undo / unroot? (click here)</b></summary>

&nbsp;

Every Android version has its **own** undo number, so unrooting only ever affects the instance you pick —
there's no single "undo everything" button. In the menu:

| Your instance's Android version | To root | To undo |
|---|:---:|:---:|
| Android 9 (Pie64) | 1 | **4** |
| Android 11 (Rvc64) | 2 | **5** |
| Android 13 (Tiramisu64) | 3 | **6** |

The undo options are **per-instance** and multi-instance safe: they remove Magisk from just that one
instance and leave any other rooted instances working. The menu also has **7** for a *full host scrub*
(restore the master `Root.vhd` to factory **and** un-patch `HD-Player.exe` — unroots every instance of the
chosen version), **8** to point the tool at a custom BlueStacks folder, and **0** to exit.

</details>

### Run a rooted *and* an unrooted Android instance side by side
Root each Android instance you want — every instance you *don't* root stays 100% clean on its own (no
root, no Magisk app, nothing for games to detect). Then **launch them together from the Multi-Instance
Manager** and they run side by side. Want to unroot just one later? Undo that single instance
all the others keep working, untouched.

📖 Full walkthrough & rollback: **[`docs/RUNBOOK.md`](docs/RUNBOOK.md)** · Deep technical writeup:
**[`docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`](docs/BLUESTACKS_ROOTING_DEEP_DIVE.md)**

---

## 🛡️ Is this safe? Will my antivirus flag it?

**Short answer: yes, it's safe — and yes, your antivirus or SmartScreen might warn you anyway.** That's a
*false positive* common to **every** rooting/emulator tool: the file is an unsigned `.cmd` that modifies
BlueStacks and carries binaries inside it. Heuristic scanners flag that pattern. Here's why you can trust it:

- **100% open source.** Every line of logic is plain, readable PowerShell and batch — right here in this
  repo. Read [`tools/bsr_magisk.ps1`](tools/bsr_magisk.ps1) and
  [`tools/bsr_engine.ps1`](tools/bsr_engine.ps1); those are the *exact* scripts embedded in the `.cmd`.
  Nothing is obfuscated or "encrypted" — unlike the closed-source rooter binaries floating around.
- **The big base64 blocks are not a virus — they're just files, bundled so you only download one thing.**
  The `.cmd` carries five things between clearly-labelled `__BSR_*__` markers:

  | Embedded blob | What it actually is | How to verify |
  |---|---|---|
  | `__BSR_ENGINE__` / `__BSR_MAGISK__` | The two PowerShell scripts above (plain text) | Diff against `tools/*.ps1` in this repo |
  | `__BSR_DFS__` | `debugfs` from the standard Cygwin **e2fsprogs** suite | Standard open-source ext4 tool |
  | `__BSR_SU__` / `__BSR_BSRSU__` | Tiny `su` binaries used only *during* install, then **erased** | Source in [`tools/su_src/`](tools/su_src) |
  | `__BSR_APK__` | The **official, unmodified Magisk Delta (Kitsune Mask)** APK | SHA-256 below |

- **The Magisk APK is the real one.** Its SHA-256 is
  `818cfa02783ddae573cc953450fbc39ec3e5164b66e517c657ba11cf90963a89` (12,770,643 bytes) — the genuine
  [Magisk Delta build by HuskyDG](https://github.com/HuskyDG/magisk-files). You're trusting Magisk, not me.
- **Verify it yourself in 30 seconds.** Scan the file on [VirusTotal](https://www.virustotal.com/), or
  extract any embedded blob and check its hash — open the `.cmd` in any text editor and the `__BSR_*__`
  markers are right there. The whole point of this project is that you *don't* have to trust a black box.

---

## ❓ "Android system has been illegally tampered with" — instance shuts down after rooting?

If BlueStacks shows **"the Android system has been illegally tampered with and does not meet security
requirements"** (or **"Android system doesn't meet security and will be shutdown"**) and your **instance
keeps closing** the moment you enable root, that's the **disk-integrity / anti-tamper check** added in
**BlueStacks 5.22+**. Almost every other guide tells you to **downgrade to 5.22.130.1019** — **you don't
have to.**

`blueStackRoot` applies a **one-byte HD-Player anti-tamper patch** that bypasses the disk-integrity check,
so you can **root the *latest* BlueStacks (5.22.169) without downgrading** — and it installs **real Magisk**
with **no traces**, not a detectable classic `su`. If `bst.feature.rooting` keeps **reverting to `0`** on
launch, that's the same anti-tamper system, and this tool handles it for you. Full technical breakdown:
[`docs/BLUESTACKS_ROOTING_DEEP_DIVE.md`](docs/BLUESTACKS_ROOTING_DEEP_DIVE.md) §2 (the single-byte patch).

## 🔧 How the Magisk path works (the hard part)

<details>
<summary><b>Click to expand the technical deep-dive</b></summary>

The same automated pipeline roots Android 9, 11, and 13 (it's been run end-to-end on all three).
BlueStacks 5.22 defeats the classic "inject `su` into the disk" trick: it overmounts `/system/xbin` from
`/data`, ships a host-gated daemon-su, and resets `bst.feature.rooting`. The Magisk app's *Install to
System* button also leaves `/data/adb/magisk` **empty**, so the daemon aborts with "environment
incomplete". This tool solves all of that:

1. **One-byte patch** on `HD-Player.exe` (NOP the disk-integrity `JZ`, `74 5B → 90 90`) so a modified
   `Root.vhd` is accepted and a tampered `/system` boots. It's a version-proof byte-scan; verified on 5.22.169.
2. **Offline write:** using the embedded `debugfs`, it writes Magisk's `/system` payload + a **gated**
   `bootanim.rc` directly into `Root.vhd` — no Windows ext4 driver needed.
3. **The breakthrough:** it boots once with a tiny **bootstrap su** to populate **`/data/adb/magisk`** (the
   step the Magisk app can't finish on BlueStacks) and set the grant policy, then **completely removes the
   bootstrap su** and restores the stock files.
4. **Per-instance gate:** all instances share one master `Root.vhd`, so the boot hooks live on the master
   and would otherwise run everywhere. Instead, `bootanim.rc` calls `bsr_boot.sh`, which **no-ops unless
   that instance carries `/data/adb/.bsr_root`** on its own `/data`. Result: only flagged instances get
   Magisk; the rest get **no daemon, no su, no app** — and the master stays `Readonly` so every instance
   can run at once.

**What persists vs. what's erased.** Only four things change from factory: the 2-byte `HD-Player.exe`
patch, the `enable_root_access` conf flag (flipped on for install, back off after), Magisk's `/system`
files, and `/data/adb/magisk`. The bootstrap su and hijacked `bindmount` are added *then fully erased*.
Net new su on the device: **only Magisk's.**

</details>

## 🧩 Optional: Zygisk + LSPosed + CorePatch (in [`modules/`](modules))

Once an instance is rooted with Magisk (above), you can optionally add the **Zygisk → LSPosed → CorePatch**
stack to run Xposed modules and sideload **modified / unsigned APKs**. Compatible builds are bundled in
[`modules/`](modules) so you don't have to hunt for versions that work together on Magisk Delta:

| File | What it is | How to install |
|---|---|---|
| [`NeoZygisk-v2.3-275-release.zip`](modules/NeoZygisk-v2.3-275-release.zip) | **Zygisk** implementation ([JingMatrix/NeoZygisk](https://github.com/JingMatrix/NeoZygisk)) — provides the Zygote injection that LSPosed needs on Magisk Delta | Magisk app → **Modules → Install from storage** → reboot |
| [`Vector-v2.0-3021-Release.zip`](modules/Vector-v2.0-3021-Release.zip) | **LSPosed** Zygisk build ([JingMatrix/LSPosed](https://github.com/JingMatrix/LSPosed), released as "Vector") — the Xposed framework | Flash in Magisk **after** NeoZygisk → reboot |
| [`CorePatch-4.9.apk`](modules/CorePatch-4.9.apk) | **CorePatch** ([LSPosed/CorePatch](https://github.com/LSPosed/CorePatch)) — lets you install **unsigned / modified APKs** by disabling signature verification | Install the APK → enable it in **LSPosed → Modules** → reboot |

**Order matters:** root with Magisk → flash **NeoZygisk** (turn Zygisk on) → flash **Vector / LSPosed** →
install **CorePatch** and enable it in LSPosed. Confirm each step works (Magisk shows the module active /
LSPosed shows "Active") before moving to the next, and reboot the instance between flashes.

<details>
<summary><b>Verify the downloads (SHA-256)</b></summary>

&nbsp;

```
5c84df9f962c04855b3523a3a75022cf5e4f3ad3dfd94794ed92b43e911f3b9a  NeoZygisk-v2.3-275-release.zip
d5e39669c02c2c699ab948eb8f3639b348eefb7749553224a9c62fa4a2f2dc18  Vector-v2.0-3021-Release.zip
1bdc47d5b48afffd37948a9f5638ae6a5f3d4d02ca01ae36143588284b979996  CorePatch-4.9.apk
```

These are the genuine upstream release builds — cross-check the hashes against each project's Releases page.

</details>

## 💻 Requirements
Windows + BlueStacks 5 (nxt) or MSI App Player, run as Administrator. **Nothing to download** — PowerShell
5.1 (built into Windows) runs the embedded engine, and `HD-Adb.exe` ships with BlueStacks.

## 🎥 Video tutorial
▶ **[Watch the walkthrough on YouTube](https://www.youtube.com/watch?v=BfxGGTDiESg)** — the current
one-file Magisk flow (Android 9 / 11 / 13).

<sub>Earlier junction-based method (legacy BlueStacks ≤ 5.21.x): [older video](https://youtu.be/LOhKGxuhLrU).</sub>

## 🧰 For developers (build & tests)
The `.cmd` embeds `tools/bsr_engine.ps1` + `tools/bsr_magisk.ps1` + `tools/debugfs/` + `tools/su_src/bsr_su`
+ the Magisk APK between marker lines. Proven dev/test scripts live in [`tests/`](tests) (e.g.
`test-magiskprep-offline.ps1` byte-verifies the offline `/system` write; `gate-magisk.ps1`,
`remove-bsr-su.ps1`). `tools/build.ps1` is the legacy assembler for the classic-su build. Retired
approaches (junctions, the integrity-bypass scripts, etc.) are kept for reference in
[`archive/`](archive). The fully reverse-engineered closed-source predecessor lives in `recovered/BstkRooter/`.

## ☕ Support / Donation
If this saved you time, a coffee is hugely appreciated — it keeps the last open-source BlueStacks rooter alive:
- https://ko-fi.com/yejordan
- https://buymeacoffee.com/yejordan

## 📌 Other information
- **Contributing:** open a PR with a clear explanation (and screenshots if relevant). Report issues with
  clear steps to reproduce and a video if possible.
- **Supported instances (Android 9 / 11 / 13):** the tool uses my bundled Magisk Delta (Kitsune), or the
  build at [HuskyDG/magisk-files](https://github.com/HuskyDG/magisk-files/releases/tag/1707294287). The
  Android-9 (Pie64), 11 (Rvc64), and 13 (Tiramisu64) paths are identical and fully automated — all three
  have been run end-to-end to a clean `VERIFY PASS`.
- **Android 7 (Nougat32) is not supported.** It is a 32-bit instance, and every binary this tool bundles
  (the `su` and all Magisk binaries) is 64-bit `x86_64`, so root cannot run there. If you need root,
  recreate the instance as a 64-bit Android (9/11/13) in the Multi-Instance Manager.
- **Old/legacy files** are archived [here](https://mega.nz/folder/SQBRHSZQ#pEgMXysWkkTm5Z8dxsNaNQ).
- **Manual method** this is based on:
  [XDA forums](https://xdaforums.com/t/bluestacks-tweaker-6-tool-for-modifing-bluestacks-2-3-3n-4-5.3622681/post-89306676).
  Note that the manual method may **not** work anymore due to hidden services that must be killed — this
  script handles that for you.

## 📄 License
Licensed under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License.
See [LICENSE](./LICENSE) or visit http://creativecommons.org/licenses/by-nc-nd/4.0/.

---

<sub>Keywords: root BlueStacks, BlueStacks root, root BlueStacks 5, how to root BlueStacks, BlueStacks
Magisk, Magisk Delta BlueStacks, Kitsune Magisk, BlueStacks Zygisk, root BlueStacks 5.22, BlueStacks 5 root
2026, root Android emulator, BlueStacks rooted, MSI App Player root, install unsigned APK on BlueStacks,
BlueStacks illegally tampered, Android system doesn't meet security requirements, BlueStacks tampering
detected, BlueStacks instance keeps closing after root, BlueStacks disk integrity check bypass, root latest
BlueStacks without downgrading, fix illegally tampered BlueStacks, bst.feature.rooting reverts to 0,
"disk file have been illegally tampered with", Verified the disk integrity, BlueStacks disk integrity check,
root BlueStacks 5.22.169, root BlueStacks latest version 2026.</sub>
