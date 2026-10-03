These are historical investigation scripts, retained as evidence of the original
rooting workflow. Several contain machine-specific paths, stop running players,
or modify shared disks. They are not the current implementation or test suite.

Use `tools/bsr_magisk.ps1` (embedded in `blueStackRoot.cmd`) for the maintained
workflow. The maintained regression suites are under `tests/`; `Run-Live-E2E.ps1`
requires an explicitly named disposable instance. The old probes are preserved
without modernization so their original experimental results remain interpretable.
