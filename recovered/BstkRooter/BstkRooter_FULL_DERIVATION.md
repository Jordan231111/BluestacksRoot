# BstkRooter.exe — Complete Reverse-Engineering & .cmd Reimplementation Guide

> Authoritative, byte-level derivation of `BstkRooter.exe` (Taaauu, "BSTK Rooter" v1.0.1) plus
> ready-to-paste **pure batch + PowerShell** reimplementations of every operation.
> Goal: you can rebuild the tool on Windows with **zero re-analysis**.
>
> Source binary: `BstkRooter.exe` (this folder)
> SHA-256 `cb8718999aa96c134a9f7cf0af3b633a8f8c32344b724fa3a5a2dbec3c50d187`
> Compiler: MSVC C++ (native x64), Dear ImGui 1.92.7 + D3D11 GUI, `requireAdministrator`.
> PDB: `G:\Git\bstk_re\BSTKRooter\build\BstkRooter.pdb`. lwext4 sources under `K:\Git\bstk_re\root_tool\lwext4\`.

---

## 0. Executive summary — what the exe actually does

It is a BlueStacks 5 / MSI App Player root utility with 6 buttons. Each button maps to one function:

| Button | Function | Net effect |
|---|---|---|
| Kill Emulator Processes | `0x14001d240` | `taskkill` HD-Player.exe, HD-MultiInstanceManager.exe, BstkSVC.exe |
| Fix Illegally Tampered | `0x1400203f0` | Patch `HD-Player.exe` disk-integrity check (NOP one `jz`) |
| Disk R/W | `0x140019f40` | In the instance `.bstk`: `type="Readonly"` → `type="Normal"` |
| Disk R/O | `0x140024680` | In the instance `.bstk`: `type="Normal"` → `type="Readonly"` |
| One Click Root | `0x14001d370` | Install a setuid `su` into the ext4 inside `Root.vhd` + edit `bluestacks.conf` |
| One Click Unroot | `0x14001f540` | Delete that `su` from the ext4 inside `Root.vhd` |

The **real** root mechanism is a statically-linked Android `su` binary (XOR-obfuscated RCDATA resource 101) written directly into the offline ext4 filesystem of `Root.vhd`, then `chmod 06755` + `chown 0:0`.

### ⚠️ Two corrections to the earlier `REPORT.md`
1. **Root writes `enable_root_access="0"`, NOT `"1"`.** There is literally **no `"1"` string anywhere in the binary** (verified by byte search for `22 31 22`). The conf flag is cosmetic here; root works because of the `su` binary. (See §6.)
2. **Unroot does NOT touch `bluestacks.conf` at all.** It only deletes the `su` file. (The earlier report claimed it set `="0"`.)

---

## 1. Embedded resources

`rabin2`/pefile resource directory:

| Resource | Type | Size | Meaning |
|---|---|---|---|
| `101` | RT_RCDATA | 2,012,872 | XOR-`0xA7` obfuscated Android `su` ELF |
| `102` | RT_RCDATA | 86,084 | 500×500 RGBA PNG (UI logo) |
| `1` | RT_ICON / RT_GROUP_ICON | — | app icon |
| `1` | RT_MANIFEST | 1530 | `requireAdministrator`, DPI-aware |
| `1` | RT_VERSION | — | version strings |

**Resource 101 deobfuscation = single-byte XOR `0xA7`.** Verified: `rcdata_101.bin` XOR `0xA7` == `embedded_su_decrypted` (already in this folder), an `ELF 64-bit LSB executable, x86-64, statically linked, with debug_info, not stripped`, target Android (`.note.android.ident`). Source marker `su.c`. SHA-256 of decrypted payload: `185106357cfc0d1db4b8efb033de863f437850437e0ef6b62630c05f291b4902`.

At runtime the exe does `FindResourceA(NULL, MAKEINTRESOURCE(101), RT_RCDATA)` → `LoadResource` → `LockResource`, then XOR-`0xA7` each byte into a temp file named **`bstk_su_c.tmp`** (placed via `GetTempPathA`), and uses that temp file as the `su` to copy into ext4.

> **You don't need to re-derive this** — `recovered/BstkRooter/embedded_su_decrypted` *is* the ready-to-use `su` binary. Just rename a copy to `su` and ship it next to your script.

### 1a. Recovered `su` behaviour (`su.c`)
```c
int main(int argc, char **argv){
    setgid(0); setuid(0);
    if (getuid()!=0){ fprintf(stderr,"su: permission denied (uid=%d)\n", getuid()); return 1; }
    setenv("HOME","/root",1); setenv("SHELL","/system/bin/sh",1);
    setenv("USER","root",1);  setenv("LOGNAME","root",1);
    setenv("PATH","/sbin:/system/sbin:/system/bin:/system/xbin:/vendor/bin",1);
    if (argc>=3 && !strcmp(argv[1],"-c")) execl("/system/bin/sh","sh","-c",argv[2],NULL);
    else if (argc>=2 && !strcmp(argv[1],"-")) execl("/system/bin/sh","-sh",NULL);
    else if (argc==1) execl("/system/bin/sh","sh",NULL);
    else { argv[0]="sh"; execv("/system/bin/sh",argv); }
    perror("su: exec failed"); return 1;
}
```
It is a classic permissive `su`: requires uid 0 (which it gets because the file is setuid-root), sets root env, drops into `/system/bin/sh`.

---

## 2. Discovery — registry & instances

### 2a. Registry (ANSI: `RegOpenKeyExA`/`RegQueryValueExA`)
| Display name | Registry key | Values read |
|---|---|---|
| `BlueStacks 5` | `HKLM\SOFTWARE\BlueStacks_nxt` | `InstallDir`, `DataDir` |
| `MSI App Player` | `HKLM\SOFTWARE\BlueStacks_msi5` | `InstallDir`, `DataDir` |

- **`InstallDir`** → where `HD-Player.exe`, `HD-MultiInstanceManager.exe`, `HD-Adb.exe` live (the integrity patch target).
- **`DataDir`** → where `bluestacks.conf` and `Engine\<instance>\...` live (disk + root targets).

> Your existing scripts read `UserDefinedDir`. `DataDir` and `UserDefinedDir` are normally the same value (`C:\ProgramData\BlueStacks_nxt`). The exe uses `DataDir`. Either works; prefer `DataDir`, fall back to `UserDefinedDir`, then `%ProgramData%\BlueStacks_nxt`.

Batch:
```bat
set "EMUKEY=HKLM\SOFTWARE\BlueStacks_nxt"
for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v InstallDir 2^>nul') do set "INSTALL_DIR=%%b"
for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v DataDir   2^>nul') do set "DATA_DIR=%%b"
if not defined DATA_DIR for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v UserDefinedDir 2^>nul') do set "DATA_DIR=%%b"
if not defined DATA_DIR set "DATA_DIR=%ProgramData%\BlueStacks_nxt"
```

### 2b. Instance enumeration (function `0x14001aff0`)
The exe parses **`<DataDir>\UserData\MimMetaData.json`** with three std::regex patterns:
```
\{([^{}]*"InstanceName"[^{}]*)\}      // each JSON object that contains an InstanceName
"Name"\s*:\s*"([^"]+)"                // display name
"InstanceName"\s*:\s*"([^"]+)"        // instance folder name (e.g. Rvc64, Pie64_3)
```
It also normalizes the engine path by trimming/looking for `engine\`, `engine/`, `Engine\` (case variants).

**Master vs clone (function `0x14001c760`):** an instance name is reduced to its *master* with regex `^(.+)_\d+$` (so `Pie64_3` → `Pie64`). The **`Root.vhd` lives in the master's folder** (clones share the master's read-only root disk). The **`.bstk` is per-instance**.

PowerShell instance list (drop-in for your Player.log scraping):
```powershell
$mim = Join-Path $env:DATA_DIR 'UserData\MimMetaData.json'
if (Test-Path $mim) {
  (Get-Content $mim -Raw | Select-String '"InstanceName"\s*:\s*"([^"]+)"' -AllMatches).Matches |
     ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
}
```

---

## 3. Kill emulator processes (`0x14001d240`)
Calls a per-name killer (`0x14001d140`, uses `CreateToolhelp32Snapshot`/`Process32First`/`Process32Next`/`OpenProcess`/`TerminateProcess`) for, in order:
```
HD-Player.exe
HD-MultiInstanceManager.exe
BstkSVC.exe
```
then prints `Emulator processes stopped.` The Disk/Root/Unroot functions also call this and then `Sleep(1000)`.

Batch (keep your extra `BlueStacksHelper.exe` too — harmless and helps):
```bat
:kill_emulator
taskkill /F /IM HD-Player.exe                >nul 2>&1
taskkill /F /IM HD-MultiInstanceManager.exe  >nul 2>&1
taskkill /F /IM BstkSVC.exe                   >nul 2>&1
taskkill /F /IM BlueStacksHelper.exe          >nul 2>&1
timeout /t 1 /nobreak >nul
goto :eof
```

---

## 4. Disk R/W and R/O (`.bstk`) — functions `0x140019f40` / `0x140024680`

**Path:** `<DataDir>\Engine\<instance>\<instance>.bstk` (per-instance).

**Algorithm (verified):** read the whole `.bstk` into a string; as a **guard**, confirm it contains
`location="fastboot.vdi"` **or** `location="Root.vhd"`; then do a **global `std::regex_replace`**:

| Op | Replace (regex → replacement), applied to entire file |
|---|---|
| **Disk R/W** | `type="Readonly"` → `type="Normal"` |
| **Disk R/O** | `type="Normal"` → `type="Readonly"` |

Exact literals in the binary (note the **lowercase `o` in `Readonly`**):
```
location="fastboot.vdi"   location="Root.vhd"   type="Readonly"   type="Normal"
```
Result strings: `Disk set to R/W.` / `Disk reverted to Readonly.` Failure: `Failed to update .bstk — run as Administrator.`

> Your current `blueStackRoot.cmd` uses `type="ReadOnly"` (capital O). PowerShell `-replace` is case-insensitive so *matching* still works, but to be byte-faithful use `Readonly`. The exe replaces **all** occurrences in both directions (no count cap).

Drop-in PowerShell (faithful, global):
```powershell
# R/W
(Get-Content $bstk -Raw) -replace 'type="Readonly"','type="Normal"' | Set-Content $bstk -NoNewline -Encoding utf8
# R/O
(Get-Content $bstk -Raw) -replace 'type="Normal"','type="Readonly"' | Set-Content $bstk -NoNewline -Encoding utf8
```
Always make `"<bstk>.bak"` first (the exe does, via the patch path; your script already does this for the `.bstk`).

---

## 5. The HD-Player.exe disk-integrity patch (`0x1400203f0`) — "Fix Illegally Tampered"

This is the piece your Python patcher covered unreliably. Here is the **exact** logic.

**Why:** once `Root.vhd` is modified, BlueStacks' `plrDiskCheckThreadEntry` detects tampering and shuts down (`Shutting down: disk file have been illegally tampered with!`). The patch neutralises the check.

**Flow:**
1. Kill emulator processes.
2. `HD-Player.exe` path = `<InstallDir>\HD-Player.exe`. Backup = that **+ `.bak`** (created only if absent; else `Backup already exists, skipping copy.`).
3. Load the whole file. Validate DOS/`PE\0\0` header. Find the `.text` section.
4. Locate the patch site by 4 strategies (all use the **same** byte pattern):
   - **Strategy 1** — find code that references the string `Verified the disk integrity!`, scan a **0x50**-byte window.
   - **Strategy 2** — anchor `plrDiskCheckThreadEntry`, window **0x700**.
   - **Strategy 3** — anchor `Shutting down: disk file have been illegally tampered with!`, window **0x700**.
   - **Strategy 4** — full `.text` scan; if multiple hits, validate the one whose function references `Verified the disk integrity!` or `Failed to verify the disk integrity!`.
5. **The pattern (identical in all strategies):**
   ```
   E8 ?? ?? ?? ??     CALL rel32
   84 C0              TEST AL, AL          <- t  (stored patch offset = offset of 0x84)
   74 ??              JZ  rel8             <- patched
   ```
   Match condition: `byte[t]=0x84 && byte[t+1]=0xC0 && byte[t+2]=0x74 && byte[t-5]=0xE8`.
6. **Already patched?** if `byte[t+2]==0x90 && byte[t+3]==0x90` → `Already patched. Nothing to do.`
7. **Patch:** `byte[t+2]=0x90; byte[t+3]=0x90` (the `JZ rel8` becomes `NOP NOP`). Message: `[*] Patching at 0x..: 74 .. -> 90 90`.
8. Write the whole buffer back → `Patched successfully!` (or `Failed to patch — run as Administrator.`).

> **NOP, not flip.** BstkRooter turns the `jz` into two `NOP`s (never jump). Your old Python flipped `jz`→`jmp` (always jump) — the opposite semantics, and a likely source of its unreliability. Use NOP.

### ✅ Use the dependency-free port
`recovered/BstkRooter/Patch-HDPlayerIntegrity.ps1` (in this folder) implements exactly the above in pure PowerShell — **no python, pefile, or capstone**. Replace `Bypass_Integrity_Check_Dynamic.cmd`'s body with:
```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-HDPlayerIntegrity.ps1" -Exe "%INSTALL_DIR%\HD-Player.exe"
```
Restore with `-Restore`; preview with `-DryRun`.

> Optional extra hardening (what your Python additionally targeted, not done by BstkRooter): the same `CALL;TEST AL,AL;JZ` pattern also appears guarded by `Failed to verify the file %s at block %u` (per-block check) and `In warmup mode: Stopping player.`. BstkRooter only needs the one disk-integrity site. If a future BlueStacks build needs more, extend the scan to NOP every validated `E8../84 C0/74` whose function also references one of those anchor strings.

---

## 6. bluestacks.conf root flag (inside Root, `0x14001d370`)

**Path:** `bluestacks.conf` sits in the directory **above** `Engine`. The exe takes `DataDir`, and if the path contains `engine\` (case-insensitive) it trims everything from `engine\` onward, then appends `bluestacks.conf`. In practice: **`<DataDir>\bluestacks.conf`**.

**Key built:** `bst.instance.` + `<instance>` + `.enable_root_access=` → e.g. `bst.instance.Rvc64.enable_root_access=`.

**Exact behaviour (verified byte-for-byte):**
- Read conf, iterate lines (`getline … '\n'`).
- If a line **contains** the key, replace that line with `key + "0"` → `bst.instance.<inst>.enable_root_access="0"` and set "replaced".
- If no line matched, **append** `bst.instance.<inst>.enable_root_access="0"\n`.
- Write conf back → `[+] bluestacks.conf updated.`

So **the exe writes `"0"`** (value bytes at RVA `0x1400aff38` = `22 30 22` = `"0"`; the only other value, RVA `0x1400aff3c` = `22 30 22 0a` = `"0"\n`). There is **no `"1"` constant** in the whole image.

> You answered **"replicate exactly (\"0\")"**. The faithful snippet is below. Note your existing Magisk flow instead writes `"1"` + `bst.feature.rooting="1"` because Magisk relies on BlueStacks' native root toggle; BstkRooter does not (it ships its own `su`). Keep them separate per use-case.

Faithful (BstkRooter) conf write, root:
```powershell
$conf = Join-Path $env:DATA_DIR 'bluestacks.conf'
$key  = "bst.instance.$inst.enable_root_access"
$lines = Get-Content $conf
if ($lines -match [regex]::Escape($key)) {
    $lines = $lines -replace ("(?m)^" + [regex]::Escape($key) + '=.*$'), ($key + '="0"')
} else {
    $lines += ($key + '="0"')
}
Set-Content -Path $conf -Value $lines -Encoding utf8
```
Unroot: **leave `bluestacks.conf` untouched** (faithful).

### 6a. If you instead want working BlueStacks-native root + ADB (your suggested hybrid)
To let the `.cmd` "simulate adb stuff", set these (on **root**), and revert on unroot:
```
bst.instance.<inst>.enable_root_access="1"
bst.instance.<inst>.enable_adb_access="1"
bst.feature.rooting="1"
```
The instance's adb port is then in `bluestacks.conf` as `bst.instance.<inst>.status.adb_port="<port>"`. BlueStacks bundles adb at `<InstallDir>\HD-Adb.exe`. See §7b.

---

## 7. Install / remove `su` in the ext4 of `Root.vhd`

**`Root.vhd` path:** `<DataDir>\Engine\<master>\Root.vhd` (master = instance with any `_<n>` suffix stripped). Messages: `[*] Found Root.vhd:` / `[!] Root.vhd not found:`.

The exe opens the VHD and mounts the ext4 **with bundled lwext4** (offline, no Windows mounting), then:
```
mkdir /android/system/xbin
write  bstk_su_c.tmp  ->  /android/system/xbin/su
chmod  /android/system/xbin/su  06755      (octal; immediate 0xDED)
chown  /android/system/xbin/su  uid=0 gid=0
umount; close vhd
```
Unroot deletes `/android/system/xbin/su`, umount, close. (`Unrooted successfully!` / `— already unrooted.` if absent.)

### 7a. Faithful **offline** method in .cmd (VirtDisk attach + `debugfs`)
Pure batch/PowerShell can't write ext4 natively, so reproduce lwext4 with **e2fsprogs `debugfs.exe`** (one ~2 MB download, e.g. the Windows build of e2fsprogs; place `debugfs.exe` next to the script). Windows' own VirtDisk API (the same `OpenVirtualDisk`/`AttachVirtualDisk` the exe imports) flattens fixed/dynamic VHD and VHDX so you don't reimplement the VHD format.

**VHD/partition/ext4 facts the exe uses (so you can find the partition):**
- VHD footer cookies `conectix` (fixed/dynamic) and `cxsparse` (dynamic BAT). `EFI PART` = GPT. MBR signature `0xAA55` at sector offset `0x1FE`; 4 MBR entries; Linux type `0x83`.
- **ext4 detection:** superblock magic `0xEF53` at **partition_offset + 0x438** (1024-byte superblock + 0x38). The exe scans MBR + GPT partitions and picks the first whose `+0x438` == `0xEF53`.

**Steps (root):**
```powershell
# --- 1) attach the VHD (handles fixed/dynamic/vhdx) ---
$rootVhd = Join-Path $env:DATA_DIR "Engine\$master\Root.vhd"
$img = Mount-DiskImage -ImagePath $rootVhd -StorageType VHD -Access ReadWrite -PassThru
$disk = $img | Get-DiskImage | Get-Disk
$dn   = $disk.Number
$phys = "\\.\PhysicalDrive$dn"

# --- 2) find the ext4 partition offset by the 0xEF53 magic at off+0x438 (mirrors the exe) ---
$fs = [System.IO.File]::Open($phys,'Open','ReadWrite','None')
function Read-At($fs,[long]$off,[int]$n){ $fs.Position=$off; $b=New-Object byte[] $n; [void]$fs.Read($b,0,$n); $b }
$part = $null
foreach ($p in (Get-Partition -DiskNumber $dn -ErrorAction SilentlyContinue)) {
    $m = Read-At $fs ($p.Offset + 0x438) 2
    if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) { $part = $p; break }   # 0xEF53 little-endian
}
if (-not $part) {  # superfloppy: ext4 directly at offset 0
    $m = Read-At $fs 0x438 2
    if ($m[0] -eq 0x53 -and $m[1] -eq 0xEF) { $part = [pscustomobject]@{ Offset=0; Size=$disk.Size } }
}

# --- 3) carve the partition to a temp .img (debugfs works on a plain image, any build) ---
$tmp = Join-Path $env:TEMP 'bstk_ext4.img'
$out = [System.IO.File]::Open($tmp,'Create','Write','None')
$fs.Position = $part.Offset; $buf = New-Object byte[] (16MB); [long]$left = $part.Size
while ($left -gt 0){ $r=$fs.Read($buf,0,[Math]::Min($buf.Length,$left)); if($r -le 0){break}; $out.Write($buf,0,$r); $left-=$r }
$out.Close()

# --- 4) edit ext4 with debugfs (mirrors mkdir/write/chmod 06755/chown 0:0) ---
@"
mkdir /android/system/xbin
cd /android/system/xbin
rm su
write $env:TEMP\su su
sif su mode 0106755
sif su uid 0
sif su gid 0
sif su links_count 1
"@ | Set-Content "$env:TEMP\bstk.debugfs" -Encoding ascii
& "$PSScriptRoot\debugfs.exe" -w -f "$env:TEMP\bstk.debugfs" $tmp

# --- 5) write the image back & detach ---
$in = [System.IO.File]::OpenRead($tmp); $fs.Position=$part.Offset
while(($r=$in.Read($buf,0,$buf.Length)) -gt 0){ $fs.Write($buf,0,$r) }
$in.Close(); $fs.Flush(); $fs.Close()
Dismount-DiskImage -ImagePath $rootVhd | Out-Null
```
- `0106755` octal = `S_IFREG (0100000)` | `06755` (setuid+setgid+rwsr-sr-x) — exactly the `0xDED`/`06755` the exe sets.
- **Unroot:** same attach/carve/write-back, but the debugfs script is just `rm /android/system/xbin/su`.
- Put your already-decrypted `embedded_su_decrypted` (renamed `su`) at `%TEMP%\su`, or XOR-decrypt resource 101 with `0xA7` at runtime.

### 7b. Alternative **online** method (your "enable adb" idea — no debugfs download)
If you prefer no extra tool, after §4 (disk R/W) + §5 (patch) + §6a (`enable_root_access="1"`, `enable_adb_access="1"`):
```bat
set "ADB=%INSTALL_DIR%\HD-Adb.exe"
rem read the instance adb port from bluestacks.conf:
for /f tokens^=2^ delims^=^" %%p in ('findstr /i "bst.instance.%inst%.status.adb_port" "%DATA_DIR%\bluestacks.conf"') do set "PORT=%%p"
start "" "%INSTALL_DIR%\HD-Player.exe" --instance %inst%
rem ... wait for boot ...
"%ADB%" connect 127.0.0.1:%PORT%
"%ADB%" -s 127.0.0.1:%PORT% root
"%ADB%" -s 127.0.0.1:%PORT% shell "mount -o rw,remount /system"
"%ADB%" -s 127.0.0.1:%PORT% push "%~dp0su" /system/xbin/su
"%ADB%" -s 127.0.0.1:%PORT% shell "chmod 06755 /system/xbin/su && chown 0:0 /system/xbin/su"
```
This deviates from the exe (which is fully offline) but needs no debugfs. It also pairs naturally with your Magisk flow (`adb push magisk … && adb install …`).

---

## 8. Exact path & string reference (for copy-paste fidelity)

| Thing | Value |
|---|---|
| Emulator reg keys | `SOFTWARE\BlueStacks_nxt`, `SOFTWARE\BlueStacks_msi5` |
| Reg values | `InstallDir`, `DataDir` |
| Instance metadata | `<DataDir>\UserData\MimMetaData.json` |
| `.bstk` | `<DataDir>\Engine\<instance>\<instance>.bstk` |
| `Root.vhd` | `<DataDir>\Engine\<master>\Root.vhd` |
| `bluestacks.conf` | `<DataDir>\bluestacks.conf` |
| `HD-Player.exe` | `<InstallDir>\HD-Player.exe` (+`.bak`) |
| adb | `<InstallDir>\HD-Adb.exe` |
| Processes killed | `HD-Player.exe`, `HD-MultiInstanceManager.exe`, `BstkSVC.exe` |
| Temp su | `%TEMP%\bstk_su_c.tmp` |
| ext4 dir / file | `/android/system/xbin` , `/android/system/xbin/su` |
| chmod / chown | `06755` (0xDED) / uid 0 gid 0 |
| .bstk R/W regex | `type="Readonly"` → `type="Normal"` |
| .bstk R/O regex | `type="Normal"` → `type="Readonly"` |
| conf key | `bst.instance.<inst>.enable_root_access="0"` (exe) |
| Resource 101 XOR key | `0xA7` |
| ext4 magic | `0xEF53` at `partition_offset + 0x438` |
| HD-Player patch pattern | `E8 ?? ?? ?? ?? 84 C0 74 ??` → NOP the `74 ??` to `90 90` |

### Function map (for re-checking against the binary)
| RVA | Role |
|---|---|
| `0x14001d240` | kill emulator processes (helper `0x14001d140` per-name) |
| `0x14001aff0` | enumerate instances (MimMetaData.json + 3 regexes) |
| `0x14001c760` | master name from instance (`^(.+)_\d+$`) |
| `0x140017320` / `0x1400229b0` | registry read (`BlueStacks_nxt`/`_msi5`) |
| `0x140018bf0` | UI init: read InstallDir/DataDir + enumerate |
| `0x140019f40` / `0x140024680` | Disk R/W / R/O (`std::regex_replace`, helper `0x140014c90`) |
| `0x1400203f0` | HD-Player integrity patch |
| `0x140018f80` | anchor→patch-site finder (strategies 1-3) |
| `0x14001d370` / `0x14001f540` | Root / Unroot |
| `0x140031560` | VHD partition table parse + ext4 detect |
| `0x140031cf0` | dynamic-VHD block (BAT) translation |
| `0x140022a50` | UI dispatcher (calls all button handlers) |

---

## 9. How this maps onto your existing repo (minimal-change plan)

Your project is **Magisk**-based (junction switching via `split.cmd`/`RootJunction.cmd`/`UnRootJunction.cmd`, config edits in `blueStackRoot.cmd`, integrity patch via the Python). The only genuinely **missing/unreliable** pieces vs. BstkRooter are (a) the integrity patch and (b) optionally the offline `su` install. Minimal changes:

1. **Replace the Python patcher** — swap `Bypass_Integrity_Check_Dynamic.cmd`'s `python … Bypass_Integrity_Check_Semantic.py` call for the bundled `Patch-HDPlayerIntegrity.ps1` (no Python deps). Keep the same backup/restore UX. *(Fixes "missing the disk patches".)*
2. **Fix the `.bstk` literal** — in `blueStackRoot.cmd` lines 192–196, `type=\"ReadOnly\"` → `type=\"Readonly\"` to be byte-exact (matching is case-insensitive so this is cosmetic but correct).
3. **Wire the patch into `:apply_changes`** — after the `.bstk`/conf edits, call the patcher so newer BlueStacks (≥5.22.150) stops detecting tamper. This is what makes rooting work on current builds without downgrading.
4. **(Optional) Add a true `su` install path** — §7a (offline debugfs) for a BstkRooter-faithful root, or §7b (adb) which dovetails with your Magisk push. *(Fixes "moving su files around".)*
5. **`todolist.md` item "kill all 4 with 1 taskkill"** — `for %%P in (HD-Player.exe HD-MultiInstanceManager.exe BstkSVC.exe BlueStacksHelper.exe) do taskkill /F /IM %%P >nul 2>&1`.

Nothing about your junction/Magisk architecture needs to change — these are additive.

---

## 10. Appendix — how each fact was verified
- Strings/imports/resources: `rabin2 -z/-zz/-i`, `pefile` resource walk.
- XOR key: `rcdata_101.bin ^ 0xA7 == embedded_su_decrypted` (byte-exact), ELF confirmed by `objdump`.
- Functions: r2 `axt` string-xrefs → r2dec `pdd` + capstone disassembly.
- Conf value `"0"`: byte search proved `22 31 22` (`"1"`) absent; `0x1400aff38=22 30 22`.
- Patch: pattern `84 C0 74 / E8` and the `0x90 0x90` writes read directly from `0x1400203f0`; identical pattern in anchor finder `0x140018f80`.
- chmod `0xDED`(=`06755`) / chown `0,0` / `0xEF53` at `+0x438`: read from `0x14001d370` and `0x140031560`.
