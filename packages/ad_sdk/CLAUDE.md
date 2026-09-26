# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Run commands from `packages/ad_sdk/` unless noted.

- **Install dependencies:** `flutter pub get`; example app: `(cd example && flutter pub get)`
- **Analyze:** `flutter analyze`; example app: `(cd example && flutter analyze)`
- **Format:** `dart format .`
- **All unit/widget tests:** `flutter test`
- **Single test file:** `flutter test test/api_golden_test.dart`
- **Single test case:** `flutter test test/api_golden_test.dart -n "public API surface"`
- **Example widget tests:** `(cd example && flutter test)`
- **Integration tests:** `(cd example && flutter test integration_test/)` with a booted device/emulator/simulator
- **Single integration test:** `(cd example && flutter test integration_test/banner_ad_test.dart -d <deviceId>)`
- **Run example app:** `(cd example && flutter run)`; pass provider IDs via `--dart-define` as documented in `example/lib/main.dart`
- **Build example Android:** `(cd example && flutter build apk --debug)`
- **Build example iOS simulator:** `(cd example && flutter build ios --simulator --debug)`
- **Regenerate public API golden after intentional API change:** `dart run tool/api_surface.dart > test/goldens/public_api_surface.txt`
- **Release gate:** `./tool/release_readiness_gate.sh all` (`secret|api|size|dependency|all`)
- **Pinning-wall check:** `./tool/check_pinning_wall.sh`; release-shaped changes use `./tool/check_pinning_wall.sh --with-builds`
- **Publish dry-run:** `dart pub publish --dry-run`
- **Generate VIP keypair:** `dart tool/vip_keygen.dart`
- **Mint VIP token:** `dart tool/vip_mint.dart --priv-file .vip-private-key --days 30 --valid-days 30 --bundle com.example.app --kid DEMO1` (use bare `dart`, not `dart run`; `--priv` is intentionally disabled)
- **Mint VIP revocation list:** `dart tool/vip_crl_mint.dart --priv-file .vip-private-key --kids DEMO1 --revision 1`
- **Verify signed exports:** `dart run tool/verify_compliance_report.dart <path>`, `dart run tool/bypass_audit_replay.dart <path>`, `dart run tool/incident_replay.dart <path>`

## Big-picture architecture

This package is a Flutter SDK that exposes one public barrel, `lib/applovin_admob_sdk.dart`, for AdMob and AppLovin MAX. Public API stability is guarded by `test/api_golden_test.dart`; intentional public changes require a `CHANGELOG.md` entry and regenerated `test/goldens/public_api_surface.txt`.

`AdManager` (`lib/src/core/ad_manager.dart`) is the singleton orchestrator. It owns config, lifecycle observation, consent/VIP/safety gates, the active adapter, fullscreen busy state, SDK-owned persistence, and the broadcast `events` stream. Keep provider-specific native SDK calls out of `AdManager`; route them through `AdProviderAdapter`.

`AdProviderAdapter` (`lib/src/core/ad_provider_adapter.dart`) is the provider boundary. `AdMobAdapter` and `AppLovinAdapter` implement it; `FakeAdapter` is for tests. Fullscreen slots are singleton adapter fields. Inline formats (`banner`, `mrec`, `native`) are keyed per widget instance, with matching dispose methods; avoid reintroducing shared singleton inline state.

`AdSlot` (`lib/src/state/ad_slot.dart`) is the ad state machine (`idle`, `loading`, `ready`, `showing`, `cooldown`). Load/show methods must use slot transition helpers instead of ad-hoc booleans so duplicate loads, double-shows, cooldowns, and dismiss recovery stay consistent.

`AdManager().events` emits typed `AdEvent`s (`AdLoadEvent`, `AdShowEvent`, `AdSkipEvent`, `AdRevenueEvent`, anomalies, self-healing observations). Monetization modules in `lib/src/monetization/` are mostly opt-in observers over this stream; they should not shadow-request or silently switch providers in-session.

Consent/compliance live across `lib/src/consent/`, `lib/src/core/ad_consent.dart`, and `lib/src/compliance/`. Google UMP is the default consent path; AppLovin consent writes are limited by the plugin's fire-and-forget API. Signed compliance, bypass-audit, consent-provenance, and incident exports share Ed25519 signing helpers.

VIP logic lives in `lib/src/vip/`. Signed VIP keys are offline Ed25519 tokens (AVP2 by default) with optional expiry and bundle binding. iOS has Keychain-backed anti-bypass; Android remains weaker without a backend, as documented in `README.md`.

Widgets in `lib/src/widget/` are the public UI surfaces and diagnostics. `BannerAdWidget`/`MrecAdWidget` combine route lifecycle, visibility detection, per-instance adapter state, and provider-specific rendering. `AdScreen`/`AdScreenRouteLogger` provide route-aware lifecycle glue.

Persistent SDK state goes through `AdPreferences` (`lib/src/utils/ad_preferences.dart`) plus `flutter_secure_storage` for VIP entitlement data. Do not use broad preference clears for privacy erasure; use `AdManager.clearSdkData(...)` semantics.

`example/` is both demo app and integration-test host, not a production template. Real ad IDs and AppLovin SDK key are supplied via `--dart-define`; placeholders in source are deliberate.

## Owner-approved product decisions — do not reopen as audit findings

- VIP promotion-code activation **must require network**. Ed25519 verification is local, but online redemption permits signed-CRL refresh and reduces leaked-code abuse. VIP works offline after activation. Do not add offline redemption or grace without explicit owner approval.
- AppLovin MAX COPPA status is fixed at SDK initialization. The product does not support a mid-session age-status switch. If a host flips it later, warning-only behavior is intentional; do not add forced teardown, app restart, or a repeat finding without explicit owner approval. `AppLovinAdapter.initialize()` remains fail-closed when the status is already child-directed.
- Offline VIP codes are promotions, never globally single-use paid licenses. Android trial anti-reinstall protection is best-effort through OS backup; no backend/device-fingerprint workaround is wanted.
- The built-in `kQaTestDeviceHashes` fleet stays active in release builds with no opt-out. This is owner-approved: protecting the AdMob account from QA invalid traffic outweighs revenue from those few devices. Do not propose debug-only or per-app test-device handling without explicit owner approval.
- AVP1 and AVP2 VIP codes intentionally coexist. New integrations use AVP2; hosts that issued AVP1 codes can opt in with `allowLegacyV1: true`. Do not propose removing AVP1 support or treat its coexistence as an audit finding without explicit owner approval.

## Dependency and release constraints

Dependency versions are deliberately constrained around Flutter/Dart and CocoaPods pinning walls. Do not loosen or bump `google_mobile_ads`, `applovin_max`, `gma_mediation_applovin`, `wakelock_plus`, `package_info_plus`, or `flutter_secure_storage` casually. Re-read `pubspec.yaml` comments and run `tool/check_pinning_wall.sh --with-builds` for release-shaped dependency changes.

`google_mobile_ads` is pinned below `9.1.0` because `9.1.0` has a confirmed iOS build regression. AppLovin iOS mediation pins must agree on exact `AppLovinSDK` version; the pinning check asserts the resolved CocoaPods version.

## Task workflow

Backlog files live in `doc/task/`:

- `doc/task/todo/` — not started
- `doc/task/inprogress/` — active work
- `doc/task/done/` — completed

When taking a task, move its file with `git mv`, update `Status:`, satisfy acceptance criteria, then move it to `done/`. Do not create broad architecture abstractions unless the task explicitly needs them.

## Test requirement

Every behavior change needs tests for every meaningful branch: success, failure, offline, invalid input, lifecycle teardown, and relevant provider/platform divergence. Use unit tests for pure/state logic, widget tests for UI/lifecycle, and Android/iOS integration tests for platform/plugin behavior. Comments, documentation, and wording-only changes need no duplicate tests; rerun closest existing coverage instead. Do not close behavior work on static analysis alone.
