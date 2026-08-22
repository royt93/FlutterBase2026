# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

- This repo is the **source of `applovin_admob_sdk`** — a dual-provider ad SDK (AppLovin MAX + Google AdMob) for Flutter, targeting Android + iOS. Published to pub.dev.
- The package itself lives in `packages/ad_sdk/` — its own Flutter package with its own `pubspec.yaml`, `README.md`, `CHANGELOG.md`, `example/` app, and tests (the migration guide lives inside `doc/AD_PROMPT_FLUTTER.MD` → Appendix D, merged from the former standalone `MIGRATION.md` on 2026-08-20). This repo root holds no app code of its own (the host app that consumes this SDK — a WiFi stress tester, formerly developed alongside this SDK in the same repo — now lives in its own separate repo and depends on the published pub.dev package, not on this repo directly).
- `gma_mediation_applovin` (native AdMob↔AppLovin mediation plugin) and `applovin_max`/`AppLovinSDK` version pinning live at the **consuming app's** level (`dependency_overrides`), not here — see the pinning-wall notes below for why those exact versions matter when a consuming app upgrades.

## Common commands

**Where the tests live:** flat (no `unit/widget/integration` subfolders):

| Suite | Path | How to run |
|---|---|---|
| SDK (primary gate) | `packages/ad_sdk/test/` — 78 files, ~890 tests | `cd packages/ad_sdk && flutter test` |
| SDK on-device | `packages/ad_sdk/example/integration_test/` — 27 files (26 test suites + shared `scroll_helpers.dart`) | `cd packages/ad_sdk/example && flutter test integration_test/` (needs emulator/simulator; CI runs it on both) |

```bash
cd packages/ad_sdk
flutter pub get
flutter analyze
flutter test

cd example
flutter pub get
flutter test integration_test/
```

**CI** (`.github/workflows/test.yml`) pins **Flutter 3.35.1 stable**, four jobs:

- `sdk` — `flutter analyze` + `flutter test` in `packages/ad_sdk`. Primary gate.
- `pinning-wall` — runs `packages/ad_sdk/tool/check_pinning_wall.sh` (`pub get` + `pod install`) against `tool/pinning_check_app/`, a minimal consuming-app fixture reproducing the documented known-good AppLovin/GMA version combo, so an incompatible pin bump fails CI instead of surfacing at release time.
- `sdk-integration` — the example app's `integration_test/` on an Android emulator. Needs KVM, disk cleanup and a 3GB swapfile on the runner (OOM-killer flake, see the inline comments before touching it). Forces `AD_PROVIDER_ADMOB` because no real AppLovin SDK key is committed, so the AppLovin path can never init in CI.
- `sdk-integration-ios` — same tests on an iOS Simulator (Xcode 26.1.1 + CocoaPods), **sharded across 3 macOS runners** (`matrix.shard: [0,1,2]`, via `SHARD_TOTAL=3 SHARD_INDEX=...`). Unlike the Android job this one runs **one `flutter test` invocation per file** (`.github/scripts/integration-retry.sh`, shared with the Android job, plus one retry): with all files passed to a single invocation, one flaky app launch on the CI simulator hung until the 12-minute per-test timeout, took the next file down with `Failed to start Dart Development Service`, and hid the rest. Per-file isolation is nearly free (`flutter test` already relaunches the app between files) and names the file that broke; sharding cuts wall clock from ~41 min to ~16-18 min since each file pays its own ~49s Xcode build.

**Where the written history lives:** `doc/init.md` (project conventions), `doc/feature.md` + `doc/task/` (specs & completed task records — these predate the app/SDK split and mix both), `doc/audit/` (numbered audit rounds — this SDK has been through 12+; read the latest before re-litigating a design decision), `doc/README_TESTING.md`, `doc/SPLASH_SETUP.md`, `doc/UMP_SETUP.md`.

## Publishing to pub.dev

**Two traps `--dry-run` does not catch** (it reported "0 warnings" right before both failures): the upload API rejects any `screenshots:` description over **200** characters, and pana/pub.dev scoring separately wants the package `description` **and** every screenshot description under **160** characters or it silently drops 10 points each from "valid pubspec.yaml" and "example and screenshots". Also expect `flutter pub get` (in a consuming app) to keep reporting `doesn't match any versions` for a minute or two after a successful upload — the pub.dev API already serves the new version while the CDN edge still caches the old listing. Just retry; `pub cache clean` is unrelated.

`gma_mediation_applovin` is a native mediation plugin and cannot be declared inside this package — it must stay at the **consuming app's** level, pinned in that app's `dependency_overrides` alongside `applovin_max`. Two separate walls, easy to confuse, and relevant here because they constrain which SDK versions a consuming app can actually adopt:

- **Dart level:** `gma_mediation_applovin >=2.6.0` needs `meta ^1.17.0` while `flutter_test` from the CI-pinned Flutter 3.35.1 forces `meta 1.16.0`. And `google_mobile_ads` **8 and 9** need Dart `>=3.10.0` + Flutter `>=3.38.1`, which 3.35.1 (Dart 3.9.x) cannot satisfy — so the last 10 pub.dev points are gated on a Flutter upgrade, which would also raise this package's own `environment` floor and so be breaking for consumers.
- **CocoaPods level:** `applovin_max 4.6.4` requires `AppLovinSDK (= 13.6.3)`, but `gma_mediation_applovin 2.5.2` → `GoogleMobileAdsMediationAppLovin (~> 13.5.0.0)` → `AppLovinSDK (= 13.5.0)`. Both pin exact versions, so `pod install` cannot resolve them together in a consuming app pinned to `gma_mediation_applovin 2.5.2` unless it also holds `applovin_max` back to `4.6.0` even though this package declares `^4.6.4`.
- Verify any change here against a real consuming app with `flutter pub get` **and** `cd ios && pod install` **and** a real `flutter build apk` / `flutter build ios --simulator`: `pub get` succeeding proves nothing about the pod graph.

## Integration contract

The full contract lives in `packages/ad_sdk/README.md` — summary:

1. Consuming app calls `AdManager().setNavigatorKey(navigatorKey)` before `runApp`.
2. Consuming app adds `adRouteObserver` and `AdScreenRouteLogger()` to `navigatorObservers`.
3. **SDK init must happen inside the consuming app's splash screen, not in `main()`** — `SimpleEventBus` replays the most recent init-completion event to a listener that subscribes late, but still needs a listener registered before/during init to react to it as it happens.
4. Splash should implement: hard-cap timer, `AdManager().markSplashActive/Inactive()`, `incrementSplashCount()`, `AdLoadingDialog.showAdBuffer()` before `showAppOpenAd(bypassSafety: true)`.
5. Any screen displaying ads should extend `AdScreen` + `AdScreenState` (instead of `StatefulWidget`/`State`) to get `buildBanner()`, `showInterstitialAd()`, `showRewardedAd()`. RouteAware banner lifecycle is automatic when `adRouteObserver` is registered.
6. Built-in safety layer (daily/hourly/session caps, 30s throttle, CTR fraud, progressive cooldown) — don't bypass except the splash App Open ad (`bypassSafety: true`).
7. App Open never stacks on top of a modal — `showAppOpenAdOnResume` checks `AdScreenRouteLogger.isDialogOnTop` and skips while a dialog is showing. `_retryRefillAds` also returns early while a VIP entry is active.

## VIP entitlement

`VipManager` (reachable as `AdManager().vip`, nullable until SDK init completes) suppresses all ad surfaces automatically while a VIP entry is active. Consuming apps subscribe to `AdManager().vip!.activeListenable` for reactive UI.

- VIP grants **stack globally** — `addVip`/`redeemVip` with `stack: true` add onto the latest expiry across all active entries (clamped at `AdConfig.maxVipStackDuration`, ~90 days). A VIP can voluntarily watch a real rewarded ad to extend their window: pass `bypassVipGuard: true` to `showRewardedAd` so the (normally VIP-suppressed) rewarded surface still plays.
- Keys are **Ed25519-signed and verified offline** — only the public key ships in a consuming app, so decompiling the binary doesn't let anyone forge new valid keys. Mint new keys with the matching private key via `packages/ad_sdk/tool/vip_mint.dart` (never commit the private key). Redemption goes through `VipManager.redeemSignedKey(...)`, not a lookup table.
- `packages/ad_sdk/example` ships a reference `VipRedeemScreen` consuming apps can wrap with their own localized strings, signing public key, and privacy-policy launcher.
