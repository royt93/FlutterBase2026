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
| SDK (primary gate) | `packages/ad_sdk/test/` — file/test counts grow every release, see `CHANGELOG.md`'s latest entry for the exact current numbers | `cd packages/ad_sdk && flutter test` |
| SDK on-device | `packages/ad_sdk/example/integration_test/` — 133 files (132 test suites + shared `scroll_helpers.dart`; audit round 42, 2026-09-17 — verify with `ls packages/ad_sdk/example/integration_test \| wc -l` rather than trusting this number long-term) | `cd packages/ad_sdk/example && flutter test integration_test/` (needs emulator/simulator; CI runs it on both) |

```bash
cd packages/ad_sdk
flutter pub get
flutter analyze
flutter test

cd example
flutter pub get
flutter test integration_test/
```

**CI** (`.github/workflows/test.yml`) pins **Flutter 3.38.1 stable** (bumped from 3.35.1 — see the pinning-wall notes below for why), four jobs:

- `sdk` — `flutter analyze` + `flutter test` in `packages/ad_sdk`. Primary gate.
- `pinning-wall` — runs `packages/ad_sdk/tool/check_pinning_wall.sh` (`pub get` + `pod install`) against `tool/pinning_check_app/`, a minimal consuming-app fixture reproducing the documented known-good AppLovin/GMA version combo, so an incompatible pin bump fails CI instead of surfacing at release time.
- `sdk-integration` — the example app's `integration_test/` on an Android emulator. Needs KVM, disk cleanup and a 3GB swapfile on the runner (OOM-killer flake, see the inline comments before touching it). Forces `AD_PROVIDER_ADMOB` because no real AppLovin SDK key is committed, so the AppLovin path can never init in CI.
- `sdk-integration-ios` — same tests on an iOS Simulator (Xcode 26.1.1 + CocoaPods), **sharded across 3 macOS runners** (`matrix.shard: [0,1,2]`, via `SHARD_TOTAL=3 SHARD_INDEX=...`). Unlike the Android job this one runs **one `flutter test` invocation per file** (`.github/scripts/integration-retry.sh`, shared with the Android job, plus one retry): with all files passed to a single invocation, one flaky app launch on the CI simulator hung until the 12-minute per-test timeout, took the next file down with `Failed to start Dart Development Service`, and hid the rest. Per-file isolation is nearly free (`flutter test` already relaunches the app between files) and names the file that broke; sharding cuts wall clock from ~41 min to ~16-18 min since each file pays its own ~49s Xcode build.

**Where the written history lives:** `doc/init.md` (project conventions), `doc/feature.md` + `doc/task/` (specs & completed task records — these predate the app/SDK split and mix both), `doc/audit/` (numbered audit rounds — this SDK has been through 12+; read the latest before re-litigating a design decision), `doc/README_TESTING.md`, `doc/SPLASH_SETUP.md`, `doc/UMP_SETUP.md`.

## Publishing to pub.dev

**Two traps `--dry-run` does not catch** (it reported "0 warnings" right before both failures): the upload API rejects any `screenshots:` description over **200** characters, and pana/pub.dev scoring separately wants the package `description` **and** every screenshot description under **160** characters or it silently drops 10 points each from "valid pubspec.yaml" and "example and screenshots". Also expect `flutter pub get` (in a consuming app) to keep reporting `doesn't match any versions` for a minute or two after a successful upload — the pub.dev API already serves the new version while the CDN edge still caches the old listing. Just retry; `pub cache clean` is unrelated.

`gma_mediation_applovin` is a native mediation plugin and cannot be declared inside this package — it must stay at the **consuming app's** level, pinned in that app's dependencies alongside `applovin_max`.

**RESOLVED (2026-09-22):** both the Dart-level and CocoaPods-level pinning walls below are fixed as of this package's `google_mobile_ads: '>=9.0.0 <9.1.0'` + Flutter `>=3.38.1` / Dart `>=3.10.0` floor bump (breaking; was `google_mobile_ads ^7.0.0` / Flutter `>=3.27.0`). A consuming app can now use `gma_mediation_applovin 2.6.2` or `2.6.3` (NOT `2.6.4` — its AppLovin iOS adapter moved to 13.6.4.0, diverging again) with a **plain** `applovin_max ^4.6.4`, no `dependency_overrides` needed. Verified for real: `flutter analyze` clean, 2255/2255 tests, `pod install` resolves `AppLovinSDK (13.6.3)` on both sides, `flutter build ios --simulator` succeeds. Pinned `google_mobile_ads` below `9.1.0` on purpose — that version ships a confirmed upstream iOS build regression (`Include of non-modular header inside framework module 'google_mobile_ads.FLTAd_Internal'` / `GoogleMobileAds_Beta.h`, from its new Ad Preloading API); `9.0.0` is also what `gma_mediation_applovin 2.6.2`'s own changelog says it was built and tested against. Revisit the `9.1.x` pin once Google ships a fix. One new requirement this
floor bump adds: on Android, `google_mobile_ads 9.0.0`'s native
`play-services-ads 25.3.0` ships Kotlin metadata compiled with Kotlin
2.3.0, so a consuming app's own Kotlin Gradle plugin must be `>= 2.3.0` or
`compileDebugKotlin` fails — see this SDK's own `example/android` for the
`settings.gradle.kts` version bump and the `build.gradle.kts` migration
off the old `kotlinOptions { jvmTarget = ... }` DSL (removed in 2.3.0).
Old history, kept for context:

- **Dart level (was):** `gma_mediation_applovin >=2.6.0` needed `meta ^1.17.0` while `flutter_test` from the old CI-pinned Flutter 3.35.1 forced `meta 1.16.0`. And `google_mobile_ads` **8 and 9** need Dart `>=3.10.0` + Flutter `>=3.38.1`, which 3.35.1 (Dart 3.9.x) could not satisfy. Audit round 43 (2026-09-18): `google_mobile_ads` 9.x also ships the `RequestConfiguration.ageRestrictedTreatment` (TFAT) API replacing the legacy `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent` this SDK still uses in `admob_adapter.dart`/`gma_bridge.dart`/`ad_consent.dart` — Google says the legacy pair keeps working through 2026 (no removal before a major release expected H1 2027), so migrating off it is still a follow-up, not blocking.
- **CocoaPods level (was):** `applovin_max 4.6.4` requires `AppLovinSDK (= 13.6.3)`, but `gma_mediation_applovin 2.5.2` → `GoogleMobileAdsMediationAppLovin (~> 13.5.0.0)` → `AppLovinSDK (= 13.5.0)`. Both pinned exact versions, so `pod install` could not resolve them together in a consuming app pinned to `gma_mediation_applovin 2.5.2` unless it also held `applovin_max` back to `4.6.0`.
- Verify any change here against a real consuming app with `flutter pub get` **and** `cd ios && pod install` **and** a real `flutter build apk` / `flutter build ios --simulator`: `pub get` succeeding proves nothing about the pod graph, and `pod install` succeeding proves nothing about whether it actually compiles (see the `9.1.0` regression above — the pod graph resolved fine, the Xcode build didn't).

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

## Resolved security debt — repo git history (was: pending)

**`android/app/private_key.pepk`** (a Play App Signing key export, leftover
from when the host app lived in this repo) was committed at `60a1f3d`
(2024-12-20). Resolved 2026-09-21: Play Console confirmed this key was
**never used to sign a published app** (no rotation needed), so the 4 remote
branches that still had it reachable in their history
(`audit-round9-n1-n6-f7`, `release20260322`, `release20260616`,
`release20260814` — `main` itself never had it as an ancestor) were deleted
from `origin` outright rather than rewritten with `git filter-repo`/BFG —
simpler and sufficient once rotation wasn't a prerequisite. Verified after
deletion: `git branch -r --contains 60a1f3d` returns nothing across every
remaining branch. (`keystore.jks`, the separate Android signing-key leak
purged 2026-09-20, was independently re-verified clean across all branches
in the same pass.)

Residual, accepted: GitHub may keep the now-unreachable commit objects
reachable by exact SHA for a while until internal GC runs; low risk given
the key was confirmed never live. If this ever needs to be fully scrubbed
from GitHub's side too, that requires a GitHub support request, not
anything doable from this repo alone.
