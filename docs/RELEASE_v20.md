Fixes disk-format handling and improves evidence for Windows failures reported in #31 and #32.

- Detect VHD/VHDX content and test mounting before modifying the player or root settings.
- Harden disk copying, cleanup, and player launching. Distribution remains one self-contained `blueStackRoot.cmd`.
- Expand `debug.cmd` with read-only disk probes, native error codes, file hashes/signatures, permissions, policy events, and exact-instance ADB checks. User-directory names are masked; technical details stay visible.
- Remove the obsolete `recovered/BstkRooter` files and their unused legacy assembler.

Tested full rooting and cold-boot persistence on Android 11 and 13 with BlueStacks 5.22.265.1013.

If either issue persists, run the attached `debug.cmd` and attach its Desktop log. The original launch-denial policy has not been reproduced locally, so this release does not claim every access-denied case is resolved.
