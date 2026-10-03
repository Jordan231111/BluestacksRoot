# Production hardening review

The user distribution remains **one `blueStackRoot.cmd`**. The root README is
unchanged. Sources under `tools/` are for development; the launcher extracts its
own engine, orchestrator and payloads into isolated temporary directories.

## Changes

- Replaced batch path interpolation and repeated subprocess bootstrapping with
  an embedded PowerShell launcher. Spaces, brackets, apostrophes, ampersands,
  exclamation marks and Unicode paths are covered by actual launch tests.
- Consolidated discovery, native process execution, disk reads and copies,
  hashing, extraction, configuration updates and instance identification into
  shared helpers. Large binary results remain byte arrays rather than being
  enumerated through the PowerShell pipeline.
- Bound native process execution and drain both output pipes concurrently.
  Pin ADB to the selected instance's process and listening port; reject stale
  log PIDs, occupied foreign server ports and unrelated devices.
- Run automated guest commands through ADB's noninteractive transport, require
  completed responses, recognize connection resets, retry incomplete transfers,
  and keep temporary guest scripts and their input files until execution is confirmed. Bound hung
  private-server shutdowns and verify ownership before stopping a process.
  These fixes address failures reproduced on fresh Android instances.
- Verification and undo now return failure when their checks or cleanup are
  incomplete. The bootstrap scan uses bundled BusyBox and checks traversal and
  hashing before accepting a clean result. A directory containing the word
  `magisk` no longer makes an unrelated `su` link pass verification; package
  removal must receive the package manager's success response.
- Validate every offline payload's size, permissions and ownership within its
  own debugfs response. Reject short disk reads and incorrect write lengths.
  Correct the clone configuration path and handle XML attribute order.
- Publish backups, restores, configuration writes and rebuilt distributions
  atomically. Preserve existing backups, line endings and Defender exclusions.
  Validate all embedded payload hashes and reject archive path traversal.
- Reject malformed PE headers and section bounds before patching. Restore dry
  runs now leave the executable unchanged. The existing optimized patch remains
  byte-equivalent to the frozen reference implementation.
- Use shared build helpers, validate source syntax before publishing, reject
  duplicate markers, and pin PowerShell source line endings for reproducible
  builds. Rebuilding either the scripts or the unchanged APK is byte-identical;
  APK re-embedding takes about 1.5 seconds on the test machine.
- Extend Windows CI with distribution and failure regression suites. Move seven
  superseded, machine-specific investigation scripts into `archive/dev-probes/`;
  maintained live tests require an explicitly named disposable instance.

## Runtime cost and cleanup

The launcher extracts its two scripts once per menu session. Each selected
operation uses a separate private work directory, removed on success or failure.
Debugfs scripts and carved disk images are also removed in their own `finally`
blocks. Forced termination or a machine crash can leave temporary files behind;
normal completion does not retain a history of work directories.

Auto reads the embedded distribution once per orchestrator process and extracts
each payload once. Data reuses the ten APK files already staged by Prep; a
standalone Data invocation extracts its own set and needs no debugfs extraction.
There is no persistent extraction cache to invalidate between runs.

Root.vhd and player backups are created only when absent. Atomic publication uses
a temporary sibling and a rename, with cleanup on failure; it does not keep
rotating backup copies. Configuration updates are batched and write only when
content changes. The large before-images used during this review are test
artifacts, not part of the shipped runtime.

The main Auto costs remain three emulator boots and two offline disk passes
(Prep and Clean). Each pass holds one carved image at a time. Removing the clean
pass would retain bootstrap root; removing the final boot would omit validation
of the cleaned state. Disk length checks, payload integrity, operation locking,
completion markers and post-write verification protect against failures that
unit tests cannot prevent on a user's machine. No further high-yield reduction
was identified without changing this workflow or weakening recovery. This is
not a claim that every possible micro-optimization has been exhausted.

## Validation

Tests run with Windows PowerShell 5.1 on Windows 10 IoT Enterprise LTSC,
build 19044, and BlueStacks 5.22.265.1013, on October 2–3, 2026. The test machine
has real VHD/VHDX mount support and `mke2fs`, so disk and ext4 integration checks
run rather than skip.

| Suite | Passing checks |
| --- | ---: |
| Embedded source and payload integrity | 11 |
| Standalone distribution and reproducible builds | 10 |
| Engine and ext4 integration | 35 |
| Patch equivalence, including the installed player's copied bytes | 24 |
| Discovery and instance resolution | 59 |
| Magisk orchestration | 270 |
| Host helpers, including `-LiveDisks` VHD/VHDX checks | 39 |
| Failure handling and recovery | 48 |
| Diagnostic privacy and error handling | 28 |
| Scratch-disk root/unroot integration | 6 |
| **Total, excluding live Android tests** | **530** |

The failure suite checks malformed archives and executables, short disk reads,
failed restores, native timeouts and argument quoting, stale PIDs, foreign ADB
servers, incomplete verification, failed uninstalls, and full host scrub against
isolated fixtures. Distribution tests execute the standalone `.cmd` from a path
containing spaces, punctuation and Unicode. Syntax validation and
`git diff --check` also pass.

The final extraction reduction was checked with the real embedded APK: prepared
Data preserves all ten payload hashes and write times, while standalone Data
stages the same complete file set before boot. Both paths work without debugfs.
The distribution, payload synchronization and orchestration suites passed again
after this change.

Six disposable instances were created with BlueStacks' Multi-Instance Manager:

| Android | Instances | Confirmed behavior |
| --- | --- | --- |
| 9 | `Pie64_3`, `Pie64_4` | Root, cold boots, peer isolation, unroot; final-build re-root/unroot on `_3` |
| 11 | `Rvc64_5`, `Rvc64_6` | Root, repeated cold boots, peer isolation, unroot; final-build re-root/unroot on `_5` |
| 13 | `Tiramisu64_7`, `Tiramisu64_8` | Root, repeated cold boots, peer isolation, unroot; lost-reply recovery on `_8` |

Live checks require `uid=0`, a Magisk `su` link, the bundled Kitsune version and
manager package, no competing `su`, and no bootstrap binary hash after reboot.
Unroot checks reboot again and require an unprivileged shell and an absent
manager package. Peer checks verify that unrooting one clone preserves another
clone's root, despite their shared master disk.

On all three Android versions, a non-executable copy of the known bootstrap
binary was planted temporarily: actual verification returned failure, and
passed again after removal. On Android 13, the live harness also discarded a
successful population reply in its extracted test copy and verified that the
normal retry completed safely. This can be reproduced with
`Run-Live-E2E.ps1 -Instance <disposable-instance> -SimulateLostPopulateReply`.
Ordinary runs extract the shipped engine/orchestrator and use the `.cmd`'s
embedded APK, debugfs and bootstrap; no development binaries are required.

Full host scrub was tested against isolated backup fixtures through the real
engine. Live tests used per-instance undo to preserve the original installations.
The standalone `debug.cmd Rvc64_5` launcher was also run live: it correctly
identified the selected instance and reported a successful boot, then exited 0.

After testing, the three original shared disks, player executable and instance
configuration files were restored from snapshots and verified by SHA-256.
Original instance settings and app-data file sizes/timestamps were checked;
pre-existing factory backups remained unchanged. All six disposable instances
were removed through Multi-Instance Manager, leaving only the original
`Pie64`, `Rvc64` and `Tiramisu64` instances.

Logs, screenshots and restoration hashes were recorded locally in
`%TEMP%\bsr-production-audit`. A separate, local cleanup command removes review
snapshots and generated temporary files. It removes the extra test-created Pie
backup only when both it and the restored master still match the recorded
SHA-256. Pre-existing recovery backups and original instance data are preserved.
This cleanup is a development task and adds no files or work to the user-facing
distribution.

Bundled APK, debugfs and su binaries retain their original hashes. They are
vendored dependencies; this review checks integrity and behavior rather than
claiming a new source audit of those compiled upstream projects. Historical
archive scripts are retained as reference material, outside the maintained
test suite. Compatibility with other BlueStacks or Windows releases still
requires testing on those releases.
