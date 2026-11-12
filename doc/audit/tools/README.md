# doc/audit/tools

Helpers used while auditing the SDK on real devices. This directory is outside `packages/ad_sdk`, so
it is not part of the pub.dev tarball.

## adb_smoke.sh (T277)

```bash
source doc/audit/tools/adb_smoke.sh
export ADB_SERIAL=<serial>                      # optional if exactly one device is attached
smoke_init <evidence_dir> <logfile>             # starts continuous logcat; clears it ONCE
trap restore_device EXIT                        # density, Wi-Fi and clock are put back even on failure
open_item "VIP / redeem"                        # coordinates come from uiautomator, not constants
type_secret_and_submit <keyfile> "Activate" "redeemSignedKey result"
shot name                                       # screenshot into <evidence_dir>/name.png
crash_check
redact_file <log>                               # REQUIRED before a log goes into the repo
```

What it does not do: it cannot see native overlays (UMP form, full-screen ads) in `uiautomator`; use
`tap_xy` with coordinates read from a screenshot and say so in the evidence notes. It does not decide
whether a test passed; `type_secret_and_submit` only checks that the SDK logged a reaction, and returns 2
if it did not (the field was probably not cleared or a keyboard covered the button).

Known pitfall found while writing it: Android's adbd logs every `adb shell input text <value>` into
logcat, so a typed key lands in the saved log unless `redact_file` is run.

Verified once on a TECNO KJ7 (Android 14): opened a screen by label, typed an obviously invalid key from a
file, the SDK reported `bad format`, FATAL/ANR 0, device settings restored. Not run on the S24U or in CI.
