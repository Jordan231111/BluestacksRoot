# archive/ — superseded code, kept for reference (nothing here is used by the current tool)

The working tool is `blueStackRoot.cmd` (root) + `tools/bsr_magisk.ps1` + `tools/bsr_engine.ps1`.
These files are **historical** — kept so you can look back on prior approaches. None are referenced
by the current pipeline.

## `legacy-scripts/` — pre‑Magisk / experimental rooting attempts
| File | What it was |
|---|---|
| `Bypass_Integrity_Check_Semantic.py` | Early Python HD‑Player anti‑tamper byte‑patch (now done by `bsr_engine.ps1 -Action Patch`). |
| `Bypass_Integrity_Check_Dynamic.cmd` | Batch wrapper for the above. |
| `RootJunction.cmd` / `UnRootJunction.cmd` | Old NTFS‑junction approach to swap rooted/stock disks. |
| `split.cmd` | Helper to split/join large blobs. |
| `Magisk.cpp` | Magisk source/decompiled snippet used while studying the daemon. |
| `uninstall_script.sh` | Old guest‑side uninstaller. |
| `magiskkitsune.apk` | A *different* Magisk Delta build (the tool embeds `Working Example & Fix/Magisk-27.2-kitsune-4.apk`). |

## `original-cmd/` — the original `blueStackRoot.cmd` before the rewrite
| File | What it is |
|---|---|
| `blueStackRoot.last-pushed.cmd` | The last **git‑pushed** version (486‑line ASCII‑menu tool), dumped from `HEAD`. |
| `blueStackRoot.original.cmd.bak` | Same era snapshot. |
| `blueStackRoot.head.cmd` | Just the batch‑logic head of an intermediate rewrite. |

## `dev-probes/` — one‑off diagnostic scripts from development
`probe*.ps1`, `guest-probe*.ps1`, `recon-data.ps1`, `sb-size.ps1`, `window-test.ps1`,
`apply-and-verify.ps1`, `reboot-native.ps1` — throwaway probes used to discover the architecture
(mount layout, su gating, disk sizes, boot windows). Superseded by the proven scripts in `tests/`.
