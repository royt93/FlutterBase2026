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

# Per-TEST timeout, i.e. once a test body is actually running. Kept because it
# is the right bound for a test that hangs inside itself, but be clear about
# what it does NOT do — see the note below. Every real test body finishes in
# well under a minute; 5 leaves a wide margin.
TEST_TIMEOUT=5m

# `--timeout` above does NOT bound the hang, proven on run 30740897513: the
# failure still read "TimeoutException after 0:12:00" with --timeout 5m in
# effect. It is package:test's PER-TEST timeout, and the hang happens at the
# loading stage — the test never starts, so that clock is not the one running.
#
# So bound it from outside instead, where nothing about flutter's internals
# matters. Limits come from measured times on run 30738772564 (a clean run):
# the first file in a shard costs up to ~500s because it pays the cold Xcode
# build and first simulator install, every later file ran 69-144s. 10 minutes
# and 5 minutes leave room above both without waiting out a 12-minute hang.
FIRST_FILE_LIMIT_SECS=${FIRST_FILE_LIMIT_SECS:-600}
FILE_LIMIT_SECS=${FILE_LIMIT_SECS:-300}

# Run "$@", killing it after $1 seconds. Prefers coreutils timeout when the
# runner has it (Ubuntu does, macOS does not) and falls back to a plain POSIX
# watchdog. A killed command exits non-zero, which is exactly what the caller
# already treats as a failed attempt.
run_bounded() {
  _limit=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -s KILL "$_limit" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout -s KILL "$_limit" "$@"
    return $?
  fi
  "$@" &
  _cmd_pid=$!
  # >/dev/null on the watchdog subshell: without it the subshell inherits this
  # script's stdout and holds the pipe open, so a caller doing `script | grep`
  # hangs after the script itself has finished. Caught while testing this.
  ( sleep "$_limit"; kill -9 "$_cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _wd_pid=$!
  wait "$_cmd_pid"
  _status=$?
  kill "$_wd_pid" 2>/dev/null
  if [ "$_status" -eq 137 ]; then
    # 137 = SIGKILL, i.e. the watchdog fired rather than the test failing.
    # Worth naming in the log so a wall-clock kill is never mistaken for a
    # test that legitimately failed.
    #
    # Note: `flutter` is a wrapper script, so killing it may leave the dart
    # snapshot doing the real work behind. No cleanup is attempted here — a
    # broad `pkill -f flutter` would kill an unrelated `flutter test` when
    # someone runs this script on their own machine, and there is as yet no
    # evidence orphans actually survive. If a kill turns out to poison the
    # next file, that is the thing to look at.
    echo "::warning::hit the ${_limit}s wall-clock limit and was killed"
  fi
  return $_status
}

files=$(ls integration_test/*_test.dart | grep -Ev '/(app_open|interstitial|rewarded)_ad_test\.dart$')

# Optional sharding: SHARD_TOTAL=3 SHARD_INDEX=0|1|2 runs a third of the files.
#
# Every file pays its own Xcode build because each one is a separate Dart
# entrypoint — `flutter test integration_test/foo_test.dart` packages an app
# whose main() IS that file, so no single binary can serve all of them, and
# `flutter test` has no --use-application-binary to reuse one anyway. Measured
# on run 30738772564: 18 builds, 879s total (14.6 min, avg 49s, first 117s) out
# of a 41-minute job. Sequential, that cost cannot be removed — only spread.
#
# Round-robin (NR % total) rather than contiguous blocks: file durations vary
# from 69s to 144s, and interleaving keeps the shards closer in length than
# slicing the alphabetical list would.
if [ -n "${SHARD_TOTAL:-}" ]; then
  files=$(printf '%s\n' $files | awk -v t="$SHARD_TOTAL" -v i="${SHARD_INDEX:-0}" 'NR % t == i')
  echo "Shard ${SHARD_INDEX:-0}/$SHARD_TOTAL — $(printf '%s\n' $files | wc -l | tr -d ' ') files"
fi

failed=""
retried=""

file_no=0
for f in $files; do
  file_no=$((file_no + 1))
  if [ "$file_no" -eq 1 ]; then
    limit=$FIRST_FILE_LIMIT_SECS
  else
    limit=$FILE_LIMIT_SECS
  fi
  echo "::group::$f"
  if run_bounded "$limit" flutter test "$f" --timeout "$TEST_TIMEOUT" "$@"; then
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
  if run_bounded "$limit" flutter test "$f" -v --timeout "$TEST_TIMEOUT" "$@"; then
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
