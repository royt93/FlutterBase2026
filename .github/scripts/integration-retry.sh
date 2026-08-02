#!/bin/sh
# Run each integration_test/*_test.dart file in its OWN `flutter test`
# invocation, retrying a failed file once. Extra arguments are passed through
# to `flutter test` (device id, --dart-define flags, ...).
#
# Run from packages/ad_sdk/example.
#
# Why a file instead of an inline `script:` block in the workflow:
# android-emulator-runner hands its `script:` to /bin/sh in a way that
# collapses the body onto one line, so a multi-line `run_one() { ... }` died
# with "/usr/bin/sh: 1: Syntax error: end of file unexpected (expecting })".
# An earlier attempt using bash arrays died on the same runner with
# "Syntax error: "(" unexpected" — /bin/sh is dash on Ubuntu, not bash. A real
# file has neither problem and can be checked locally with `dash -n`.
#
# Keep this POSIX sh: no arrays, no [[ ]], no `local`.
#
# Why per-file at all, and why retry: passing all 18 files to a single
# invocation let one bad app launch hide the other 17 behind a 12-minute
# timeout (CI run 30697397657). Isolation names the file that broke; the retry
# absorbs the launch flake, which lands on a different file every run. Retries
# are always logged by name — of four files that needed one, three were the
# infra launch hang and one was a real assertion failure that a silent retry
# would have buried.
set -u

# Cut the dead wait when a file hangs. The default for integration_test is 12
# minutes, and the hang burns every second of it while producing no output at
# all — a hung run costs ~17 minutes including teardown, which on run
# 30734786580 was 17 of the iOS job's 40. Measured against real timings: every
# file finishes in ~1 minute wall clock (18 files in ~19 minutes once the hung
# one is excluded), and the longest in-test waiting is app_boot_test's 45s poll
# plus cold start. 5 minutes leaves a wide margin over that while cutting a
# hang from 12 minutes to 5.
#
# This shortens the wait, it does not fix anything: a file that genuinely needs
# longer than 5 minutes will now fail, and that failure would be real
# information, not a false positive to paper over.
TEST_TIMEOUT=5m

files=$(ls integration_test/*_test.dart | grep -Ev '/(app_open|interstitial|rewarded)_ad_test\.dart$')

failed=""
retried=""

for f in $files; do
  echo "::group::$f"
  if flutter test "$f" --timeout "$TEST_TIMEOUT" "$@"; then
    echo "::endgroup::"
    continue
  fi
  echo "::endgroup::"
  echo "::warning file=$f::first attempt failed — retrying once"
  retried="$retried $f"

  # Grab evidence BEFORE the retry relaunches the app and overwrites the
  # interesting state. Only on the iOS job, where SIMULATOR_UDID is set — the
  # launch hang has never reproduced locally, so CI is the only place this
  # data exists. Deliberately small: `simctl diagnose` produces hundreds of MB.
  if [ -n "${SIMULATOR_UDID:-}" ]; then
    diag="/tmp/sim-diag/$(basename "$f" .dart)"
    mkdir -p "$diag"
    date -u > "$diag/when.txt"
    xcrun simctl list devices booted > "$diag/booted-devices.txt" 2>&1 || true
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl list > "$diag/launchctl-list.txt" 2>&1 || true
    ps aux | grep -E "Simulator|adSdkExample|dart|flutter" | grep -v grep > "$diag/processes.txt" 2>&1 || true
    tail -n 3000 "$HOME/Library/Logs/CoreSimulator/$SIMULATOR_UDID/system.log" > "$diag/system.log" 2>&1 || true
    # system.log came back essentially EMPTY on the first hang we captured
    # (run 30730904622: two lines, nothing at all across the 12-minute
    # window) while diagnosticd inside the sim burned 42.9% CPU for 9m35s.
    # `log show` reads the real log store instead of that file, so it is the
    # one source that can confirm or kill the "the simulator's logging
    # subsystem is wedged, so flutter never sees the VM-service URI"
    # hypothesis. Tail-bounded because 15 minutes of os_log can be large.
    xcrun simctl spawn "$SIMULATOR_UDID" log show --last 15m --style compact 2>&1 \
      | tail -n 20000 > "$diag/log-show.txt" || true
  fi

  # Retry verbosely: if the retry hangs too, `-v` shows which step flutter is
  # stuck on (install, launch, or waiting for the VM service). A normal retry
  # prints nothing useful about that, and the first attempt cannot be re-run
  # after the fact.
  echo "::group::$f (retry)"
  if flutter test "$f" -v --timeout "$TEST_TIMEOUT" "$@"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error file=$f::integration test failed on both attempts"
    failed="$failed $f"
  fi
done

if [ -n "$retried" ]; then
  echo "::warning::Files that needed a retry:$retried"
fi

if [ -n "$failed" ]; then
  echo "Failed files (both attempts):$failed"
  exit 1
fi
