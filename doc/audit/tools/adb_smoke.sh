#!/usr/bin/env bash
# Reusable adb helpers for manual smoke tests of the ad_sdk example (T277).
# Source it:   source doc/audit/tools/adb_smoke.sh
# Lives OUTSIDE packages/ad_sdk on purpose, so it is not part of the pub.dev tarball.
#
# Design rules (each one comes from a mistake made during audit round 79):
#  - Tap coordinates are read from `uiautomator dump`, never hardcoded: phones differ
#    (TECNO 1080x2436, S24U 1080x2340 + density override) and layouts shift when the
#    keyboard opens. Native UMP/ad overlays are NOT visible to uiautomator; for those use
#    tap_xy with coordinates taken from a screenshot and say so in the evidence notes.
#  - Logcat is recorded continuously to one file; never `logcat -c` between steps.
#  - This script never PRINTS key values, CRL codes or LAN addresses, BUT Android's own adbd logs every
#    `adb shell input text <value>` into logcat ("adbd service requested 'shell,...:input text <value>'"),
#    so any secret typed that way lands in the saved log. Always run redact_file on a log before it goes
#    into the repo, and use throwaway keys only (found when this script's dry run left a fake key in the log).
#  - Anything this script changes on the device is restored by restore_device (call it in a trap).
#  - User-0 only for package queries (S24U has a work profile user that raises SecurityException).
#
# Requires: adb, python3. Env: ADB_SERIAL (optional; defaults to the only attached device).

set -u

adb_s() { if [ -n "${ADB_SERIAL:-}" ]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi; }

smoke_init() { # smoke_init <evidence_dir> <logfile>
  SMOKE_EVIDENCE="$1"; SMOKE_LOG="$2"; mkdir -p "$SMOKE_EVIDENCE"
  if [ -z "${ADB_SERIAL:-}" ]; then
    local n; n=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
    [ "$n" = "1" ] || { echo "smoke_init: expected exactly 1 device, found $n; set ADB_SERIAL" >&2; return 1; }
  fi
  SMOKE_ORIG_DENSITY="$(adb_s shell wm density | grep -c Override)"
  SMOKE_ORIG_WIFI="$(adb_s shell settings get global wifi_on)"
  SMOKE_ORIG_TIME_DELTA=0
  SMOKE_START_EPOCH_HOST=$(date +%s)
  adb_s logcat -c   # once, before the run; never again
  adb_s logcat -v time > "$SMOKE_LOG" 2>&1 &
  SMOKE_LOGCAT_PID=$!
  echo "smoke_init: device=$(adb_s shell getprop ro.product.model | tr -d '\r') android=$(adb_s shell getprop ro.build.version.release | tr -d '\r') log=$SMOKE_LOG"
}

ui_dump() { adb_s shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb_s exec-out cat /sdcard/ui.xml; }

# center of the first element whose content-desc/text STARTS WITH $1 -> "x y" or NOTFOUND
# Parses one <node ...> at a time: a single regex over text=/content-desc=/bounds= swallows the
# bounds of a node whose empty text="" matched first, so its content-desc was never checked.
find_center() {
  ui_dump | python3 -I -c '
import sys,re,html
label=sys.argv[1]; x=sys.stdin.read()
for node in re.findall(r"<node\b[^>]*>", x):
    attrs=dict(re.findall(r"([\w-]+)=\"([^\"]*)\"", node))
    b=re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attrs.get("bounds",""))
    if not b: continue
    for key in ("content-desc","text"):
        if html.unescape(attrs.get(key,"")).startswith(label):
            a,c,d,e=map(int,b.groups()); print((a+d)//2,(c+e)//2); sys.exit(0)
print("NOTFOUND")' "$1"
}

# center of the first EditText -> "x y clearX"
find_edittext() {
  ui_dump | python3 -I -c '
import sys,re
x=sys.stdin.read()
m=re.search(r"class=\"android.widget.EditText\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", x)
print((int(m.group(1))+int(m.group(3)))//2,(int(m.group(2))+int(m.group(4)))//2,int(m.group(3))-60) if m else print("NOTFOUND")'
}

tap_xy() { adb_s shell input tap "$1" "${2:?tap_xy needs x and y as two arguments}"; }
tap_label() { local p x y; p=$(find_center "$1"); [ "$p" = NOTFOUND ] && { echo "tap_label: '$1' not found" >&2; return 1; }; read -r x y <<<"$p"; tap_xy "$x" "$y"; }

scroll_to_top() { local i; for i in 1 2 3 4 5 6; do adb_s shell input swipe 540 600 540 2000 250; done; sleep 1; }
scroll_down()   { adb_s shell input swipe 540 1900 540 900 300; sleep 1; }

open_item() { # open_item <label>: from the home list, scroll until the label is visible and tap it
  scroll_to_top
  local i p
  for i in 1 2 3 4 5 6 7 8; do p=$(find_center "$1"); if [ "$p" != NOTFOUND ]; then local x y; read -r x y <<<"$p"; tap_xy "$x" "$y"; sleep 3; return 0; fi; scroll_down; done
  echo "open_item: '$1' not found" >&2; return 1
}

shot() { adb_s exec-out screencap -p > "$SMOKE_EVIDENCE/$1.png"; [ -s "$SMOKE_EVIDENCE/$1.png" ] || { echo "shot: empty $1.png" >&2; rm -f "$SMOKE_EVIDENCE/$1.png"; return 1; }; }

# type a secret from a FILE into the focused/first text field, hide the keyboard, press Activate.
# The value is never echoed. Verifies the SDK reacted by counting a log marker before/after.
type_secret_and_submit() { # <keyfile> <submit_label> <log_marker_regex>
  local n0 n1 fx fy xx
  n0=$(grep -cE "$3" "$SMOKE_LOG")
  read -r fx fy xx < <(find_edittext); [ "$fx" = NOTFOUND ] && { echo "no text field" >&2; return 1; }
  tap_xy "$xx" "$fy"; sleep 1; tap_xy "$fx" "$fy"; sleep 1
  adb_s shell input text "$(cat "$1")"; sleep 2
  adb_s shell input keyevent 111; sleep 1
  tap_label "$2"; sleep 6
  n1=$(grep -cE "$3" "$SMOKE_LOG")
  [ "$n1" -gt "$n0" ] || { echo "submit did not reach the SDK (marker count $n0 -> $n1); retry" >&2; return 2; }
}

redact_file() { # scrub LAN IPs and signed-key/CRL-looking tokens in place
  sed -i.bak -E "s/192\\.168\\.[0-9]+\\.[0-9]+/<lan-ip>/g; s/(AVP[12]|CRL1)\\.[A-Za-z0-9_=-]{20,}/\\1.<redacted>/g; s/(input text )[^']*/\\1<redacted>/g" "$1" && rm -f "$1.bak"
}

crash_check() { echo "FATAL=$(grep -c 'FATAL EXCEPTION' "$SMOKE_LOG") ANR=$(grep -c 'ANR in' "$SMOKE_LOG")"; }

restore_device() { # safe to call repeatedly; also use as: trap restore_device EXIT
  [ -n "${SMOKE_LOGCAT_PID:-}" ] && kill "$SMOKE_LOGCAT_PID" 2>/dev/null
  adb_s shell wm density reset >/dev/null 2>&1
  adb_s shell svc wifi enable >/dev/null 2>&1
  adb_s shell cmd alarm set-time "$(( $(date +%s) * 1000 ))" >/dev/null 2>&1   # auto-time stays on; this only snaps to host time
  echo "restore_device: density reset, wifi enabled, clock set to host time"
}

# --- state-changing helpers (always paired with restore_device) ---
wifi_off()  { adb_s shell svc wifi disable; sleep 8; }
wifi_on()   { adb_s shell svc wifi enable;  sleep 8; }
set_density() { adb_s shell wm density "$1"; sleep 3; }
shift_clock() { adb_s shell cmd alarm set-time "$(( ( $(date +%s) + $1 ) * 1000 ))" >/dev/null; sleep 2; }  # seconds, may be negative
