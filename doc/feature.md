# Feature Status

Updated: 2026-07-18

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

### 📣 Ad / SDK — `applovin_admob_sdk` (hosted pub.dev `^1.1.0`, **published 1.1.1**, ACTIVE 2026-07-18)
- Android + iOS ad integration, runtime provider `AdProvider.appLovin`
  (AdMob kept present for swap-readiness). Root `pubspec.yaml` consumes
  hosted `applovin_admob_sdk: ^1.1.0` from pub.dev; the local `path:
  packages/ad_sdk` override line is commented out. Check `pubspec.yaml`
  directly before trusting this — it has drifted stale before (flipped
  back and forth multiple times during T01-T62 dev).
- **1.1.0 (2026-07-18)** — package is now **public** on pub.dev (was
  previously published but effectively dev-only/undiscoverable metadata);
  this release adds Native Ad v1, MREC, Smart Monetization Arbitrator,
  fill-rate monitor, mediation waterfall reporting, consent-country
  analytics, and config-validation preflight — see `packages/ad_sdk/CHANGELOG.md`
  `[1.1.0]` for the full list. Also fixes a crash where `preloadMrec()` threw
  synchronously on any host app that doesn't configure an MREC slot.
- **1.1.1 (2026-07-18)** — dependency-freshness-only release: bumped
  `confetti` `^0.7.0`→`^0.8.0` and `connection_notifier` `^2.0.1`→`^4.1.0`
  (closes pub.dev Pub Points "up-to-date dependencies" gap). Zero Dart logic
  touched — verified the 3 `connection_notifier` APIs the SDK actually uses
  (`initialize`/`isConnected`/`onStatusChange`) are unchanged across its
  3.x/4.x majors. Root `pubspec.yaml`'s `^1.1.0` constraint already resolves
  to 1.1.1 (no host-side change needed).
- Platform-specific AppLovin ad unit config — `AdKey.appLovin` selects Android
  vs iOS units at runtime; Android and iOS never share unit IDs.
- iOS native config in `ios/Runner/Info.plist`: `GADApplicationIdentifier`,
  `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems`.
- **Audit follow-up T31-T38 (2026-07-13)**: `_eventStream` closed+recreated in
  `destroy()`; `AdManager().isOfflineListenable` (opt-in offline signal, mirrors
  `VipManager.activeListenable`); AppLovin banner's stale native `AdView`
  destroyed before `onAppResumed()` recreates it; splash `mounted` guard
  narrowed to UI-only (ATT/UMP/init always run); example app's iOS Podfile
  platform pin + ad-inspector `kDebugMode` gate. See `doc/task/done/T3{1,3,4,5,6,7,8}-*.md`.
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
- **In-app ad inspector entry (2026-07-13, example app only).** `StatePanelDemoPage`
  gained a button calling each provider's own native debug UI directly —
  `AppLovinMAX.showMediationDebugger()` / `MobileAds.instance.openAdInspector()`
  — picked via `kProvider`. No custom inspector built; both SDKs already ship
  one. `applovin_max` + `google_mobile_ads` added as direct deps of
  `example/pubspec.yaml` (previously only transitive via the SDK).
- **T40 — AppLovin child-user (COPPA) init gate (2026-07-13).**
  `AdProviderAdapter.initialize()` gains `isAgeRestrictedUser` (default
  `false`); `AppLovinAdapter.initialize()` refuses to call the native AppLovin
  SDK at all when it's `true` (AppLovin MAX 4.x has no runtime child-directed
  API — the only compliant option is to never initialize, exposed via the new
  `disabledForChildUser` getter). `AdMobAdapter` accepts but ignores the flag
  (COPPA already honoured per-request via `tagForChildDirectedTreatment`).
  `AdManager.initialize()` now bootstraps `ConsentManager` **before** picking
  the adapter (was after) so a persisted `isAgeRestrictedUser=true` from a
  prior session can actually reach the gate. **Known gap, not fixed**: a
  brand-new install has no persisted consent yet, so on an app that is
  *always* child-directed with no consent dialog at all, `isAgeRestrictedUser`
  defaults `false` and AppLovin still initializes on install #1 — there is no
  `AdConfig`-level "this app is always child-directed" flag. Current app
  (WiFi stress tester) is not child-directed, so this is a documented gap, not
  an active bug — fix before reusing this SDK for a mixed/child audience.
  Tests: `applovin_adapter_test.dart` "COPPA child-user init gate (T40)".
  Verified: `flutter test` 548/548 green + `flutter analyze` clean in
  `packages/ad_sdk`.
- **T41 — example app publish-safety (2026-07-13).** `example/lib/main.dart`'s
  hardcoded real production AppLovin SDK key + 4 ad-unit IDs replaced with
  `YOUR_*` placeholders read via `String.fromEnvironment` — pass
  `--dart-define=APPLOVIN_SDK_KEY=...` (+ per-platform `_BANNER_ID_IOS` /
  `_BANNER_ID_ANDROID` / etc.) to exercise real ads locally; nothing real is
  committed to source anymore. `example/ios/Runner/Info.plist`'s real
  `GADApplicationIdentifier` swapped for Google's public iOS test App ID
  (`ca-app-pub-3940256099942544~1458002511`, matches the Android manifest's
  existing test App ID) and `AppLovinSdkKey` swapped for the same placeholder
  (unused at runtime — the Dart code initializes AppLovin programmatically).
  `kDemoSafetyParams` (999 caps / CTR-check disabled) is now opt-in only via
  `--dart-define=QA_AD_STRESS=true`; without it `DemoConfig.build()` uses
  `AdSafetyParams.auto` like a real app would, so a release build of the
  example never ships with fraud/frequency caps effectively off. Verified:
  `flutter test` 12/12 green + `flutter analyze` clean in `example/`.
- **T32 — AdMob App ID trùng lặp Android/iOS (2026-07-14).** App ID production
  cũ (`ca-app-pub-3612191981543807~9731053733`) bị dán trùng cho cả 2 platform
  — sai vì AdMob console cấp App ID riêng theo từng platform app entry. Chốt
  với user: đổi tạm sang test App ID chính thức của Google (`~3347511713`
  Android / `~1458002511` iOS, khác nhau đúng theo platform), kèm comment rõ
  đây là quyết định có chủ đích + checklist việc cần làm trước khi bật AdMob
  thật. Xem `doc/task/done/T32-admob-appid-duplicated-platforms.md` +
  `doc/AD_PROMPT_FLUTTER.MD`'s "Phụ lục C". Verified: `flutter analyze`
  (root) clean; grep xác nhận ID production cũ không còn ở
  `AndroidManifest.xml`/`Info.plist` (chỉ còn trong comment lịch sử ở
  `ad_keys.dart`, đã cập nhật nội dung).
- **Không watchdog Interstitial/Rewarded — accepted risk (chốt 2026-07-14).**
  User đánh giá và chấp nhận: khác App Open (có hard-cap watchdog 90s), lỗi
  hiếm từ native SDK bên thứ 3 không gọi callback dismiss/fail có thể kẹt
  slot Interstitial/Rewarded vô thời hạn — rủi ro chấp nhận được, không phải
  thiếu sót. Chi tiết + template nếu muốn thêm sau này: `doc/AD_PROMPT_FLUTTER.MD`'s Phụ lục C.
- **T39 — SSV (server-side verification) rewarded ad: app-side wired
  (2026-07-14).** `AdManager.showRewardedAd()` đã có `ssvUserId`/`ssvCustomData`
  sẵn từ trước, nhưng phát sinh thêm 1 lỗ hổng khi wire thật: host app không
  gọi `AdManager` trực tiếp mà qua wrapper `AdScreenState.showRewardedAd()`
  (`ad_screen.dart`) — wrapper này chưa expose 2 tham số đó, phải sửa cả SDK.
  Đã thêm `getOrCreateSsvUserId()` (ID ẩn danh, `Random.secure()`, persist
  SharedPreferences, không thêm dependency `uuid`) + truyền vào
  `history_screen.dart`'s nút export + mở rộng wrapper SDK forward xuống
  `AdManager`. `ssvCustomData` để trống — chưa có server xác minh, out of
  scope. Xem `doc/task/done/T39-ssv-plumbing-unwired.md` +
  `doc/AD_PROMPT_FLUTTER.MD`'s Phụ lục C + `packages/ad_sdk/CHANGELOG.md`.
  Verified: `flutter analyze` root + `packages/ad_sdk` clean; `flutter test`
  root 79/79 + `packages/ad_sdk` 550/550 pass.
- **T42 — consent bị "quên" mỗi lần mở app (2026-07-14).** Tự phát hiện khi
  đối chiếu 6 tài liệu audit với code thật — không nằm trong T31-T39. Host app
  gọi `requestUmpConsent()` → `setConsent(...)` **trước** `initialize()`; lúc
  đó `_consentManager` còn `null` nên consent mới chỉ ở RAM, rồi
  `initialize()`'s `ConsentManager.bootstrap()` load lại dữ liệu **cũ** đã lưu
  từ phiên trước và ghi đè mất giá trị vừa nhận — xảy ra ở **mọi lần khởi
  động app**. Fix: `AdManager` đệm consent chưa persist được vào
  `_pendingConsentSettings`, `initialize()` áp dụng lại buffer này ngay sau
  bootstrap (thắng dữ liệu cũ); `destroy()` xóa buffer khi teardown tường
  minh. Xem `doc/task/done/T42-consent-lost-on-init.md`. Verified: `flutter
  test` 550/550 green (gồm test mới `consent_persistence_on_init_test.dart`,
  dùng provider AppLovin vì dễ giả lập init-thành-công thật hơn AdMob trong
  `flutter test`) + `flutter analyze` clean trong `packages/ad_sdk`.
- **T43 — ATT/UMP consent flow có thể treo vô thời hạn (2026-07-15).** Tự
  phát hiện khi debug hang lặp lại của `consent_dialog_test.dart` trên iOS
  Simulator. `requestAttIfNeeded()` và `requestUmpConsentFlow()` await một
  callback native (dismiss ATT/UMP, hoặc phản hồi mạng
  `requestConsentInfoUpdate`) **không có timeout** — nếu native side không
  bao giờ resolve (ATT bị throttle sau nhiều lần mở app, form UMP không ai
  bấm qua trên test tự động, mạng chết), `AdManager().initialize()` không
  bao giờ chạy, SDK quảng cáo bị đơ vĩnh viễn cho phiên đó. Fix: bọc 3 chỗ
  `await` rủi ro bằng `Future.timeout(20s, onTimeout: () => <fallback an
  toàn>)`. Người dùng chốt "Sửa luôn" qua `AskUserQuestion`. Xem
  `doc/task/done/T43-att-ump-consent-timeout.md`. Verified: `flutter test`
  552/552 pass (gồm test timeout mới `att_consent_test.dart`) + `flutter
  analyze` clean cả `packages/ad_sdk` và repo root.

- **T44 — `requestPrivacyOptionsFlow()` vẫn có thể treo vô thời hạn dù đã có
  timeout guard (2026-07-15/16).** Tự phát hiện khi viết test cho guard T43 đã
  thêm: `dismissCompleter.future.timeout(20s)` là **dead code** vì dòng ngay
  trước đó `await ConsentForm.showPrivacyOptionsForm(...)` tự treo trước —
  hàm này tự await native platform call bên trong trước khi gọi callback
  dismiss, khác với `loadConsentForm`/`form.show()` (fire-and-forget thật).
  Fix: bọc bằng `unawaited(...)` để timeout guard trên `dismissCompleter`
  thật sự có tác dụng. Test mới trong `ump_consent_test.dart` (T44 case)
  verify guard hoạt động thật (trước khi fix, test fail vì `result` vẫn
  `null` sau 20s). `flutter test` 561/561 pass.

- **F4 — iOS `SKAdNetworkItems` chỉ 50 entries, README nói "~70" (2026-07-16).**
  README ghi sai: list AdMob chính chủ ([iOS 14
  guide](https://developers.google.com/admob/ios/ios14#skadnetwork)) thực tế
  vẫn đúng 50 entries (verify trực tiếp qua WebFetch) — "~70" là số liệu cũ,
  không còn đúng. Vấn đề thật của F4 là **thiếu ID của các mediation partner
  AppLovin MAX** (không phải AdMob thiếu). Fix: lấy list chính chủ của
  AppLovin (`https://skadnetwork-ids.applovin.com/v1/skadnetworkids.json`,
  152 entries, confirm là superset chứa đủ 50 ID AdMob) thay cho 50 entries
  cũ trong `ios/Runner/Info.plist`. README's "~70" reference đã sửa lại
  đúng số + nguồn. Verify: XML valid, `grep -c` = 152 `SKAdNetworkIdentifier`,
  `flutter analyze` clean, `flutter test` 79/79 pass (repo root — không có
  test nào assert số lượng SKAdNetworkIdentifier cụ thể).

- **Audit 2026-07-17 — 4 finding High đã fix + 3 feature mới (2026-07-17).**
  Audit toàn diện 5-agent song song theo checklist 7 điểm
  (`doc/audit/audit_claude.md`); user chốt hướng qua 4 `AskUserQuestion`
  (Q1-Q3: fix ngay + làm 3 feature; Q4: "chưa lên production, chờ hết High
  trước"). Tất cả đã xong, điều kiện Q4 đã thỏa:
  - **Fix — UMP EEA test gap.** `initialize()`'s `autoRequestUmpConsent`
    branch (`ad_manager.dart`) trước đây không forward `debugGeography`/
    `testIdentifiers` từ `AdConfig` vào lệnh gọi `requestUmpConsent()` nội bộ
    → không cách nào test luồng UMP EEA qua config. Thêm 2 field mới
    `AdConfig.umpDebugGeography`/`umpTestIdentifiers` + forward đúng vào lệnh
    gọi + seam `debugLastAutoUmpParams` (`@visibleForTesting`) để test xác
    nhận tham số soạn đúng (native UMP không có mock hook thật).
  - **Fix — 3 gap ở app mẫu** (`packages/ad_sdk/example/lib/main.dart`): thêm
    ô nhập SSV user id vào `RewardedDemoPage` (+ hiện "pending SSV
    confirmation"); thêm nhánh `ArbitratorNudgeEvent` vào
    `EventsDemoPage._describe()`; thêm nút "Enable Smart Arbitrator" vào
    `SafetyDemoPage` gọi `AdManager().enableArbitrator(...)` + README mục mới
    "Monetization Arbitrator (opt-in)".
  - **Feature — `AppOpenTrigger` enum** (`both`/`resumeOnly`/`splashOnly`) trên
    `AdConfig`, mặc định `both` (không đổi hành vi hiện tại). `resumeOnly`
    chặn `showAppOpenAd(bypassSafety:true)` ở splash; `splashOnly` chặn
    `showAppOpenAdOnResume()`.
  - **Feature — `AdManager().tcfConsentString`** getter mới (đọc
    `IABTCF_TCString` từ `SharedPreferences` — chuỗi TCF v2.3 thô UMP tự ghi,
    không cần dependency mới) để host tự gửi cho bên thứ 3 cần nó.
  - **Feature — AppLovin adaptive banner: xác nhận ĐÃ adaptive sẵn, không
    phải thiếu sót.** Điều tra kỹ `applovin_bridge.dart` +
    `banner_ad_widget.dart` + plugin `applovin_max` source: banner AppLovin
    hiển thị qua `MaxAdView` widget, tự đọc `MediaQuery.of(context).size.width`
    live tại build time (kể cả khi xoay màn hình) — thực ra adaptive tốt hơn
    cách AdMob làm (AdMob phải reload thủ công khi đổi orientation). Tham số
    `widthPx` bị bỏ (no-op) trong `loadBannerIfNeeded` không phải bug — nó
    chưa từng là thứ điều khiển kích thước AppLovin thật. Quyết định: không
    chế API giả, ghi rõ lý do vào README Pitfalls mục 7 thay vì sửa code.
  Verified: `packages/ad_sdk` 572/572, `packages/ad_sdk/example` 16/16, host
  root 79/79 — toàn bộ pass; `flutter analyze` clean cả 3 scope, zero
  regression. **Q4 go/no-go:** điều kiện "hết finding High" giờ đã thỏa —
  quyết định go-live vẫn cần user chốt riêng, không tự ý tiến hành.

### ⚠️ Accepted risks — audit findings knowingly NOT fixed (2026-07-16)
Người dùng đã xem từng mục qua `AskUserQuestion` và chọn **giữ nguyên** (không
phải bug bị bỏ sót) — ghi lại ở đây để tránh audit vòng sau báo lại như phát
hiện mới:

- **F3 (Gemini, Medium) — VIP signed key one-time-use chỉ per-device, không
  toàn cục.** Ed25519 chống forge key mới, nhưng 1 key hợp lệ (vd promo) bị
  leak công khai (forum/group) thì mỗi máy vẫn redeem được 1 lần → VIP miễn
  phí không giới hạn số máy; không có server nên không revoke được key đã
  mint. Giới hạn nội tại của mô hình offline, đã ghi trong T18. Chấp nhận vì
  app chưa có backend. `vip_manager.dart:475-528`, `signed_vip_key.dart:66-70`.
- ~~**F4 (Gemini, Medium) — VIP entries lưu plaintext JSON trong
  SharedPreferences.**~~ **✅ Đã sửa (2026-07-18)** — migrate sang
  `flutter_secure_storage` (Keychain iOS / EncryptedSharedPreferences Android)
  qua `VipEntriesStore` (`packages/ad_sdk/lib/src/vip/_vip_entries_store.dart`),
  kèm migration 1 lần + xoá key cũ khi thành công. Verify: `run-as` xem trực
  tiếp ciphertext trên Pixel 7 Pro + redeem→force-kill→relaunch giữ VIP trên cả
  iOS Simulator và Android thật. Checksum FNV-1a (T30) không còn cần thiết cho
  bản ghi mới (OS đã encrypt at-rest), chỉ giữ lại để đọc data cũ trong
  migration path.
- **F5 (Gemini, Medium) — COPPA gap ở lần cài đầu tiên nếu app "always
  child-directed".** Không có consent dialog nào set `isAgeRestrictedUser`
  trước install đầu → AppLovin init 1 lần với flag mặc định false (AppLovin
  MAX 4.x không có runtime API để tắt IDFA sau đó). App hiện tại (WiFi stress
  tester) **không** child-directed → rủi ro = 0 hiện tại; chỉ áp dụng nếu SDK
  tái dùng cho app trẻ em sau này. Đã ghi trong T40. `ad_consent.dart:85-93`.
- **F5 (Codex, Low/operational) — không có fallback provider AdMob↔AppLovin
  ở runtime.** Provider chọn tĩnh lúc init (`ad_manager.dart:784`); nếu
  provider đang chọn init fail, SDK không tự thử provider còn lại — toàn bộ
  ad surface tắt cho phiên đó. Quyết định kiến trúc có chủ đích (single
  provider, không dual-waterfall); chỉ cần document, không cần code thêm.
- **F6 (Codex, Low) — `ad_manager.dart` là god-file 2148 dòng.** Gánh
  orchestration + consent + VIP gating + lifecycle observer + retry timers +
  arbitrator hook. Còn maintainable (tên tốt, comment dày) nhưng đã tới
  ngưỡng nên tách. Rủi ro: bảo trì dài hạn, không ảnh hưởng publish. Chấp
  nhận, không refactor trong đợt này. **Cập nhật (2026-07-18)**: navigability
  cải thiện bằng cách mở rộng 12 section-header comment (INITIALIZE, CONSENT,
  DESTROY, APP OPEN, INTERSTITIAL, REWARDED, BANNER, MREC, LIFECYCLE OBSERVER,
  RETRY TIMER, EVENT EMIT, CONNECTIVITY) thành mô tả 1-3 dòng thay vì chỉ có
  tiêu đề trơn — chọn phương án nhẹ nhất trong 3 lựa chọn đưa ra qua
  `AskUserQuestion`, **không tách file**. Rủi ro bảo trì dài hạn vẫn còn
  (giảm bớt, chưa hết).
- **AppLovin adapter — cảnh báo lặp lại khi 1 ad slot fail liên tục (2026-07-18).**
  Thêm `AdSlot.consecutiveFailures` + `_logIfRepeatedFailure` (log-only, không
  đổi hành vi retry/cap hiện có) trong
  `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart` — giúp phát hiện
  sớm slot bị Google/AppLovin từ chối liên tục (vd. policy issue) thay vì chờ
  đến khi partner report doanh thu tụt. Verify: `flutter analyze` sạch,
  `flutter test` 627/627.
- **No-backend-model (T39) — Reward SSV chỉ có app-side plumbing, chưa có
  server verify.** `ssvUserId`/`ssvCustomData` đã thread xuyên suốt
  `AdManager.showRewardedAd`/`AdScreenState.showRewardedAd`, nhưng không có
  backend nào nhận postback AdMob/AppLovin để verify reward thật — quyết định
  phạm vi có chủ đích (chưa có nhu cầu backend), không phải thiếu sót. Xem
  `doc/task/done/T39-ssv-plumbing-unwired.md`.
- **F2 (Gemini, High) — App Open ad hiện trên splash mọi lần mở app, dùng
  `bypassSafety: true` (bỏ qua toàn bộ frequency cap).** Google policy về App
  Open không cho hiện ad theo cách "chặn app đang tải nội dung lần đầu" gây
  nhầm lẫn; ở đây App Open hiện ngay sau init trên splash, mọi cold-start (trừ
  VIP grace 24h cho user mới cài). Người dùng đã **chốt giữ nguyên hành vi
  này** (quyết định thiết kế, không phải bug) — sẽ theo dõi AdMob/AppLovin
  Policy Center nếu bị flag "interrupting app load" thì mới cân nhắc chuyển
  App Open sang chỉ chạy khi resume từ background. `splash_screen.dart:85-129`
  (`bypassSafety:true` tại :129).

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

### 🔬 Smoke-test on-device 4 lượt — hosted `1.0.24` sau publish (2026-07-16)
> Sau khi publish `applovin_admob_sdk` 1.0.24 lên pub.dev + flip root
> `pubspec.yaml` sang hosted (checklist #3 ở trên), chạy smoke-test on-device
> cả 2 app tiêu thụ SDK theo 2 cách khác nhau (hosted pub.dev vs local `path`),
> trên cả Android + iOS, để bao phủ đủ mọi case tiêu thụ dependency.

| App | Nguồn SDK | Android | iOS Simulator |
|---|---|---|---|
| Host app (`saigonphantomlabs`, `com.roy.admobwrapper`) | hosted `^1.0.24` pub.dev | ✅ CPH1989 thiết bị thật — boot sequence AdManager/consent/VIP đúng | ✅ iPhone 17 Pro — tới màn hình chính WiFi Stressor, không crash |
| `packages/ad_sdk/example` | local `path: ../` (luôn dùng local, **không** verify được publish) | ✅ CPH1989 (sau `adb uninstall` do trùng `applicationId` với host app → tránh `INSTALL_FAILED_VERSION_DOWNGRADE`) — VIP grace 30s hết hạn → preload ad thật đúng flow | ✅ iPhone 17 Pro — AppLovin MAX SDK init OK, không `FATAL`/crash/exception, chỉ badge debug "Ad" (không phải ad thật) |

- Cả 4 lượt: **zero crash**, boot sequence `ATT → notSupported → UMP consent
  → setConsent buffered → AdManager.initialize provider=appLovin → VipManager
  → AppLovinAdapter SDK ready` chạy đúng — xác nhận trực tiếp fix T42
  (consent buffer-then-apply) hoạt động đúng ở điều kiện gần-production.
- Lưu ý quan trọng: `packages/ad_sdk/example/pubspec.yaml` hardcode
  `applovin_admob_sdk: path: ../` — **không bao giờ** dùng bản hosted, nên lượt
  test này chỉ verify local-source consumption, không verify được việc publish
  lên pub.dev có đóng gói đúng hay không. Việc đó chỉ được verify qua lượt
  test host app (hosted `^1.0.24`) ở trên.
- 2 lỗi môi trường gặp phải khi build iOS example app (không phải lỗi code):
  `FLUTTER_TARGET` cũ trong `Generated.xcconfig` trỏ file tạm đã xóa (fix:
  `flutter clean && flutter pub get`) và CocoaPods sandbox desync sau đó (fix:
  `cd ios && pod install`).

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

- (Product track: none — Wave 5 complete)
- (Ad/SDK track: **none — audit vòng 4 (2026-07-18) đóng, verdict cuối cùng
  là CÓ, không còn điều kiện chặn nào mở.** Xem `doc/audit/audit_claude.md`
  mục "Re-audit vòng 4 — 2026-07-18". Delta kể từ vòng 3 (cùng ngày) chỉ là
  release 1.1.1 (dependency bump, không đụng logic) — verify độc lập:
  `flutter analyze` sạch cả root + `packages/ad_sdk`, `flutter test`
  624/624 pass. Không có finding mới. Toàn bộ 8 ý tưởng brainstorm vòng 2/3
  đã Implemented (xem mục Ideas bên dưới); việc còn lại chỉ là dọn demo/doc
  không chặn ship (waterfall UI, consent-country UI trong example app) + 1
  lưu ý vận hành (thay AdMob test App ID bằng App ID thật nếu đổi provider
  sang AdMob).)
- (Ad/SDK track: Audit follow-up T31-T42 — **hoàn tất 2026-07-14**, xem
  ✅ Implemented ở trên, `doc/task/done/T3{1,2,...,9}-*.md` + `T42-*.md`)
- **Ad/SDK track — test-coverage cleanup (9 gaps, direct user request),
  picked 2026-07-13.** Not a bug/audit item — user asked to fill remaining
  unit/widget test gaps across `packages/ad_sdk/` + its example app. All 9
  done same day: `ad_route_observer_test.dart` (didRemove/didReplace),
  `top_toast_test.dart` (new), `ad_manager_core_test.dart`
  (showAppOpenAdOnResume guard chain, didHaveMemoryPressure, retry-timer via
  `fake_async`, RevenuePanel compact:false + dispose-safety),
  `debug_ad_overlay_test.dart` (new), `example/test/home_page_test.dart`
  (new), `example/test/revenue_demo_page_test.dart` (new) +
  `events_demo_anomaly_test.dart` (added empty-state case). Verified:
  `flutter test` 542/542 green in `packages/ad_sdk`, 12/12 green in
  `packages/ad_sdk/example`, `flutter analyze` clean in both.
  Cross-checked against a separate coverage-audit agent afterward — found 2
  more genuine gaps (audit's other claims were already covered): the real
  `AdManager.didChangeAppLifecycleState()` dispatcher had no direct test
  (only its inner `showAppOpenAdOnResume()` call was), and
  `debug_ad_overlay_test.dart`'s expand-panel test didn't assert `_SlotRows`
  content (`(no adapter)`/`VIP=`/`Safety:`). Both closed same day: new
  `didChangeAppLifecycleState()` group (`_FakeAdapter` gained
  `onAppPaused`/`onAppResumed` call counters + a `throwOnLifecycle` flag) +
  extended assertions on the existing expand-panel test. 547/547 green,
  `flutter analyze` clean.

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

- ~~**UMP consent form NOT configured** for AdMob app ID.~~ **✅ DONE
  (xác nhận với user 2026-07-19).** User đã publish UMP consent message trên
  AdMob console. Không còn blocking cho release EU/EEA.

## 🧑‍💻 Checklist thao tác tay — trước khi release thật (2026-07-15)

Ba việc dưới đây **Claude không tự làm được** (cần login console/pub.dev của
user, hoặc là quyết định kinh doanh) — user tự làm theo thứ tự nào cũng được,
không phụ thuộc lẫn nhau:

1. ✅ **DONE (xác nhận + verify code 2026-07-19).** Host app (FastNet) đã
   dùng App ID production thật
   (`ca-app-pub-3004713799155145~9488250427`, cùng giá trị Android/iOS) và bộ
   ad-unit ID AppLovin thật trong `AdKey.appLovinAndroid`/`appLovinIos`
   (`lib/mckimquyen/common/const/ad_keys.dart`) — provider đang chạy runtime
   là AppLovin (`AdConfig.provider`) nên đây là phần quyết định doanh thu.
   Bộ `AdKey.adMob` (ad-unit ID fallback, dùng nếu sau này flip provider
   sang AdMob) **vẫn đang là ID test của Google — có chủ đích**, chỉ cần đổi
   khi thật sự chuyển provider. **Phát hiện phụ:** example app của SDK
   (`packages/ad_sdk/example`) vẫn đang hardcode App ID production thật này
   (đáng lẽ nên dùng App ID test) — tách thành ticket riêng, xem
   `doc/task/todo/T44-example-app-real-admob-appid.md`.
2. ✅ **DONE (xác nhận với user 2026-07-19).** Đã publish UMP consent form
   trên AdMob console — xem mục Blockers phía trên (đã chuyển sang trạng thái
   done).
3. ✅ **DONE 2026-07-16 — Publish `packages/ad_sdk` v1.0.24 lên pub.dev + flip
   `pubspec.yaml`.** Root `pubspec.yaml` đã bỏ comment dòng hosted
   `applovin_admob_sdk: ^1.0.24` (pub.dev, sha256 `cc8ee183...`), comment lại
   dòng `path: packages/ad_sdk`; `flutter pub get`/`flutter analyze` clean.
   Đã smoke-test on-device xác nhận — xem mục "Smoke-test on-device 4 lượt"
   ngay bên dưới mục "On-device verification".

## ⏸️ Deferred

- Recheck native ad SDK majors (AppLovinSDK / Google Mobile Ads) each quarter —
  confirm whether the CocoaPods/Dart version pins in `dependency_overrides`
  (root `pubspec.yaml`) can be relaxed now that upstream has moved. Retested
  2026-07-10: still blocked (`gma_mediation_applovin >=2.6.0` needs
  `meta ^1.17.0`, Flutter SDK 3.35.1's `flutter_test` pins `meta 1.16.0`). See
  `doc/audit/audit_partner_lead_20260710.md` finding #2/#3. **Lần kiểm tra kế
  tiếp: ~2026-10-13** (3 tháng sau lần audit 2026-07-13, chốt qua
  `AskUserQuestion`) — thử lại `flutter pub get` sau khi bump 3 package trên
  theo version SDK tự khai báo.

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

### Audit re-verify + 3 quyết định qua AskUserQuestion (2026-07-16)

Re-verify toàn bộ "should-fix" của 3 audit (`doc/audit/audit_claude.md`,
`audit_gemini.md`, `audit_codex.md`) — tất cả blocking đã đóng, verdict cuối:
**Có, dùng production được.** Phát sinh thêm 1 lỗi CHANGELOG staleness (nội
dung 1.0.24 vẫn nằm nhầm dưới `## [Unreleased]`) — đã sửa.

3 điểm còn mở (không blocking) được đưa cho người dùng chọn qua
`AskUserQuestion`, đã chốt và implement xong:
- **App Open trên splash (Gemini F2):** giữ nguyên hành vi (placement eCPM cao
  nhất) + thêm comment giải thích rõ rủi ro/mitigation ngay trên
  `AdManager().showAppOpenAd(..., bypassSafety: true)` ở
  `lib/mckimquyen/widget/splash/splash_screen.dart`. Theo dõi AdMob Policy
  Center sau ship thay vì gỡ/rào ad.
- **AdMob App ID còn là test ID:** giữ nguyên tới khi AdMob thật sự trở thành
  provider chính (không đổi code) — recommended option, tránh đổi ID rồi lại
  phải đổi lại.
- **`redeemVip()` demo mode khi `vipKeyValidator == null` (Gemini F7):** đã vá —
  `_runValidator()` ở `packages/ad_sdk/lib/src/vip/vip_manager.dart` refuse mọi
  key khi `kReleaseMode == true` và validator null (thay vì assert, vì
  `assert()` bị strip khỏi release build nên không bảo vệ được gì ở đúng build
  cần bảo vệ nhất); debug/profile giữ nguyên demo-mode để không phá luồng dev.
  Chỉ ảnh hưởng luồng `redeemVip()` cũ — production dùng `redeemSignedKey()`
  (Ed25519) nên không đổi hành vi thật. Verify: `flutter analyze` sạch +
  `flutter test` 561/561 pass (`packages/ad_sdk`), root app `flutter analyze`
  sạch + `flutter test` 79/79 pass sau comment ở splash_screen.dart.

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
- ~~Ad health screen: SDK init state, loaded slots, consent state, VIP state,
  last load error.~~ **Skipped (2026-07-13)** — already covered rải rác qua
  các trang có sẵn trong `packages/ad_sdk/example`: `StatePanelDemoPage` (SDK
  init/destroy, per-slot state/fails/lastError/lastLoaded),
  `ConsentDemoPage` (consent state), `VipDemoPage` (VIP state). Xây thêm 1
  màn hình gộp chỉ để tiện hơn — không đáng effort, sẽ duplicate UI có sẵn.

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

#### New ideas (2026-07-17 audit vòng 2 brainstorm) — chờ chọn qua AskUserQuestion

1. ~~**Adaptive banner size cho AppLovin** (S).~~ ✅ Không phải gap thật —
   audit vòng 2 nhầm vì chỉ đọc `preloadWidgetAdView` (chỉ nhận `AdFormat`
   enum, không nhận width) mà bỏ sót tầng widget: `_AppLovinMaxAdView` trong
   `banner_ad_widget.dart` đã dùng `MaxAdView(isAdaptiveBannerEnabled: true)`,
   tự đọc `MediaQuery` width lúc build (kể cả khi xoay màn hình) — banner
   AppLovin **đã adaptive trong thực tế**, chỉ khác cơ chế AdMob (không qua
   tham số `widthPx` truyền vào lúc load). Đã có sẵn README mục "AppLovin
   banner width" giải thích đầy đủ; chỉ sửa 1 comment gây hiểu lầm ở
   `applovin_adapter.dart:loadBannerIfNeeded` cho khớp (2026-07-17).
2. **MREC ad format** (M). Thêm `AdSlotType.mrec` (300×250), mirror toàn bộ
   lifecycle load/show/dispose đã có cho banner ở cả 2 adapter.
3. **Native Ad format** (L). ✅ Implemented (2026-07-18, v1) — eCPM cao nhất,
   effort/risk bảo trì cao nhất trong danh sách, cần asset-binding riêng
   (title/icon/CTA/media view) và label "Ad/Sponsored" đúng pháp lý. Xem mục
   "Cập nhật 2026-07-18 (Native Ad v1, #3)" cuối file.
4. **Shadow fill-rate alert** (S-M). Mở rộng ý "Shadow eCPM comparison" ở
   trên — nếu provider active liên tục fail-to-load trong khi shadow-provider
   fill tốt, emit cảnh báo gợi ý switch provider.
5. **Arbitrator per-slot threshold + veto-rate guardrail** (S). Ngưỡng eCPM
   theo từng `AdSlotType` thay vì 1 ngưỡng chung; tự tắt tạm nếu veto-rate
   vượt X% trong rolling window (chống estimator lỗi làm mất hết ad).
6. **Mediation waterfall / adapter response reporting** (M). Surface
   `getResponseInfo()` (AdMob) / waterfall callback (AppLovin) qua `AdEvent`
   để partner debug "tại sao eCPM thấp hôm nay" ngay trong app.
7. **GDPR consent analytics theo quốc gia** (S). Bổ sung Trust/Compliance
   layer (T23-T26) — log consent decision kèm country code vào `AdEventLog`
   để `ComplianceReport` show breakdown theo vùng.
8. **Config validation / preflight check** (S). `AdConfig.validate()` (hoặc
   tự chạy ở debug init) cảnh báo lỗi config phổ biến (test ad-unit ID sót
   lại trong release, `firstInstallVipGrace` xung đột safety cap thấp bất
   thường...) thay vì fail âm thầm lúc runtime.

Đề xuất ưu tiên (rẻ + khép nợ cũ trước): #1 + #8 + #5, rồi tới #4/#2/#6/#7
theo nhu cầu, #3 (Native Ad) sau cùng vì effort/risk cao nhất. Chi tiết đầy đủ
kèm lợi ích/rủi ro/breaking-change ở `doc/audit/audit_claude.md` mục "(E)
Feature/enhancement brainstorm vòng 2".

**Cập nhật 2026-07-18 (sau audit vòng 3):** #2 (MREC), #4 (Fill-rate monitor),
#5 (Arbitrator per-slot + guardrail), #6 (Mediation waterfall), #7 (Consent
country), #8 (Config validation) — ✅ **Implemented**. #3 (Native Ad) ban đầu
⏸️ **Deferred** — effort/risk cao nhất, cố tình để làm sau cùng.

**Cập nhật 2026-07-18 (Native Ad v1 — #3) — ✅ Implemented.** Toàn bộ 8 ý
tưởng brainstorm vòng 2 nay đã xong. Chi tiết đầy đủ (2 nhánh render khác
nhau theo provider, test compliance nhãn "Ad") ở mục "Cập nhật 2026-07-18
(Native Ad v1, #3)" phía dưới, cuối file.

Audit vòng 3 (6 agent song song) xác nhận 0 Critical/High trên 7 tính năng
vừa ship, fix live 1 Medium (`AdManager.destroy()` không dispose
arbitrator/fill-rate-monitor) + 1 Low (threshold `FillRateMonitor` không
validate). Agent E ban đầu báo 4/7 tính năng thiếu doc/demo, nhưng **verify
tay bằng grep README + example app (2026-07-18) bác bỏ 1 claim**: AppOpenTrigger
load-gate thực ra đã có doc sẵn từ vòng 2 (README dòng 621+633) — không cần
sửa.

**Cập nhật 2026-07-18 (audit vòng 4, session mới) — 4 "gap" trên bị stale, đã
đóng từ trước, verify lại bằng grep trực tiếp source (không dựa vào doc cũ):**
- Config validation (#8) — **đã có doc**: README mục "Release-build safety
  checks (config validation)" liệt kê đủ cả 2 warning mới
  (`umpDebugGeography` còn set, `AppLovinConfig.sdkKey` rỗng).
- Arbitrator per-slot/guardrail (#5) — **đã demo**: `SafetyDemoPage` gọi
  `AdManager().enableArbitrator(MonetizationArbitrator(...
  perSlotThresholdMicros: const {...`.
- Mediation waterfall (#6) — **đã hiển thị**: `EventsDemoPage` đọc
  `e.mediationWaterfall` và render trực tiếp trong dòng log.
- Consent country (#7) — **đã có UI**: `ConsentDemoPage` hiển thị
  `country=${s.country ?? ...}`.

(MREC #2, Fill-rate monitor #4, và AppOpenTrigger đã hoàn thiện đầy đủ cả doc
lẫn demo/doc tương ứng — cả 7 tính năng vòng 3 nay đều có doc + demo đầy đủ,
0 gap còn mở.)

#### New ideas (2026-07-18 audit vòng 3 brainstorm)

1. **Dashboard chẩn đoán hợp nhất** (S). Gộp waterfall + fill-rate + arbitrator
   veto stats thành 1 `AdManager.diagnostics()` hoặc 1 debug-overlay panel duy
   nhất — hiện là 3 tín hiệu rời rạc, partner phải tự ghép để trả lời "vì sao
   eCPM thấp hôm nay".
2. **Integration self-check tự động** (M). `AdManager.runIntegrationSelfCheck()`
   (debug-mode) chạy init→consent→mỗi loại ad→VIP redeem→dispose, trả về 1
   checklist pass/fail — thay vì partner phải tự click qua ~15 trang demo để
   biết SDK hoạt động đúng trên máy họ.

**Thứ tự đã chốt với user (2026-07-18):** dọn 5 gap doc/demo ở trên trước
(rẻ nhất, không đụng logic) → rồi 2 ý tưởng brainstorm này (S/M effort, để
integration self-check + dashboard sẵn sàng hỗ trợ verify khi làm việc khó
nhất) → cuối cùng mới tới Native Ad v1 (#3, effort/risk cao nhất trong toàn bộ
backlog).

**Cập nhật (brainstorm vòng 3, cả 2 ý tưởng) — ✅ Implemented:**
1. **Dashboard chẩn đoán hợp nhất** → `AdManager.diagnostics()` trả về
   `AdDiagnostics` (waterfall mới nhất/slot + fill-rate/slot + arbitrator
   estimated eCPM/veto-rate), export qua barrel công khai. Waterfall-indexing
   được tách thành hàm pure `AdDiagnostics.lastWaterfallBySlotFrom()` (mirror
   pattern `ComplianceReport.generate`) để test không cần `AdEventLog`/
   `SharedPreferences` sống — `ad_diagnostics_test.dart` (7 test).
2. **Integration self-check tự động** → `AdManager.runIntegrationSelfCheck()`
   (debug-only) chạy checklist init→per-slot-load→VIP-wiring, trả
   `SelfCheckResult`/`SelfCheckItem`/`SelfCheckStatus` (cũng export công khai)
   — `integration_self_check_test.dart` (4 test).

Cả `packages/ad_sdk` test suite (614/614) và `flutter analyze` sạch sau khi
thêm 2 tính năng này.

**Cập nhật 2026-07-18 (audit vòng 4, session mới) — đóng nốt gap demo/README
cho 2 tính năng trên.** Grep trực tiếp `example/lib/main.dart` xác nhận SDK
đã có code + test nhưng **không có demo page nào** dùng `diagnostics()` hay
`runIntegrationSelfCheck()` — đây là gap thật duy nhất còn sót của cả backlog
vòng 3 (khác 4 gap ở trên vốn đã bị stale/sai). Đã thêm `DiagnosticsDemoPage`
(§18, mirror pattern `ComplianceDemoPage`) vào example app + mục README
"Diagnostics & integration self-check" (giữa Fill-rate monitor và Native Ad
v1). `flutter analyze` sạch trên `packages/ad_sdk/example`. Từ giờ **0 gap
doc/demo còn mở** cho toàn bộ 7 tính năng vòng 3 + 2 ý tưởng brainstorm.

**Cập nhật 2026-07-18 (Native Ad v1, #3) — ✅ Implemented — toàn bộ backlog
audit vòng 2/3 đã xong.** Research trực tiếp trong source `google_mobile_ads`
7.0.0 và `applovin_max` 4.6.4 xác nhận giả định ban đầu ("1 layout Dart tuỳ
biến dùng chung 2 provider") **sai kỹ thuật** — 2 provider dùng 2 cơ chế tích
hợp khác nhau ở tầng render (không chỉ tầng adapter), dù dùng chung 1
lifecycle-shell (gating VIP/offline/cooldown, mirror `MrecAdWidget`, bỏ hẳn
route-pause/auto-refresh vì không áp dụng cho native):
- **AdMob**: `NativeAd extends AdWithView` — giống hệt `BannerAd`/MREC, preload
  rồi `AdWidget`. Dùng `NativeTemplateStyle(templateType: TemplateType.medium)`
  — template tự vẽ nhãn "Ad"/AdChoices, package không vẽ thêm.
- **AppLovin**: `MaxNativeAdView` là widget tự quản lý, load khi mount trực
  tiếp từ `adUnitId` + layout Dart tuỳ biến (`MaxNativeAdIconView`/
  `MaxNativeAdTitleView`/`MaxNativeAdMediaView`/`MaxNativeAdBodyView`/
  `MaxNativeAdCallToActionView`) — **không** qua `preloadWidgetAdView`/adViewId
  bridge banner/MREC dùng. Vì layout ở đây là Dart thật, package phải tự vẽ
  nhãn "Ad" (mirror `_MrecContainer`'s badge) — đây cũng là format đầu tiên
  cần test compliance-nhãn thật (trước đó **không có test nào** assert nhãn
  "Ad" thực sự render, ở bất kỳ format nào).

Đã thêm: `AdSlotType.native`, `nativeId` config (cả 2 provider), interface
`nativeSlot`/`native`/`preloadNative()`/`buildAdmobNativeView()`/
`appLovinNativeId` trên `AdProviderAdapter`, `NativeAdWidget` mới + fixed
height 320px (khuyến nghị Google cho `TemplateType.medium`), `buildNative()`
trên `AdScreen`, Native accessors facade trên `AdManager`, demo tile + trang
trong example app, export công khai qua barrel, mục README "Native Ad (v1)"
(nêu rõ v1 = layout cố định, không phải editor tuỳ biến). Test mới:
`native_ad_widget_test.dart` (8 case, gồm 2 test compliance-nhãn "Ad" —
AppLovin phải hiện, AdMob không được hiện đúp) + adapter slot-state-machine
test cho `nativeSlot` ở cả `admob_adapter_test.dart`/`applovin_adapter_test.dart`.

`packages/ad_sdk` test suite: 624/624 pass. `packages/ad_sdk/example` test
suite: pass. `flutter analyze` sạch ở cả 2. Idea #3 là idea cuối cùng còn lại
trong backlog audit vòng 2 — toàn bộ 8 ý tưởng brainstorm vòng 2 nay đều
✅ Implemented.

**Cập nhật 2026-07-18 (audit vòng 4 — verdict cuối cùng sau release 1.1.1).**
Session mới (context clear), user yêu cầu audit toàn diện lại đúng 7 tiêu chí
gốc (dual-provider Android+iOS, online/offline, lifecycle 5 loại ad, trial 1
ngày, VIP-by-code không backend, consent mọi quốc gia, policy AdMob/AppLovin).
Trước khi lặp lại 6-agent audit như 2 vòng trước, kiểm tra delta trước:
`git log` cho thấy đúng 3 commit mới kể từ vòng 3 (cùng ngày) — release
**1.1.1** (bump `confetti`/`connection_notifier`), regenerate plugin
registrant macOS/Windows example, doc refresh — **cả 3 đều không đụng
`lib/src/**`**. Vì không có logic mới để re-audit, thay vào đó verify độc
lập (không tin lại commit message):
- `flutter analyze` sạch cả `packages/ad_sdk` và repo root.
- `flutter test` (`packages/ad_sdk`) — toàn bộ suite chạy xong, không có
  dòng fail nào, khớp 624/624 mà commit 1.1.1 tự báo.
- Native config (`AndroidManifest.xml`/`Info.plist` AdMob test App ID,
  `pubspec.yaml` provider wiring) re-check — chưa đổi so với ghi nhận vòng
  2/3.

**Không tìm thấy finding mới.** Toàn bộ kết luận vòng 1-3 (kể cả mọi finding
đã fix: F1 App-Open reload gate, F7 privacy-options timeout, debugGeography/
testIdentifiers, AppOpenTrigger load-gate, destroy() dispose arbitrator/
fill-rate-monitor, FillRateMonitor threshold assert...) vẫn nguyên giá trị.
**Verdict cuối cùng: CÓ — sẵn sàng production, không còn điều kiện chặn nào
mở.** Chi tiết đầy đủ ở `doc/audit/audit_claude.md` mục "Re-audit vòng 4 —
2026-07-18".
