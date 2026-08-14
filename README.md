# applovin_admob_sdk

Source repo for **`applovin_admob_sdk`** — a dual-provider ad SDK (AppLovin MAX +
Google AdMob) for Flutter, Android + iOS. Published to pub.dev.

**Integrating this into your app?** Read
**[`packages/ad_sdk/README.md`](packages/ad_sdk/README.md)** — the full,
current integration contract.

Host apps that consume this SDK live in their own separate repos, depending on
the published `applovin_admob_sdk` package from pub.dev — not on this repo
directly.

## Repository layout

| Path | What it is |
|---|---|
| `packages/ad_sdk/` | The `applovin_admob_sdk` package — SDK source, its own README/CHANGELOG/MIGRATION, example app, ~699 tests. |
| `doc/` | Project docs — see `doc/audit/` for the numbered audit rounds (12+ so far; read the latest before re-litigating an SDK design decision). |
| `.github/workflows/test.yml` | CI: `sdk` (analyze + unit/widget tests), `sdk-integration` (Android emulator), `sdk-integration-ios` (iOS Simulator, 3-way sharded). |

## Quick start

```bash
cd packages/ad_sdk
flutter pub get
flutter analyze
flutter test                              # unit/widget suite

cd example
flutter test integration_test/            # on-device suite, needs emulator/simulator
```

## Publishing

See `CLAUDE.md` for the pub.dev publishing gotchas (screenshot description
length limits, CDN cache lag) and the CocoaPods/Dart version-pinning
constraints around `gma_mediation_applovin` / `applovin_max`.
