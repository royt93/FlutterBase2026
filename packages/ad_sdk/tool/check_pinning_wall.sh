#!/usr/bin/env bash
# T85 — verifies the documented CocoaPods/Dart pinning wall (see CLAUDE.md)
# still resolves. `tool/pinning_check_app/` is a minimal fixture that
# depends on this package plus the exact known-good combo of
# gma_mediation_applovin + a dependency_overrides-pinned applovin_max.
#
# Run from anywhere; always resolves paths relative to this script.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$script_dir/pinning_check_app"

echo "== T85: pinning-wall check =="
echo "Fixture: $fixture_dir"

# Pass --with-builds (or set WITH_BUILDS=1) to also run a real
# `flutter build apk` + `flutter build ios --simulator`. Off by default
# because the two builds add ~8 minutes; on for anything release-shaped.
#
# Why the builds matter even though pub get + pod install already passed:
# both of those succeeding proves only that a dependency graph exists on
# paper. `flutter pub publish --dry-run` reported "0 warnings" immediately
# before two separate real upload failures (see CLAUDE.md), and a resolvable
# pod graph still says nothing about whether the thing links and compiles.
with_builds=0
[[ "${WITH_BUILDS:-0}" == "1" ]] && with_builds=1
for arg in "$@"; do [[ "$arg" == "--with-builds" ]] && with_builds=1; done

cd "$fixture_dir"
flutter pub get

cd ios
pod install --repo-update

# The pin that actually breaks in the field is AppLovinSDK: applovin_max and
# GoogleMobileAdsMediationAppLovin each pin it to an EXACT version, so the
# graph only resolves while both land on the same one. `pod install` exiting 0
# does not prove that — CocoaPods is happy the moment it finds *any* solution,
# including one reached by silently moving a pod we meant to hold. So assert
# the resolved version rather than trusting the exit code.
expected_applovin_sdk="13.5.0"
resolved_applovin_sdk="$(awk '/^  - AppLovinSDK \(/{gsub(/[()]/,"");print $3; exit}' Podfile.lock)"
echo "AppLovinSDK resolved to: ${resolved_applovin_sdk:-<none>}"
if [[ "$resolved_applovin_sdk" != "$expected_applovin_sdk" ]]; then
  echo "FAIL: expected AppLovinSDK $expected_applovin_sdk, got '${resolved_applovin_sdk:-<none>}'." >&2
  echo "      Either a pin moved or the known-good combo in CLAUDE.md is stale." >&2
  echo "      Do not 'fix' this by loosening a pin without re-reading the" >&2
  echo "      pinning-wall notes in CLAUDE.md first." >&2
  exit 1
fi

if [[ "$with_builds" == "1" ]]; then
  cd "$fixture_dir"
  echo "== building for Android =="
  flutter build apk --debug
  echo "== building for iOS simulator =="
  flutter build ios --simulator --debug
  echo "== both platforms built =="
else
  echo "(skipping real builds — pass --with-builds to include them)"
fi

echo "== pinning-wall check passed =="
