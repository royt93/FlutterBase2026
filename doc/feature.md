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

- (none — Wave 2 complete; Wave 3 not started)

## ✅ Implemented — Wave 2 (measurement + export) · DONE 2026-06-16

> Started + completed 2026-06-16. New files: `services/latency_service.dart`,
> `models/network_quality.dart`, `test/wave2_{latency,quality,export}_test.dart`.
> Touched: `models/test_result(_adapter).dart`, `stressor_controller.dart`,
> `controllers/history_controller.dart`, `widgets/control_panel_widget.dart`,
> `presentation/{test_detail,comparison}_screen.dart`, translations, `pubspec.yaml`
> (`pdf`).

### D. Ping/Latency + Jitter realtime — `done`
- [x] D1 `LatencyService`: HTTP GET round-trip probe (Cloudflare trace), ms; null
      on failure. Pure static `jitter`/`average`. — `done`
- [x] D2 Controller: `latencyMs`/`jitterMs`/`latencyHistory` Rx + 2s probe Timer
      during a run (cancelled in stop/cleanup, service closed); jitter = mean |Δ|.
      — `done`
- [x] D3 Model+adapter: `TestResult.avgLatencyMs`/`jitterMs` (fields 12/13,
      backward-safe null read) + `fromControllerData`/`copyWith`/`toJson`/`fromJson`
      + `latencyFormatted`/`jitterFormatted`. — `done`
- [x] D4 UI: latency + jitter metric tiles (running panel) + detail screen rows.
      — `done`
- [x] D5 i18n vi/en (`latency`,`jitter`) + tests `test/wave2_latency_test.dart`
      (8: jitter/average math + model round-trip/format/backward-compat). — `done`
> Note: latency is measured *under load* (during the download stress) → reflects
> bufferbloat, intentionally. Probe runs in parallel with downloads.

### E. Network Quality Score A–F — `done`
- [x] `NetworkQuality.compute` (pure): speed 50pts + latency 30pts + jitter 20pts
      → 0-100 score → grade A/B/C/D/F + colour. Null latency → speed-only on a
      100 scale. — `done`
- [x] UI: grade badge on the test-detail performance card (white pill, coloured
      letter + score) + a coloured grade row in the comparison table (+ latency/
      jitter rows). — `done`
- [x] i18n `quality_score` + tests `test/wave2_quality_test.dart` (6: tiers,
      boundaries, null-latency, caps). — `done`

### F. Export CSV / JSON / PDF — `done`
- [x] `exportData` now opens a dark bottom-sheet format picker (CSV/JSON/PDF) →
      `_exportAs(fmt)` writes temp file + shares (share_plus). — `done`
- [x] CSV: added Latency/Jitter/Quality columns. JSON: indented array of
      `TestResult.toJson` (incl. latency). PDF: `pdf: ^3.12.0` — A4 MultiPage
      table (#, time, avg, peak, latency, jitter, grade, status). — `done`
- [x] Generators made `@visibleForTesting` (`generateCsv`/`generateJson`/
      `generatePdf`); i18n `export_choose_format`; tests
      `test/wave2_export_test.dart` (3: CSV headers/rows, JSON parse+round-trip,
      PDF %PDF magic). — `done`

> **Wave 2 COMPLETE (2026-06-16).** Latency+jitter, A–F quality score, 3-format
> export. `flutter analyze` clean, APK builds.

#### Wave 2 tests + bug fixes (2026-06-16)
- Added **widget + integration tests**: `test/wave2_widget_test.dart` (latency/
  jitter tiles, detail quality badge, export bottom-sheet) +
  `test/wave2_integration_test.dart` (select 2 → comparison shows latency + A–F
  grades end-to-end). **40/40 host tests green.**
- 🐛 **Fixed custom-duration dialog crash** (`_dependents.isEmpty` assertion): the
  dialog disposed its `TextEditingController` in a `.then()` while the `TextField`
  was still mounted. Rewrote as a `_CustomDurationDialog` StatefulWidget that
  disposes in `State.dispose()`. Regression test added in `wave1_widget_test.dart`
  (open→fill→OK→`pumpAndSettle`). Verified on S24 Ultra: 45s entered → no crash →
  `45s` chip selected.
- 🐛 **Fixed pre-existing detail-screen overflow** (233px): `SpeedChart` was forced
  into `SizedBox(height:200)` but needed ~420px → added `chartHeight` param
  (detail uses 180).
- 🐛 Added missing i18n key `ok` (the OK button rendered as lowercase "ok").
- **On-device (S24 Ultra):** latency `268 ms` + jitter `362 ms` tiles live during
  a run (high = under-load bufferbloat, by design), gauge hero animates, auto-stop
  fires, custom dialog no longer crashes. No `_dependents`/assertion/FlutterError
  in logcat (only expected per-loop DioException on cancel).

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

### Wave 1 UI polish — dark theme unify (2026-06-16) · `done`
> The WiFi main screen used a light cream `Card` (app theme is `ThemeData.light`)
> floating over the dark space background, clashing with the dark-slate History/
> Comparison screens. Unified everything to the dark design system
> (bg #0F172A · card #1E293B · accent #3B82F6).
- Control panel: cream `Card` → dark `Container` (#1E293B, subtle border), white
  text, dark dropdown (`dropdownColor`).
- Duration chips: default Material `ChoiceChip` → custom dark chips — selected =
  solid blue accent + white, unselected = #0F172A + white70, animated.
- Speedometer gauge: now the **hero** when running (size 260, top, replaces the
  idle status circle); removed the redundant "Tốc độ hiện tại" metric row; fixed
  the "Mbps" label colour (was black → white70); gauge `size` param added.
- `MetricTileWidget`: white/white70 text on dark; green metric icons kept.
- `SpeedChart` (live) + `collecting_data`: cream `Card` → dark, readable text.
- Comparison + History charts: softened the harsh black `FlBorderData` to
  white-12%; comparison legend squares rounded.
- Verified on device (S24 Ultra): cohesive dark control panel + accent chips +
  gauge hero. `flutter analyze` clean, `flutter test` 12/12 Wave 1 still green.

#### UI refinements (user feedback, 2026-06-16)
- Connection-count picker: bare underlined `DropdownButton` → rounded pill
  (#0F172A, 12px corners, subtle border, `borderRadius` on the popup too).
- Speedometer gauge value overlap fixed: redesigned from a 270° dial (value
  Stacked over the hub/needle/background art) to a **180° semicircle with the
  value number in a `Column` directly below the arc** — number can no longer
  overlap the needle/arc/background. Verified on device.
- Gauge smooth animation: `TweenAnimationBuilder` (450ms easeOutCubic) interpolates
  needle/arc/number/colour between value changes (no more jumps on each 500ms
  controller tick). `begin: null` → first build shows target instantly (tests stay
  green).

## 📋 Picked — awaiting implementation

> Chosen 2026-06-15. Apply the coding rules at the top of this file to each.

### 🔬 Wave 3 — native measurement
- **Signal strength dBm (real)** — replace the `null` with a platform channel
  (Android `WifiManager.getRssi`, iOS equivalent); surface in Network Info.
- **DNS resolution + Packet loss** — DNS response time + packet-loss ratio; needs
  a dedicated package. Most complex.

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
