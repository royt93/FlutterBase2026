# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Install Dependencies:** `flutter pub get` (run in the root and in `example/`)
- **Lint:** `flutter analyze`
- **Format:** `dart format .`
- **Unit & Widget Tests:** `flutter test`
- **Single Test:** `flutter test test/path_to_test.dart`
- **Integration Tests:** `cd example && flutter test integration_test/` (Requires emulator/device)
- **Run Example App:** `cd example && flutter run`
- **API Surface Check:** `dart run tool/api_surface.dart > test/goldens/public_api_surface.txt`
- **Release Gate:** `./tool/release_readiness_gate.sh all`
- **Pinning Wall Check:** `./tool/check_pinning_wall.sh --with-builds`
- **Generate VIP Keys:** `dart tool/vip_keygen.dart` (Note: Use `dart` not `dart run`)
- **Mint VIP Tokens:** `dart tool/vip_mint.dart --priv <b64priv> --days <num> --kid <name>`
- **Verify Exported JSON:** `dart run tool/verify_compliance_report.dart <path>`, `dart run tool/bypass_audit_replay.dart <path>`

## High-Level Architecture

This is a production-grade dual-provider ad SDK wrapper for Flutter. It unifies Google AdMob (`google_mobile_ads`) and AppLovin MAX (`applovin_max`) behind a single API with built-in compliance, safety gating, and VIP management.

- **`AdManager` Singleton (`lib/src/core/ad_manager.dart`):** The orchestrator and entry point for the SDK. It holds the active adapter, VIP gate, safety configurations, consent state, and the global event bus. It contains no provider-specific logic itself.
- **Adapter Pattern (`lib/src/core/ad_provider_adapter.dart`):** `AdProviderAdapter` defines the contract for underlying ad networks. Concrete implementations are `AdMobAdapter`, `AppLovinAdapter`, and `FakeAdapter` (for test gating).
- **Ad Slots (`lib/src/state/ad_slot.dart`):** Manages the state machine (idle, loading, ready, showing, cooldown) for each ad slot type (app open, interstitial, rewarded, banner, mrec, native). It handles debouncing, timeouts, and state transitions safely.
- **Event Bus (`lib/src/state/ad_event.dart`):** `AdManager().events` broadcasts typed events (e.g., `AdLoadEvent`, `AdShowEvent`, `AdRevenueEvent`, `AdSkipEvent`, `AdAnomalyEvent`). This enables decoupled observability and powers the monetization modules.
- **Monetization & Analytics (`lib/src/monetization/`):** A suite of opt-in, decoupled observer modules that listen to the event bus. Features include `MonetizationArbitrator`, `WaterfallTuner`, `FillRateMonitor`, `JourneyPrefetcher`, and `RevenueAnomalyDetector`.
- **Compliance & VIP (`lib/src/compliance/`, `lib/src/vip/`):** Provides offline Ed25519-signed VIP key mechanics (`VipManager`), GDPR/COPPA/CCPA consent flow wrappers (`ConsentManager`), and signed tamper-evident logs for audit/dispute purposes (`ComplianceReport`, `BypassAuditTrail`, `IncidentRecorder`).
