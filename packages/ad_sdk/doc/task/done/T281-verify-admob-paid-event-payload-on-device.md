# T281 — Verify AdMob paid-event payload on Android

- **Type:** Verification / test enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Confidence:** Evidence gap, not a confirmed defect.
- **Status:** done (2026-11-15; controlled mapping tests and S24 Ultra native paid-event integration passed)
- **Evidence:** `lib/src/adapters/admob_adapter.dart:155-225`; `lib/src/adapters/gma_bridge.dart:47-53`; `test/admob_behavioral_test.dart:1823-1889`; `example/integration_test/t185_revenue_request_id_test.dart`

## Context

T185 originally verified that the real AdMob paid-event callback carries the request ID from its ad load, but did not assert the remaining payload. Google test ads do not guarantee a fixed revenue amount or mediation waterfall, so assertions must validate shape and contract, not exact revenue.

## Acceptance criteria

- [x] Controlled adapter callback test asserts `valueMicros`, `currencyCode`, `precision`, ad type, placement, and matching `requestId` for interstitial. Other fullscreen formats retain their request-ID checks.
- [x] Device integration asserts nonnegative `valueMicros`, uppercase three-letter currency, an allowed Google `PrecisionType` name (`unknown`, `estimated`, `publisherProvided`, `precise`), interstitial type, unspecified placement, and matching load `requestId`.
- [x] Event listener is scoped to this request and cancelled with `addTearDown`.
- [x] Integration passed on Samsung S24 Ultra `R5CX613VZBR` (SM-S928B, Android 17) using Google test ads and disposable app ID `com.roy.admobwrapper.t281smoke`. Ran from isolated source copy under `/tmp/ad-sdk-t281-isolated`; original `com.roy.admobwrapper` was not touched.
- [x] The stricter precision enum assertion was included in the final integration run, which exited successfully after using a lean source copy without generated caches.
- [x] `flutter analyze` passed; full SDK suite passed: 2,858 tests.
- [x] Widget/golden N/A: no UI or public API change. Interruption, network conditioning, memory/profile, frame/jank, and mediation N/A: this test only validates one paid-event callback and does not change lifecycle/resource behavior; waterfall metadata is not guaranteed by test inventory. IAP is host-app scope.
- [x] Google test IDs only; no production IDs, credentials, or ad clicks.

## Test plan

- **Unit:** controlled adapter callback validates mapping without assuming real revenue.
- **Integration/device:** run `flutter test integration_test/t185_revenue_request_id_test.dart -d R5CX613VZBR --dart-define=AD_PROVIDER_ADMOB=true --reporter expanded` from the isolated `example/`.
- **Other dimensions:** N/A with reasons recorded above.
