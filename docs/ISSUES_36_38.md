# Issues #36 and #38: findings and v22 validation

## #36: reproduced and fixed

[#36](https://github.com/Jordan231111/BluestacksRoot/issues/36) reports a real Windows PowerShell 5.1
locale bug. With `tr-TR`, the launcher's case-insensitive expression
`^(BSR_[A-Z]+)=(.*)$` rejects `BSR_INSTALL`, `BSR_INSTANCE` and `BSR_DATADIR`. Replaying the resolver's
output against the old embedded launcher reproduces the missing `BSR_INSTALL` error.

The engine emits uppercase ASCII keys, so v22 uses `-cmatch`. Tests exercise the shipped launcher and
real resolver against temporary installation fixtures, in a fresh PowerShell 5.1 process for each of
`en-US`, `tr-TR` and `az-Latn-AZ`. All pass. Fresh processes matter because PowerShell caches regular
expressions; testing only in PowerShell 7 did not reproduce the 5.1 failure.

## #38: confirmed reporting defect; underlying file failure unresolved

[#38](https://github.com/Jordan231111/BluestacksRoot/issues/38) reports a failure immediately after
embedded APK preparation. Its [attached diagnostic log](https://pastebin.com/6J6PXA1m) does not capture
that operation, its temporary path or the original exception. There is no basis to dismiss the report
as bogus, but the log cannot establish the failing file or cause.

The old generic user-path redactor can reproduce the exact truncated message. Given an error such as
`An object at the specified path C:\Users\Example Person does not exist, or has been filtered ...`,
it treats the whole error suffix as the username and prints only
`An object at the specified path C:\Users\xxxxx`. The `xxxxx` is intentional privacy masking, not a
second Windows account. v22 retains the explanation after this profile-root path and identifies which
payload preparation step failed.

The OneDrive path in the posted log is the **diagnostic log destination on the Desktop**. It does not
identify the rooter's location. A `OneDrive - <organization>` folder is a work/school OneDrive sync
location; Windows Desktop can be redirected there through
[OneDrive folder backup](https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders).
[Files On-Demand](https://learn.microsoft.com/en-us/sharepoint/files-on-demand-windows) allows files to
be online-only, but a directory name alone says nothing about whether a particular file is available.
The old log has neither cloud-file attributes nor a rooter read failure to support that explanation.

The log shows a successful read-only master-disk attach, a player boot and an ADB reconnect. Subsequent
guest commands return `error: closed`, so its final reconnect success message does not validate rooting.
Registered Kaspersky/Defender products likewise do not prove quarantine. v22 separates ADB readiness
from file preparation and incomplete guest evidence, and reports observed payload damage without
asserting an antivirus cause.

Actual embedded APK, su and debugfs preparation succeeded locally from paths containing spaces,
brackets, apostrophes, ampersands, exclamation marks and Unicode, and with an 8.3 temporary path. These
results do not reproduce the reporter's failure or rule out a problem specific to their machine.

### Evidence the new diagnostic collects

Run the new `debug.cmd --files-only` beside the **affected copy** of `blueStackRoot.cmd`, or pass that
copy as the second argument. This runs without elevation or a player restart. The log contains:

- Rooter/diagnostic paths and hashes, culture, configured OneDrive roots, raw file attributes and
  offline/recall flags, captured before reading payloads. Flag meanings follow
  [Windows file-attribute documentation](https://learn.microsoft.com/en-us/windows/win32/fileio/file-attribute-constants).
- Actual temp-directory create/write/provider-lookup/read/rename/delete and PowerShell launch checks.
- Parsing of embedded scripts, isolated execution of the rooter's own payload extraction functions,
  payload hashes and a debugfs executable/DLL check. The probe does not invoke rooting or alter
  existing caches; external APK overrides are outside its scope.
- The failing stage, exception chain, HRESULT/native code, source position and stack; bounded worker
  timeouts retain partial output. Each independent check gets a result, and failures yield a nonzero
  exit code and final summary.

Logs prefer `%LOCALAPPDATA%\BlueStacksRoot\Logs`, with a printed fallback location if necessary.
They are not automatically uploaded. Use the normal `debug.cmd <instance>` mode if runtime evidence
is also needed; that mode restarts the selected instance.

## Console layout and display scaling

The old menu forced a minimum width of 44 cells and could overflow a smaller viewport. Its stacked
layout also interleaved root and undo choices under separate headings. v22 wraps text to the available
width, keeps root/undo groups together in one-column mode, shortens long displayed paths and removes
decoration in short windows so the actions and prompt remain visible. Wide windows retain the centered
two-column layout. It reads viewport dimensions on each redraw without changing the user's font or
Windows scale setting; [Windows console dimensions use character cells](https://learn.microsoft.com/en-us/windows/console/window-and-screen-buffer-size).

Validation covers widths from 20 to 240 cells, compact viewport cases down to 40×18, and 28 real Windows
console size/font combinations with Consolas from 16 to 48 pixels. Native screen-buffer checks confirm
the action labels, redacted paths and input prompt remain visible. This is not a physical multi-monitor
or Windows Terminal test matrix; OS display scaling was not changed during testing.

## Validation scope

The embedded-source/payload checks, reproducible distribution build, engine/ext4 fixtures, patch
equivalence, path/port resolution, Magisk unit, host, safety, diagnostic, locale/layout, preflight and
native console suites passed in Windows PowerShell 5.1. Failure fixtures include sharing violations,
missing temp paths, an unavailable log destination, broken worker startup, damaged/truncated payloads,
timeout output retention and cleanup, and incomplete ADB replies. Cloud-attribute decoding is tested
with fixtures; no real online-only OneDrive file was tested.

Magisk, su and debugfs binaries are unchanged. No live root/undo run was performed for this release;
the tests used disposable files/disks and did not root or unroot an installed instance. #38 still needs
the new log from the affected machine before any underlying filesystem fix can be justified.
