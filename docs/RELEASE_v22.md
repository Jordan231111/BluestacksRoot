- Fix Turkish-locale path discovery (#36).
- Fit the menu to narrow and short windows, respecting font size and display scaling.
- Expand `debug.cmd` with `--files-only`, isolated payload checks, cloud/temp-file evidence and detailed failure summaries.
- Fix error text lost during path redaction (#38). The underlying file failure is still unconfirmed; OneDrive is not an established cause.

Tested under Windows PowerShell 5.1, including three locales and 28 native console size/font combinations. Bundled binaries are unchanged. [Investigation and validation](https://github.com/Jordan231111/BluestacksRoot/blob/v22/docs/ISSUES_36_38.md).

Download **`blueStackRoot.cmd`** to root; **`debug.cmd`** is optional troubleshooting.
