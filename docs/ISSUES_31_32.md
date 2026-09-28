# Issues #31 and #32: Windows host failures

Investigation: 2026-09-27–28. Both complete issue bodies, every comment, both attached logs,
and the screenshot in #32 were reviewed.

## What the attachments establish

- [#32](https://github.com/Jordan231111/BluestacksRoot/issues/32): the
  [screenshot](https://github.com/user-attachments/assets/864a513c-6e6f-4be1-9103-6ce7f32db635)
  shows the offline disk write and detach completing. The next step fails while Windows starts
  `HD-Player.exe` for Tiramisu64. Its [diagnostic log](https://github.com/user-attachments/files/32155553/bsr_debug_20260913_124341.log)
  records the same launch denial, no player process, and no instance ADB listener. A connected physical
  Android device in that log is unrelated to the failed emulator launch. The follow-up comment reports
  another affected user but adds no diagnostic evidence.
- [#31](https://github.com/Jordan231111/BluestacksRoot/issues/31): the posted run stops at
  `Mount-DiskImage` for Rvc64. The Russian error means that Windows found no virtual disk support
  provider for the specified file. Its [attached log](https://github.com/user-attachments/files/31909841/bsr_debug_20260907_204144.log)
  also records an access-denied player launch. These are two separate host failures, not an Android
  bootstrap-su or ADB reconnect failure.

The old diagnostic did not capture native launch codes, executable signatures, permissions, policy
events, or disk signatures. Consequently these attachments cannot identify the exact ACL/security
policy responsible for either launch denial, or establish the actual format/provider state on #31's PC.
Removing Defender is not a supported inference or remedy from this evidence.

## Reproductions and changes

Windows normally selects a disk provider from the filename extension unless `StorageType` is supplied.
[Microsoft documents this behavior](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage).
A valid VHD renamed `.bsrbak` reproduced the exact provider error locally. A VHDX named `Root.vhd`
also failed with the old mount call. Both mount successfully when their actual format is selected.
This proves a compatibility defect in the old implementation, not that either filename mismatch occurred
on the reporter's machine. Missing/broken Windows storage components still require host repair.

- Shared `bsr_host.ps1` reads VHD/VHDX signatures, rejects truncated/unknown/VDI content before writing,
  specifies the format for mount and query, and detaches the returned image object. The latter matters:
  detaching a VHDX by its misleading `.vhd` filename can fail and leave it attached.
- Prep performs a read-only mount preflight before backups, executable patching, or root-conf changes.
  Existing attachments are rejected without detaching disks owned by another process.
- Disk copy helpers reject short reads, unaligned staging images, and changed image lengths; they no
  longer silently accept an incomplete carve or pad a write with leftover buffer contents. Failed edits
  in the Magisk pipeline clean up their unique temporary image and detach in `finally`.
- Player launch uses the existing elevated token, the install directory as working directory, and no
  inherited handles. Windows permission and application-control checks still apply. Failures include the
  native code and host evidence; the diagnostic stops instead of spending two minutes reconnecting ADB.
  Signature/ACL inspection explicitly loads the security module belonging to the running PowerShell;
  this also fixes failed module discovery when a PowerShell 7 parent starts the diagnostic through cmd.
- The generic batch failure message no longer attributes unrelated failures to antivirus or claims an
  exclusion succeeded. Payload integrity errors retain their separate diagnostics.
- Both `.cmd` files embed the shared helpers. The rooter remains a single distributable `.cmd`, with no
  extra runtime files to download. The builder searches markers with native byte scanning and preserves
  CRLF in the batch header. The live harness now saves screenshot bytes directly; PowerShell 5.1 text
  redirection previously produced corrupt UTF-16 files bearing `.png` names. It launches the manager
  before taking screenshots, fails if its package is absent, and releases its private ADB server on exit
  so inherited log handles cannot keep a terminal/CI capture open.

## Validation

The host suite includes a real temporary execute-deny ACL (Win32 5), a long-running child process that
must not hold its parent's output pipes open, mount preflight failure without host mutations, rejected
short/unaligned writes, and actual VHD/VHDX mount/detach/reattach with misleading extensions.
Run `tests/Run-Host-Tests.ps1 -LiveDisks` as administrator; all test disks are disposable.

All seven automated suites passed locally under Windows PowerShell 5.1: 448 checks, zero failures or skips.

| Suite | Passed |
| --- | ---: |
| Engine unit/integration | 29 |
| Magisk unit | 263 |
| Path and ADB resolution | 59 |
| Unchanged patch algorithm equivalence | 24 |
| Disposable ext4/VHD end-to-end | 6 |
| Windows host regressions, including real disk mounts | 39 |
| Diagnostic privacy, disk safety, targeting, and timeouts | 28 |

Embedded-source synchronization, payload hashes, PowerShell parsing, and `git diff --check` also passed.

On a fresh BlueStacks 5.22.265.1013 installation on Windows 10, newly created Android 11 (`Rvc64`)
and Android 13 (`Tiramisu64`) instances completed the full Magisk pipeline. Android 13 was installed
through the actual batch menu, with only `blueStackRoot.cmd` in its directory and a fresh TEMP/TMP:
all runtime tools and the APK were extracted from that single file. Both versions reached `VERIFY PASS`.

Independent verification on each version passed all eight checks, including another cold reboot:
`uid=0`, Kitsune v31 installed, `/system/bin/su` points to Magisk, no competing `/system/xbin/su`, and
no bootstrap-su hash remains. Additional app-launch checks passed, and the manager reports
`Installed 31.0-kitsune (31000)`. The updated `debug.cmd` also completed a real cold-boot diagnostic,
including signature, ACL, disk-format, and ADB recovery output. The test instances and pristine VHD
backups remain available locally.

The v20 diagnostic was also tested with two instances running: it restarted only the selected Android 13
instance, used its owned ADB listener, and left Android 11 running. With the other instance closed, its
read-only probe attached the 8 GB root disk, reported the partition layout, and detached successfully.
The report retains Windows codes, hashes, ACLs, UAC/Code Integrity state, related events, and filtered
player startup/disk errors. User-directory names are masked before output or truncation; other technical
details remain. Unrelated app inventories and input/telemetry messages are not copied from Player.log.

## Confidence and remaining limits

The matching disk-provider failure is reproduced and its format-selection defect is fixed. The supplied
issue #31 evidence does not establish whether that reporter has a format mismatch, damaged image, or
broken Windows provider. A controlled execute-deny ACL reproduces Win32 5 and verifies immediate,
accurate launch-failure reporting; it does not reproduce or repair the reporters' unknown host policy.

The reporters' precise launch-denial policy has not been reproduced on this host. A fresh diagnostic
from an affected PC is still needed to confirm that cause. The changes do not disable Windows security
or broadly rewrite file permissions to conceal that uncertainty. No regressions were observed in the
tests above; this is not proof of compatibility with every BlueStacks build, Windows 11 security policy,
or interrupted disk write. Neither issue should be described as confirmed resolved on the reporters'
machines until they retest.

## Git fetch

Repeated `git fetch origin` and `git fetch --all --prune --tags --verbose` calls succeeded. One fetched
a newly created remote branch, so this was not just a cached/up-to-date result. Repository connectivity
checks found no corruption. The original fetch error was not reproduced; no Git configuration changes
were needed or made.
