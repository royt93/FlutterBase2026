# Feature Status

Updated: 2026-06-16

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
- Network info: SSID, IP, estimated frequency, **signal dBm** (Wave 3 native
  channel), latency/jitter/DNS/packet-loss (Wave 2–3).
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
- **VIP grace-period expiry nudge (2026-07-09).** `VipManager` gains
  `graceNudgeThreshold` (default 24h) + `graceNudgeDueListenable` +
  `acknowledgeGraceNudge()`, folded into the existing `_scheduleNextExpiry`/
  `_handleExpiry` timer (no second timer). Ack is keyed on
  `expiresAt.millisecondsSinceEpoch` via `AdPreferences`, so a new
  stack/redeem automatically makes the nudge due again. Host wires it in
  `wifi_stressor_screen.dart` (`SnackBar` + navigate-to-`VipScreen` action);
  SDK example `VipDemoPage` shows the same listenable. Tests:
  `vip_manager_grace_nudge_test.dart` (5). Verified on Samsung SM-A507FN
  (debug build) — no crash, correctly hidden when remaining time is above
  threshold.
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

- (none — Wave 5 complete)

## ✅ Implemented — Wave 5 (network dashboard + chart types) · DONE 2026-06-16

> Picked 2026-06-16 (Network Info dashboard + Chart types & visualization), built
> same day. New files: `models/network_dashboard.dart`,
> `controllers/network_dashboard_controller.dart`,
> `presentation/network_dashboard_screen.dart`, `widgets/loss_pie_widget.dart`,
> `test/wave5_{unit,widget}_test.dart`. Touched: `MainActivity.kt`
> (getNetworkDetails), `services/network_info_service.dart`, `speed_chart.dart`,
> `presentation/test_detail_screen.dart`, `wifi_stressor_screen.dart` (router
> AppBar icon), translations. Also polished `common/v/pulse_container.dart`
> (`late`→nullable).

### I. Network Info dashboard — `done`
- [x] Native `getNetworkDetails` (MainActivity.kt): gateway IP + DNS1/DNS2 + BSSID
      via `DhcpInfo` + `WifiInfo.bssid`; int→dotted IPv4; placeholder MAC
      `02:00:00:00:00:00` (no location perm) → null.
- [x] `NetworkInfoService`: `getNetworkDashboard()` gathers base info + native
      gateway/dns/bssid + **public IP** (Dio GET ipify, 5s timeout, null on fail)
      + link speed. Pure helpers `isLikelyIpv4` / `dnsListOf` `@visibleForTesting`.
- [x] `NetworkDashboard` model (live, **not** Hive-persisted → no adapter/schema
      migration). `NetworkDashboardController` (GetX Rx, refresh guard).
- [x] `NetworkDashboardScreen`: Connection / Addresses / DNS cards + per-row
      copy-to-clipboard + refresh button. Entry = `Icons.router` on main AppBar
      (no interstitial — info screen).
- [x] i18n vi/en (`net_*`). Tests in `wave5_unit_test.dart`.

### J. Chart types & visualization — `done`
- [x] `SpeedChart` now StatefulWidget with line / area / bar toggle (state via
      `ValueNotifier`, **no setState**). Bar chart downsamples to `maxBars=48`
      buckets (`downsample` `@visibleForTesting`). Live running chart passes
      `showTypeToggle:false` (keeps data-points counter).
- [x] `LossPieWidget` — success-vs-loss pie (fl_chart `PieChart`) from
      `packetLossPct`; rendered in `test_detail` only when not null. Pure
      `successOf` `@visibleForTesting`.
- [x] i18n vi/en (`packet_pie_title`, `packet_success`). Tests in
      `wave5_widget_test.dart` (toggle line→bar, hidden toggle, pie + legends).

> **Wave 5 COMPLETE (2026-06-16).** 72/72 host tests green, ad_sdk 225/225,
> `flutter analyze` clean (host + ad_sdk), APK builds with the native channel.
> i18n 184/184 parity.
> **Deferred from this pick:** heatmap (performance over time) — needs a
> history×time matrix + a custom painter; larger than this session.

#### Wave 5 on-device verification + post-review polish (S24 Ultra, 2026-06-16)
- **Verified live on Samsung S24 Ultra (Android 16):** Network Dashboard resolved
  gateway `192.168.92.1`, DNS, BSSID `a2:05:...`, public IP `118.69.32.232`,
  signal/freq/channel/link-speed (458 Mbps) — all native data correct. Chart
  toggle line/area/bar + success-vs-loss pie (100%) render + switch smoothly.
  Interstitial-only-on-History confirmed. **Zero** app crash/ANR/`E/flutter`
  across the session (only system `serviceDiscovery`/`NearbySharing` noise).
- **3 review nits fixed + re-verified on device:**
  1. **Public IP fallback** — `getPublicIp` now iterates `publicIpProviders`
     (ipify → ifconfig.me → icanhazip), first valid IPv4 wins (was single
     provider → silent N/A if blocked).
  2. **Parallel fetch** — `getNetworkDashboard` starts connectionType / base /
     wifi / details / publicIp as concurrent hot futures (public IP's ≤5s no
     longer serializes behind the fast native calls).
  3. **Signal-quality i18n unified** — `TestResult.signalQuality` now returns
     lowercase tier keys (`excellent`/`good`/`fair`/`poor`) like
     `NetworkDashboard`; test-detail row translates via `signal_<tier>` (device
     shows "-33 dBm (Xuất sắc)", was untranslated "(Excellent)"); share text
     uses `capitalizeFirst` to stay an English report.
  - Tests: +2 in `wave5_unit_test.dart` (TestResult tier keys, publicIpProviders
    shape). `DhcpInfo` kept (deprecated but reliable) — noted for a future move
    to `ConnectivityManager.getLinkProperties`.

#### Wave 5 spec-audit round (2026-06-16) — closed the deferred sub-items
> Audit vs the chosen option text surfaced 2 named-but-undelivered sub-items
> (router vendor OUI, heatmap) + 3 minor issues. All addressed + re-verified on
> S24 Ultra. **79/79 host tests, analyze clean, i18n 192/192.**
- **Router vendor (OUI)** — `NetworkInfoService.vendorOf(bssid)` + `ouiVendors`
  map (~40 common router/AP makers). Guards **locally-administered/randomized
  MAC** (0x02 bit) → null (real-world routers often randomize, incl. the test
  device — vendor row then hidden by design). `NetworkDashboard.vendor` + "Hãng"
  row (only when non-null). Tests: 4 (known/randomized/unknown/malformed).
- **Heatmap** (`presentation/heatmap_screen.dart`) — each test = a 24-cell strip
  (reuses `SpeedChart.downsample`, now a plain public util) coloured red→amber→
  green by speed vs global peak; legend + per-row time/avg label. Entry = grid
  icon on History AppBar. `heatmapColor` `@visibleForTesting` (3 tests). i18n
  `heatmap_*`. On device: 3 rows render, startup-ramp amber → sustained green.
- **3 nits fixed:** (a) parallel reorder so BSSID isn't fetched before location
  permission resolves (await base first; publicIp still overlapped); (b)
  `connectionType` localized (`net_type_wifi/mobile/ethernet/unknown` — device
  shows "WiFi"); (c) `getPublicIp` closes its Dio in `finally`.
- **Still deferred:** connected-devices count (needs ARP scan, unreliable);
  OUI DB is a starter list (extend as needed).

## ✅ Implemented — Polish + Wave 4 · DONE 2026-06-16

> New: `services/upload_speed_service.dart`, `presentation/ad_health_screen.dart`,
> `test/wave4_*` (upload/alerts/ad_health). Touched: model+adapter (uploadMbps),
> stressor_controller (upload probe + alerts), control_panel (upload tile + alert
> chips), test_detail/comparison/history_controller (upload col), MainActivity.kt
> (getWifiInfo), network_info_service (band/channel), translations.

### P. Polish — `done`
- [x] P1 De-nested the test-detail speed chart (was card-inside-card + 2 headers);
      now `SpeedChart` stands alone (single card/header). — `done`
- [x] P2 Native `getWifiInfo` (rssi + frequency MHz + link speed); Dart
      `bandOf`/`channelOf` derive real `NetworkInfo.frequency` (2.4/5/6 GHz) +
      `channel`. Tests added (band/channel/map). — `done`

### Wave 4 (picked)
- [x] **Upload speed test** — `done`. `UploadSpeedService` (POST 1MB to Cloudflare
      `__up`, throughput) probed every 5s under load; `TestResult.uploadMbps`
      (adapter field 16) + running tile + detail row + comparison row + CSV col +
      i18n `upload_speed`. Tests `test/wave4_upload_test.dart`.
- [x] **Real-time alerts** — `done`. Threshold chips (Off/5/10/20/50 Mbps) in the
      control panel; low-speed toast fires once when avg drops below (after 5s,
      resets on recovery); test-complete toast on stop/auto-stop. In-app toasts
      (toastification) — no OS-notification plugin needed. `shouldAlertLowSpeed`
      `@visibleForTesting`. Tests `test/wave4_alerts_test.dart`.
- [x] **Ad-health / debug screen** — built then **REMOVED per user (2026-06-16)**:
      verified working on device (SDK/slots/VIP/consent live), but it's a
      dev/debug tool — exposing it on the production AppBar is clutter + leaks
      internal ad state to end-users. Screen + icon + test + i18n all removed.
      (If needed later, re-add gated behind `kDebugMode`.)

> **Polish + Wave 4 COMPLETE (2026-06-16).** Upload speed + alerts + polish
> shipped; ad-health built+verified then removed as a debug-only tool. analyze
> clean, APK builds.

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

## ✅ Implemented — Wave 3 (native measurement) · DONE 2026-06-16

> New: `MainActivity.kt` MethodChannel, `test/wave3_{signal,dns_loss}_test.dart`.
> Touched: `latency_service.dart` (DNS), `network_info_service.dart` (RSSI channel),
> `stressor_controller.dart`, `models/test_result(_adapter).dart`,
> `presentation/{test_detail,comparison}_screen.dart`, `controllers/history_controller.dart`
> (CSV cols), translations.

### G. Signal strength dBm (native) — `done`
- [x] `MainActivity.kt`: MethodChannel `com.saigonphantomlabs.base/wifi` →
      `getRssi` returns `WifiManager.connectionInfo.rssi` (null if ≥0 / error).
- [x] `NetworkInfoService.getSignalStrength()` (`@visibleForTesting`) invokes it;
      iOS has no handler → caught → null. Wired into `getCurrentNetworkInfo`
      (was hard-coded `null`). Detail Network-Info row already renders it.
- [x] Tests `test/wave3_signal_test.dart` (4, channel-mocked: negative kept,
      0/positive→null, null→null, PlatformException→null). APK builds (Kotlin OK).

### H. DNS resolution + Packet loss — `done`
- [x] `LatencyService.dnsLookup()` (timed `InternetAddress.lookup`, null on fail).
- [x] Controller: `dnsMs`/`packetLossPct`/`dnsHistory` + probe-attempt/failure
      counters; packet-loss = failed/total probes %, DNS = avg. Persisted to
      `TestResult.dnsMs`/`packetLossPct` (adapter fields 14/15, backward-safe).
- [x] UI: detail rows + comparison rows + CSV columns; i18n `dns_time`,
      `packet_loss`. Tests `test/wave3_dns_loss_test.dart` (7).

> **Wave 3 COMPLETE (2026-06-16).** 49/49 host tests green, analyze clean, APK
> builds with the native channel.

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
- Recheck native ad SDK majors (AppLovinSDK / Google Mobile Ads) each quarter —
  confirm whether the CocoaPods/Dart version pins in `dependency_overrides`
  (root `pubspec.yaml`) can be relaxed now that upstream has moved. Retested
  2026-07-10: still blocked (`gma_mediation_applovin >=2.6.0` needs
  `meta ^1.17.0`, Flutter SDK 3.35.1's `flutter_test` pins `meta 1.16.0`). See
  `doc/audit/audit_partner_lead_20260710.md` finding #2/#3.

## ❌ Skipped

- Old verification/performance/package-plan reports in `doc/` were removed
  (described historical states, could mislead current debugging).

## 🐛 Fixed

- **Splash hard-cap race làm mất `AdManager().initialize()` vĩnh viễn** (2026-07-10):
  timer hard-cap 8s ở splash race với chuỗi ATT→UMP consent async. Guard cũ
  (`if (!mounted) return;` ở `packages/ad_sdk/example/lib/main.dart`, `if (!mounted
  || _hasNavigated) return;` ở `lib/mckimquyen/widget/splash/splash_screen.dart`)
  skip luôn `AdManager().initialize()` nếu hard-cap bắn trước khi user tap xong
  form GDPR — mất toàn bộ ad surface (banner/interstitial/rewarded) cho cả phiên
  app. Fix: bỏ guard mounted/`_hasNavigated` trước `initialize()` ở cả 2 file (gọi
  hàm này không cần `BuildContext`). Verify on-device qua example app (iOS sim):
  log xác nhận `initialize()` chạy lúc 00:14:28 dù hard-cap đã bắn lúc 00:11:01;
  cả 4 ad surface (banner/interstitial/rewarded/App Open) đều load + show
  creative thật (test mode) sau fix — App Open confirm show qua screenshot
  2026-07-11 (`showAppOpen [AdMob] ✅ shown`). Tracked as `doc/task/done/T29-splash-init-race-condition.md`.

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
- Benchmarking / leaderboard: compare against ISP advertised speeds; fastest
  networks list.
- Multiple servers selection + auto-test scheduling (daily/weekly).
- Custom test params (packet size, interval, timeout), data-usage limits.
- Heatmap of performance over time (deferred from Wave 5 — needs history×time
  matrix + custom painter).
- Network dashboard extras: connected-devices count, router manufacturer/model
  (OUI lookup) — deferred (BSSID shown in Wave 5, vendor DB is heavy).
- Light/dark theme toggle (app is currently dark-only by design).

> Done: Upload vs Download (Wave 4) · Real-time alerts (Wave 4) · Network Info
> dashboard public-IP/gateway/DNS/BSSID (Wave 5) · bar/area chart types +
> success-vs-loss pie (Wave 5) · localization completeness audit (i18n 184/184
> parity verified 2026-06-16).

#### New ideas (2026-07-07 differentiation pass)
- **Walk-test room-tagging mode.** Quick-succession tests (e.g. 5s each) with a
  lightweight room/location label prompt between runs, then a bar-chart summary
  ("Living room: 180 Mbps avg · Bedroom: 22 Mbps avg — 88% drop") so users can
  pinpoint dead zones without leaving the app. Differentiating because it's a
  *diagnostic workflow* generic speed-test apps don't offer — they test once and
  stop; a stress tester already has the rapid-fire test loop this needs. Needs
  one new nullable `roomTag` field on `TestResult`/Hive adapter (next free index
  17) + a small tag-picker sheet reusing the existing history list UI. Effort: M
  (~1 day) — no new native code, no new screen architecture, just a tag field +
  a grouped-bar aggregation view.
- **ISP-dispute evidence export.** A dedicated PDF report mode (reusing the
  existing `pdf`-based export pipeline from Wave 2) that aggregates N historical
  tests over a date range against the user's stated ISP-advertised plan speed,
  computing "% of tests below promised speed," worst/median/best, and a
  timestamped table — framed explicitly as evidence to hand to an ISP or
  regulator, not just a personal chart. Differentiating because "prove my ISP
  is underdelivering over time" is a use case a stress tester's persistent
  history uniquely supports and no bundled speed-test app frames this way.
  Effort: S–M (~4-6h) — reuses `generatePdf`/history storage, just needs a new
  report template + one plan-speed input field.
- **Sustained-load thermal/throttle detector.** During long-duration stress
  runs (5m+ preset already exists), poll Android's
  `PowerManager.getCurrentThermalStatus()` (API 29+, currently never wired to
  the `com.saigonphantomlabs.base/wifi` channel) alongside speed samples, and
  flag "throughput dropped after N minutes — possible router or phone thermal
  throttling" instead of just showing a falling line on the chart. This is
  something *only* a sustained stress tester can detect — a 10s speed test
  never runs long enough to trigger throttling, so this is structurally
  impossible for competing speed-test apps to offer. Effort: M (~1 day) — one
  new native method (mirrors the existing `getRssi`/`getWifiInfo` pattern) +
  a periodic sample alongside the existing latency probe Timer; iOS has no
  public thermal API, so gate this Android-only like signal dBm already is.

### 📣 Ad / SDK
- In-app debug entry to launch AppLovin/AdMob ad inspectors.
- Ad health screen: SDK init state, loaded slots, consent state, VIP state, last
  load error.

#### 📋 Picked (2026-07-08) — "Trust & Analytics" layer
Decision: after `doc/audit/audit_gemini.md` confirmed near-total compliance
(T01-T22), package that strength into a partner-facing product feature instead
of chasing incremental ops tricks. Broken into 4 tasks in `doc/task/todo/`,
ordered by dependency:
- **T23 — Compliance Report export.** Persist a rolling `AdEventLog` +
  structured safety/consent snapshot, exportable as JSON — evidence a partner
  can hand to Google/AppLovin during an account-suspension appeal. Foundation
  for T24/T25.
- **T24 — Real-time policy risk score.** Turn `AdSafetyConfig`'s existing
  internal signals (CTR, violation count, rapid-resume) into a single 0-100
  score exposed reactively, so partners see risk building *before* an external
  policy strike.
- **T25 — Anomaly/fraud alert stream.** `_triggerSuspiciousPause()` currently
  only logs internally; emit a new `AdAnomalyEvent` on `AdManager().events` so
  partners can pipe anomalies into their own alerting (Sentry, Slack, etc.).
- **T26 — Adaptive frequency capping, Phase 1 only.** Instrumentation-only
  proxy signals (session-length-after-ad, time-to-next-open) logged for
  observation. Explicitly NOT auto-adjusting caps yet — no backend/LTV signal
  exists to validate a bandit algorithm safely; Phase 2 (actual adaptive
  capping) is deferred until Phase 1 data exists.

Supersedes the two 💭 ideas below as the near-term priority — they remain
logged as deferred, not discarded.

#### New ideas (2026-07-07 differentiation pass)
- **Shadow eCPM comparison between AdMob and AppLovin.** Since
  `AdProviderAdapter` is already a shared interface both adapters implement,
  add an opt-in "shadow load" mode that loads (but never shows) the *inactive*
  provider's ad alongside the active one, logging both providers' `AdEvent`
  revenue/fill data side by side per slot type. This gives partners real
  per-slot A/B eCPM signal without the architectural cost of per-slot routing
  (`AdConfig.provider` stays a single app-wide choice) — just a second adapter
  instance running in observe-only mode. Differentiating because most
  lightweight ad-wrapper SDKs force partners to choose one network and never
  surface what they're leaving on the table. Effort: M (~1 day) — no
  `AdConfig`/`AdManager` restructuring needed, just a second adapter instance +
  a comparison log sink; real per-slot routing (mentioned as a bigger lift) is
  explicitly out of scope for this version.
