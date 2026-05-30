# BstkRooter.exe Static Recovery Report

Analyzed file: `/Users/jordan/Downloads/new root/BstkRooter.exe`

SHA-256: `cb8718999aa96c134a9f7cf0af3b633a8f8c32344b724fa3a5a2dbec3c50d187`

## PE Summary

- Format: Windows PE32+ x86-64 GUI executable.
- Language/toolchain: native MSVC C++, not .NET.
- Compile timestamp: `2026-03-25 08:23:01 UTC` as reported by the PE header.
- Signed: no Authenticode signature found.
- Requested privileges: `requireAdministrator`.
- Debug path: `G:\Git\bstk_re\BSTKRooter\build\BstkRooter.pdb`.
- Product/version strings:
  - Product: `BSTK Rooter`
  - File description: `BSTK Rooter - BlueStacks 5 & MSI App Player Configuration Utility`
  - Company: `Taaauu`
  - File version: `1.0.1`
  - Comments: `Emulator configuration and root access management tool for BlueStacks 5 and MSI App Player.`

## Embedded Resources

The executable has two important `RCDATA` resources:

- Resource `101`: 2,012,872 bytes of XOR-obfuscated payload data. XOR key is `0xA7`.
- Resource `102`: 500x500 RGBA PNG asset.

Recovered resource files:

- `rcdata_101.bin`: original obfuscated payload.
- `embedded_su_decrypted`: decrypted Android x86_64 ELF payload.
- `rcdata_102.png`: recovered PNG asset.

Decrypted payload SHA-256:

`185106357cfc0d1db4b8efb033de863f437850437e0ef6b62630c05f291b4902`

The decrypted payload is:

- ELF 64-bit LSB executable, x86-64.
- Android target.
- Statically linked.
- Not stripped and contains debug info.
- Source file marker: `su.c`.

Recovered behavior of embedded `su`:

```c
int main(int argc, char **argv) {
    setgid(0);
    setuid(0);

    if (getuid() != 0) {
        fprintf(stderr, "su: permission denied (uid=%d)\n", getuid());
        return 1;
    }

    setenv("HOME", "/root", 1);
    setenv("SHELL", "/system/bin/sh", 1);
    setenv("USER", "root", 1);
    setenv("LOGNAME", "root", 1);
    setenv("PATH", "/sbin:/system/sbin:/system/bin:/system/xbin:/vendor/bin", 1);

    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        execl("/system/bin/sh", "sh", "-c", argv[2], NULL);
    } else if (argc >= 2 && strcmp(argv[1], "-") == 0) {
        execl("/system/bin/sh", "-sh", NULL);
    } else if (argc == 1) {
        execl("/system/bin/sh", "sh", NULL);
    } else {
        argv[0] = "sh";
        execv("/system/bin/sh", argv);
    }

    perror("su: exec failed");
    return 1;
}
```

## Main Program Behavior

The program is a GUI built with Dear ImGui/D3D11. The visible actions are:

- `Kill Emulator Processes`
- `Fix Illegally Tampered`
- `Disk R/W`
- `Disk R/O`
- `One Click Root`
- `One Click Unroot`

It supports BlueStacks 5 and MSI App Player:

- Registry keys:
  - `SOFTWARE\BlueStacks_nxt`
  - `SOFTWARE\BlueStacks_msi5`
- Registry values:
  - `InstallDir`
  - `DataDir`
- It parses `UserData\MimMetaData.json` for instance names.
- It parses `.bstk` files for disk image entries.

## Process-Kill Routine

Function located by string xrefs: `0x14001d240`.

It tries to terminate:

- `HD-Player.exe`
- `HD-MultiInstanceManager.exe`
- `BstkSVC.exe`

The program imports `CreateToolhelp32Snapshot`, `Process32First`, `Process32Next`, `OpenProcess`, and `TerminateProcess`, matching process enumeration and termination behavior.

## HD-Player Tamper-Patch Routine

Function located by string xrefs: `0x1400203f0`.

Purpose: patch `HD-Player.exe` so BlueStacks does not stop on disk-tamper/integrity checks.

Observed behavior:

- Finds `HD-Player.exe` in the detected install directory.
- Creates or skips a `.bak` backup.
- Loads the PE and checks for a `.text` section.
- Searches for patch location with several strategies:
  - Anchor string: `Verified the disk integrity!`
  - Anchor symbol/string: `plrDiskCheckThreadEntry`
  - Anchor string: `Shutting down: disk file have been illegally tampered with!`
  - Full `.text` scan for a `CALL + test + jz` pattern.
- Uses validation strings:
  - `Failed to verify the disk integrity!`
  - `Verified the disk integrity!`
- Patches two bytes to `90 90` (`NOP NOP`).

## Disk R/W and R/O Routines

Functions located by string xrefs: `0x140019f40` and `0x140024680`.

The routines edit instance `.bstk` files. They replace disk entries:

```xml
location="fastboot.vdi"
location="Root.vhd"
type="Readonly"
type="Normal"
```

The user-facing results are:

- `Disk set to R/W.`
- `Disk reverted to Readonly.`

## Root Routine

Function located by string xrefs: `0x14001d370`.

High-level flow:

```c
kill_emulator_processes();
find Root.vhd for selected BlueStacks/MSI instance;
decrypt embedded resource 101 with XOR key 0xA7 to temporary file "bstk_su_c.tmp";
open Root.vhd;
find ext4 partition;
mount ext4 partition using bundled lwext4 code;
create "/android/system/xbin";
copy decrypted su to "/android/system/xbin/su";
chmod "/android/system/xbin/su" to 06755;
chown "/android/system/xbin/su" to uid 0, gid 0;
unmount ext4;
close VHD;
edit bluestacks.conf for the selected instance:
    bst.instance.<instance>.enable_root_access="1"
report "Rooted successfully!";
```

Notable strings:

- `bstk_su_c.tmp`
- `/android/system/xbin`
- `/android/system/xbin/su`
- `[*] Setting permissions 06755 (suid/sgid)...`
- `[*] Setting owner root:root (0:0)...`
- `.enable_root_access=`
- `bst.instance.`

## Unroot Routine

Function located by string xrefs: `0x14001f540`.

High-level flow:

```c
kill_emulator_processes();
find Root.vhd for selected instance;
open Root.vhd;
find and mount ext4 partition;
delete "/android/system/xbin/su";
unmount ext4;
close VHD;
edit bluestacks.conf for the selected instance:
    bst.instance.<instance>.enable_root_access="0"
report "Unrooted successfully!";
```

## VHD Handling

Function located by string xrefs around `0x140030b00`.

The program supports:

- Plain `.vhd` file parsing.
- Dynamic VHD footer strings: `conectix`, `cxsparse`.
- `.vhdx` via Windows `VirtDisk.dll`.

Imported APIs:

- `OpenVirtualDisk`
- `AttachVirtualDisk`
- `DetachVirtualDisk`
- `GetVirtualDiskPhysicalPath`
- `CreateFileW`
- `ReadFile`
- `WriteFile`
- `DeviceIoControl`

It can locate partition tables including GPT (`EFI PART`) and mount ext4 using bundled `lwext4` code. Source path strings show:

- `K:\Git\bstk_re\root_tool\lwext4\src\ext4.c`
- `K:\Git\bstk_re\root_tool\lwext4\src\ext4_fs.c`
- `K:\Git\bstk_re\root_tool\lwext4\src\ext4_dir.c`
- `K:\Git\bstk_re\root_tool\lwext4\src\ext4_balloc.c`
- `K:\Git\bstk_re\root_tool\lwext4\src\ext4_extent.c`

## Overall Assessment

This executable is not a generic malware dropper from the observed static evidence. It is a BlueStacks/MSI App Player root-management utility. Its powerful behavior is intentional for that purpose: it runs as administrator, stops BlueStacks processes, patches `HD-Player.exe`, edits BlueStacks config files, opens/modifies virtual disk images, and installs or removes a setuid root `su` binary inside the Android filesystem.

The most sensitive actions are:

- Terminating BlueStacks processes.
- Modifying `HD-Player.exe` on disk.
- Changing `.bstk` disk image mode entries.
- Writing directly into `Root.vhd`.
- Installing a root shell helper at `/android/system/xbin/su`.
