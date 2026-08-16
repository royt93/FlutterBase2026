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

cd "$fixture_dir"
flutter pub get

cd ios
pod install --repo-update

echo "== pinning-wall check passed =="
