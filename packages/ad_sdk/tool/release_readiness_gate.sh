#!/usr/bin/env bash
set -euo pipefail

stage="${1:-all}"
repo_root="$(git rev-parse --show-toplevel)"
package_dir="$repo_root/packages/ad_sdk"

_require_rg() {
  # Audit fix (post-T213) — every stage below that shells out to `rg`
  # used to let a missing binary through unnoticed. `api_check`'s bare
  # `rg -q ...` calls failed loudly under `set -e` (a confusing raw
  # "command not found", but at least a failure) — `secret_scan` was the
  # real bug: its `rg` call sat inside an `if (...)`, where `set -e` does
  # not apply, so `rg`'s exit 127 (not found) was indistinguishable from
  # "grep found nothing" and the stage reported PASSED with no scan
  # having run at all. Confirmed live on a real machine with no `rg`
  # installed: `secret_scan` printed "release gate: secret passed".
  # Checked explicitly, with a clear diagnostic, before either stage
  # touches `rg` at all.
  if ! command -v rg >/dev/null 2>&1; then
    echo 'release gate: rg (ripgrep) is required but is not installed —' \
      'install it before running this gate' >&2
    return 1
  fi
}

secret_scan() {
  _require_rg
  if (cd "$repo_root" && git ls-files 'packages/ad_sdk/lib/**' | xargs -r rg -n --pcre2 \
      '(?i)(private[_ -]?key|vip[_ -]?(key|token|code))\s*[:=]\s*[A-Za-z0-9._-]{20,}'); then
    echo 'release gate: possible secret found in production source' >&2
    return 1
  else
    true
  fi
}

api_check() {
  _require_rg
  test -f "$package_dir/lib/applovin_admob_sdk.dart"
  rg -q "export 'src/core/ad_manager.dart';" "$package_dir/lib/applovin_admob_sdk.dart"
  rg -q "export 'src/consent/consent_fallback.dart';" "$package_dir/lib/applovin_admob_sdk.dart"
}

size_check() {
  local kb
  kb=$(du -sk "$package_dir/lib" | awk '{print $1}')
  test "$kb" -le 2048 || { echo "release gate: lib is ${kb}KB (>2048KB)" >&2; return 1; }
}

dependency_check() {
  test -f "$package_dir/pubspec.lock"
  (cd "$package_dir" && flutter pub deps --style=compact >/dev/null)
}

case "$stage" in
  secret) secret_scan ;;
  api) api_check ;;
  size) size_check ;;
  dependency) dependency_check ;;
  all) secret_scan; api_check; size_check; dependency_check ;;
  *) echo "usage: $0 {secret|api|size|dependency|all}" >&2; exit 2 ;;
esac
echo "release gate: $stage passed"
