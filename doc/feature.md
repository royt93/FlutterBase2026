# Feature Status

Updated: 2026-06-15

> **Single source of truth** for feature decisions. Two tracks:
> **🛜 Product** (the WiFi stress-tester itself) and **📣 Ad/SDK**
> (`applovin_admob_sdk` + VIP integration).
>
> **Coding rules for every Picked item** (from `doc/init.md` + `doc/TODO.md`):
> no `print`/`debugPrint` → use `SafeLogger`; no `Get.snack` → use `AppSnackbar`
> / `UIUtils.showToast`; no `late` → nullable + init; no `setState` → GetX
> `Rx`/`Obx`; no force-null `!`; no memory leak; **full vi + en i18n** for every
> new user-facing string.

---

## ✅ Implemented

### 🛜 Product — WiFi stress tester
- Core flow: parallel Dio download stress test, configurable parallel
  connections (default 50), realtime Mbps + total bytes + duration, live speed
  line chart. Per-URL failure tracking + retry backoff.
- History (Hive, capped at 100 via `TestHistoryStorage`): summary stats card,
  line chart, timeline list.
- Test detail screen: avg / peak / min / median speed, network info,
  speed-over-time chart.
- Network info: SSID, IP, estimated frequency.
  ⚠️ `signalStrength` is currently `null` (Flutter can't read RSSI without a
  platform channel) → see Picked **"Signal strength dBm"**.
- Endpoint set: Linode / Vultr / OVH / free.fr / ThinkBroadband (the 5 dead
  DigitalOcean speedtest endpoints were removed).

### 📣 Ad / SDK — `applovin_admob_sdk ^1.0.23`
- Android + iOS ad integration, runtime provider `AdProvider.appLovin`
  (AdMob kept present for swap-readiness). Hosted `^1.0.23` from pub.dev (local
  `path: packages/ad_sdk` override commented out).
- Platform-specific AppLovin ad unit config — `AdKey.appLovin` selects Android
  vs iOS units at runtime; Android and iOS never share unit IDs.
- iOS native config in `ios/Runner/Info.plist`: `GADApplicationIdentifier`,
  `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems`.
- iOS ATT flow in the SDK (`AdManager().requestAtt()`), called in splash before
  UMP. Verified on Roy's Phone 2026-06-14 (`authorized` + IDFA present).
- **VIP time global stacking** — every grant (redeem code OR watch-ad) adds onto
  the latest expiry across ALL active entries (e.g. ~6 days + 30-day code ⇒ ~36
  days). `stack` flag on `VipManager.addVip` / `redeemVip` (default `false`).
  - Redeem code: `vip_screen.dart` → `redeemVip(..., stack: true)`.
  - Watch-ad +3d: fixed key `REWARDED_VIP` + `addVip(stack: true)` (consolidates
    into one entry). CTA stays visible while VIP via `bypassVipGuard: true`
    (real rewarded, no auto-grant; SDK loads slot on demand).
  - Anti-abuse: total window capped at **90 days** via
    `AdConfig.maxVipStackDuration` (set in `splash_screen.dart`) + fullscreen
    safety caps. `showRewardedAd` is re-entrancy-safe (`onDemandLoadTimeout` 15s).
  - Tests: SDK `vip_manager_stacking_test.dart` (8) + `rewarded VIP-bypass` (5);
    host `test/vip_screen_widget_test.dart` (5 widget + 1 integration).
- **Native build pin (historical):** app ships `google_mobile_ads 6.0.0` +
  `gma_mediation_applovin 2.5.1` + `applovin_max 4.6.0` via `dependency_overrides`
  (SDK 1.0.23 declares GMA ^7 but the hosted Dart is GMA-6-compatible). The
  `path` override dragged GMA 7 in and broke the native registrant — keep the pins.

### 🔬 On-device verification — Samsung S24 Ultra, Android 16 (2026-06-15)
> Replaces the prior "not yet verified on a real device" note. **Full ad + VIP
> lifecycle verified live** (debug build, AppLovin test ads):
- Cold start → App Open ad (`loadAppOpenAd → showAdBuffer →
  showAppOpenAd(bypassSafety:true)` → dismiss → Main). Hard-cap 8s + hot-restart
  guard OK.
- Banner on Main + History; interstitial fires **only** on History navigation;
  rewarded fires on "Export data".
- App-open-on-resume correctly **skipped** while interstitial/rewarded showing
  (modal guard).
- VIP: redeem key (30d) → gold hero + live countdown + success dialog; VIP
  **suppresses all 3 ad surfaces** (banner gone, interstitial skipped, crown
  turns gold); revoke → reverts (ads return, crown white). Key masked `9FA****`.
- **Zero** crash / ANR / `E/flutter` across the session.

### 🔐 Session 2026-06-15 — security + policy hardening
- **Keystore credentials** moved out of `android/app/build.gradle` into
  `android/key.properties` (loaded by gradle) + `key.properties.example`
  template. `key.properties` is intentionally **tracked** (private repo, user
  decision); `build.gradle` no longer holds plaintext passwords.
- **Interstitial policy:** removed from the Stop button — interstitials now fire
  **only on a real screen transition** (opening History). Start was already clean.
- **Code-style cleanup** (wifi_stressor module): 2× `late final` → nullable /
  field-initializer, 3× bang `!` → null-safe pattern, History banner wrapped in
  `SafeArea`. `flutter analyze` = No issues found.

## 🟡 In progress

- (none — Wave 1 complete; Wave 2 not started)

## ✅ Implemented — Wave 1 (Quick wins) · DONE 2026-06-16

> Started 2026-06-15, completed 2026-06-16. Pure Dart/Flutter on existing data —
> no new native code or heavy packages. Files: `widgets/control_panel_widget.dart`,
> `widgets/speedometer_gauge_widget.dart` (new), `presentation/comparison_screen.dart`
> (new), `controllers/history_controller.dart`, `widgets/timeline_item.dart`,
> `presentation/history_screen.dart`, `stressor_controller.dart`, translations,
> `test/wave1_{unit,widget,integration}_test.dart` (new).

### A. Test duration presets — `done`
- [x] A1 Controller: `Rx<int?> selectedDurationSec` + preset list + auto-stop in
      `_updateTotalSpeed` (re-entrancy guarded). — `done`
- [x] A2 UI: ChoiceChip preset selector (Unlimited/15s/30s/1m/5m) + custom dialog
      (local `TextEditingController` disposed, digits-only). running_time tile now
      shows `elapsed / total` when a preset is set. — `done`
- [x] A3 i18n: vi + en keys (`duration_label`, `duration_unlimited`,
      `duration_custom`, `duration_custom_title`, `duration_custom_hint`). — `done`
- [x] A4 `flutter analyze` = No issues found. — `done`

### B. Speedometer gauge realtime — `done`
- [x] B1 `SpeedometerGaugeWidget` (CustomPainter) reactive to `speedMbps` via
      `Obx`; auto-scale max (50/100/200/500/1000/2000), colour by quality. — `done`
- [x] B2 Integrated into running view above the line chart. — `done`
- [x] B3 `flutter analyze` = No issues found. — `done`

### C. Comparison view — `done`
- [x] C1 History: multi-select mode (`selectionMode`/`selectedIds`/`selectedResults`
      in controller; compare toggle in AppBar; check indicator on `TimelineItem`;
      bottom compare bar enabled at ≥2). — `done`
- [x] C2 `ComparisonScreen`: colour legend + overlaid speed-over-time LineChart +
      metrics table with best-value highlight. — `done`
- [x] C3 i18n vi + en (`comparison_title`, `compare_*`, `cmp_*`). — `done`
- [x] C4 `flutter analyze` = No issues found. Also fixed 3 pre-existing force-null
      `!` in `history_controller`/`test_detail_screen` while here. — `done`

### T. Tests (unit + widget + integration) — `done`
> Host tests in repo-root `test/` (`flutter test`). 18/18 pass (12 new + 6 VIP).
- [x] T1 Unit `test/wave1_unit_test.dart`: gauge `niceMax`/`speedColor`,
      `StressorController.shouldAutoStop` + `selectedDurationSec`, HistoryController
      selection (`toggleSelectionMode`/`toggleSelect`/`selectedResults`). — `done`
- [x] T2 Widget `test/wave1_widget_test.dart`: duration chips render + tap updates
      controller + hidden while running, gauge renders value + CustomPaint,
      comparison screen metric rows + LineChart. — `done`
- [x] T3 Integration `test/wave1_integration_test.dart`: select 2 of 3 tests →
      `selectedResults` → ComparisonScreen renders both, excludes the third. — `done`
- [x] Refactor for testability: `shouldAutoStop` (`@visibleForTesting`), gauge
      `niceMax`/`speedColor` made static-public. — `done`

### Wave 1 exit — `done`
- [x] `flutter analyze` clean (lib + test). — `done`
- [x] `flutter test` green (18/18). — `done`
- [x] `flutter build apk --debug`. — `done`
- [x] On-device smoke — Pixel 7 Pro + S24 Ultra (Android 16). — `done`
  - A: chips render, select 15s, `0:03 / 0:15` elapsed/total, **auto-stop**
    (`⏱️ Duration preset 15s reached → auto-stop` → `Test result saved`). ✅
  - B: speedometer gauge realtime on device (needle + colour band: 75→amber,
    26→red). ✅
  - C: selection mode (compare icon → X, entry check + blue border, bottom bar
    `Đã chọn N`, compare disabled at <2), then **ComparisonScreen verified with 2
    real entries** — colour legend (#1 blue / #2 green), overlaid speed-over-time
    chart (2 lines), metrics table with best-value highlight (avg/peak/min/median
    + duration + downloaded). ✅
  - first-install grace 30s + interstitial-only-on-History confirmed in log. ✅

> **Wave 1 COMPLETE (2026-06-16).** All three features coded, tested (18/18),
> analyzed clean, built, and verified end-to-end on real devices.

## 📋 Picked — awaiting implementation

> Chosen 2026-06-15. Apply the coding rules at the top of this file to each.

### 🔬 Core measurement (Wave 2–3)
- **Ping/Latency + Jitter realtime** — measure round-trip latency + jitter during
  a test (HTTP round-trip / ICMP), show live, persist into `TestResult`. Highest
  gap for a network tester.
- **Network Quality Score A–F** — combine speed + latency + jitter (+ packet loss
  if available) into a colour-coded grade. Reuse the existing `speedQuality`.
- **Signal strength dBm (real)** — replace the `null` with a platform channel
  (Android `WifiManager.getRssi`, iOS equivalent); surface in Network Info.
- **DNS resolution + Packet loss** — DNS response time + packet-loss ratio; needs
  a dedicated package. Most complex of the four.

### 📈 UX / visualization (Wave 2)
- **Export upgrade CSV / JSON / PDF** — extend the current `exportData`; pretty
  reports + share. Keep the existing rewarded-ad gate.

## 🚧 Blockers — config, not code

- **UMP consent form NOT configured** for AdMob app ID
  `ca-app-pub-3612191981543807~9731053733`. Device log:
  `requestConsentInfoUpdate failed: ... no form(s) configured`. SDK degrades
  gracefully (`canRequestAds=true`) but EU/EEA/UK users never see a consent form.
  Configure + **publish** a UMP message in the AdMob dashboard before an EEA
  release. Full steps in `doc/UMP_SETUP.md`.

## ⏸️ Deferred

- Recheck official AppLovin MAX iOS SKAdNetwork requirements before App Store
  release (mediation partners may require extra identifiers).

## ❌ Skipped

- Old verification/performance/package-plan reports in `doc/` were removed
  (described historical states, could mislead current debugging).

## 🐛 Fixed

- **iOS App Open watchdog false-positive** (SDK 1.0.19): the "foreground = hung
  ad" heuristic is Android-only now; on iOS the ad shows while the app stays
  `resumed`, so it no longer force-dismisses at 10s. Verified on iPhone 17 sim
  2026-06-14.

### Audit fixes (SDK 1.0.19, 2026-06-14) — all SDK tests pass, analyze clean
Correctness:
- AppLovin reload-after-display-fail no longer stranded by backoff
  (`AdSlot.beginReload()` bypasses cooldown for show-failure refills; genuine
  load failures still throttle).
- AdMob `bannerSlot.beginReload()` now runs BEFORE `BannerAd(..)..load()`.
- AdMob App Open 90s hard-cap watchdog (parity with AppLovin).
- AdMob interstitial/rewarded expire after 1h (no stale cached ad on show).
- AdMob `onAppResumed` banner reload uses `implicitView` (foldable/split-view).

Policy:
- Interstitial removed from "Start test" (interruptive); kept on Stop +
  navigation. *(Stop later removed too — see Session 2026-06-15.)*
- VIP granted ONLY on a real rewarded `earned==true` (no interstitial-as-reward).
- Release footgun guards in `AdManager.initialize` (dryRun-in-release, AdMob
  TEST unit IDs).

## 💭 Ideas

> Unstructured pool — promote to Picked with a clear scope before implementing.

### 🛜 Product
- Upload vs Download speed (currently download-only).
- Real-time alerts: speed drop below threshold, test-complete notification, push
  on connection failure.
- Network Information dashboard: gateway/DNS info, connected-devices count,
  router manufacturer/model, public IP.
- Benchmarking / leaderboard: compare against ISP advertised speeds; fastest
  networks list.
- Multiple servers selection + auto-test scheduling (daily/weekly).
- Custom test params (packet size, interval, timeout), data-usage limits.
- Heatmap of performance over time; bar/area chart types; success-vs-failed pie.
- Light/dark theme toggle (app is currently dark-only by design).
- Localization completeness audit (TODO calls for "multi language đầy đủ").

### 📣 Ad / SDK
- In-app debug entry to launch AppLovin/AdMob ad inspectors.
- Ad health screen: SDK init state, loaded slots, consent state, VIP state, last
  load error.
