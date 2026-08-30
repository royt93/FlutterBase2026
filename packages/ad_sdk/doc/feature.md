# Feature Status

Updated: 2026-08-19 (version pointers refreshed 2026-08-25)

> **Single source of truth** for `applovin_admob_sdk` feature decisions
> (Ad/SDK + VIP integration only).
>
> **Historical note:** this file was originally written when this repo also
> contained a WiFi stress-tester host app developed alongside the SDK. That
> app has since been extracted into its own separate repo and now consumes
> the SDK as a published pub.dev dependency; this repo's root holds no app
> code of its own anymore. Sections that described the host app's own
> product features (network diagnostics, speed charts, history/export, room
> tagging, etc. — nothing to do with ads/VIP/consent) have been removed
> below as out of scope for this repo. Older dated entries below that
> discuss the SDK's own features/fixes sometimes still reference that former
> host app's files (e.g. `wifi_stressor_screen.dart`, `lib/mckimquyen/...`)
> for historical context — those files no longer exist in this repo, but the
> SDK-side fix/feature being described is still accurate and kept for the
> audit trail. See `packages/ad_sdk/CHANGELOG.md` for the authoritative,
> up-to-date version history (current: **2.4.0**) and `doc/audit/` for the
> full audit-round history.
>
> **Coding rules for every Picked item** (from `doc/init.md` + `doc/TODO.md`):
> no `print`/`debugPrint` → use `SafeLogger`; no `late` → nullable + init; no
> force-null `!`; no memory leak; **full vi + en i18n** for every new
> user-facing string in `packages/ad_sdk/example`.

---

## ✅ Implemented

> (This section originally opened with a "🛜 Product — WiFi stress tester"
> block describing the former host app's own speed-test/network-diagnostics
> features — parallel download stress test, history/Hive storage, network
> info dashboard, etc. None of that is part of this SDK; it described a
> different app that now lives in its own separate repo. Removed as out of
> scope for this repo — see `doc/task/` / `doc/archive/` if the historical
> detail is ever needed.)

### 📣 Ad / SDK — `applovin_admob_sdk` (current: **2.4.0**, see `packages/ad_sdk/CHANGELOG.md`)

> The version/host-app details in this specific bullet block below (pub.dev
> `^1.1.0`/`1.1.1`, "ACTIVE 2026-07-18") are a snapshot from when this entry
> was first written and are stale — kept as historical context for the
> narrative that follows. Current SDK version is 2.4.0; the narrative below stops at 2.1.0 on purpose — everything after it lives in CHANGELOG.md.

- **2.1.0 (2026-08-19) — same-day audit + fix pass** (`doc/audit/audit_claude_20260819.md`,
  `CHANGELOG.md`): App Open (and interstitial/rewarded/rewarded-interstitial)
  could be shown stale past their 4h/1h freshness window because `isAdFresh`
  was only checked on load-reuse, never at `show*()` time — fixed for all 4
  AdMob fullscreen types. `showAppOpenAdOnResume()` always called
  `showAppOpenAd(bypassSafety: true, ...)`, bypassing the daily/hourly/session
  cap and CTR-fraud pause outside the one case (splash) this SDK's own
  contract allows — fixed to `bypassSafety: false` for the resume path.
  AppLovin banner/MREC widgets leaked their native `MaxAdView` on normal
  disposal (`disposeBannerInstance`/`disposeMrecInstance` never called
  `destroyWidgetAdView`) — fixed. Added `attOrderFootgunWarning` (loud, not
  release-gated) for the previously log-only `requestAtt()`-before-UMP
  ordering footgun. 849 → 857 tests passing, `flutter analyze` clean.
  Also fixed a stale load-watchdog timer race in `AdSlot.armLoadWatchdog()`
  and 2 minor P2 cleanup items (destroy() cooldown maps, duplicate consent
  listener on re-init) landed just before this round.

- Android + iOS ad integration, runtime provider **`AdProvider.admob`**
  (switched from `AdProvider.appLovin` 2026-08-08 — AppLovin kept present
  for swap-readiness). Root `pubspec.yaml` consumes hosted
  `applovin_admob_sdk: ^1.1.0` from pub.dev; the local `path:
  packages/ad_sdk` override line is commented out. Check `pubspec.yaml`
  directly before trusting this — it has drifted stale before (flipped
  back and forth multiple times during T01-T62 dev).
- **Provider switch to AdMob (2026-08-08)** — `AdKey.adMob` (`ad_keys.dart`)
  now holds real production AdMob ad unit IDs (banner/interstitial/
  appOpen/rewarded), replacing Google's public test IDs. This satisfies the
  debug-only `assert()` guard in `splash_screen.dart` (R10-F) that fails
  loudly if `AdProvider.admob` is active while test IDs are still present —
  the guard is unchanged, it simply no longer fires. `AdProvider.appLovin`
  stays fully configured as the fallback/swap target.
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
- **First-install VIP grant-time notice (2026-07-19, SDK 1.2.1).** The
  first-install VIP grace grant (`AdManager.initialize()` →
  `vip.addVip(key: firstInstallVipKey, ...)`) used to be completely
  silent/log-only — end users had no idea ads were suppressed, which was the
  likely root cause of "ads don't show" partner complaints on fresh installs.
  `VipManager` gains `firstInstallGrantDueListenable` +
  `lastFirstInstallGrantDuration` + `acknowledgeFirstInstallGrant()`, mirroring
  the grace-nudge pattern above but one-shot/not persisted (the grant call is
  already guarded by `AdPreferences.isFirstInstallGraceApplied()`, so it
  naturally fires once per legitimate install/reinstall). Host wires it in
  `wifi_stressor_screen.dart` via `AdManager().initRevision` (re-attaches
  across SDK re-init) + a one-shot `SnackBar`. Tests:
  `vip_manager_first_install_grant_notice_test.dart` (4). Verified: host
  `flutter analyze`/`flutter test` clean, SDK 639+4/643 pass, on-device
  (Samsung S24 Ultra) build+install+launch+logcat clean — no crash, normal
  AdManager/VipManager lifecycle (grant path itself not re-exercised on this
  device since it already consumed its grace in earlier sessions).
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

- **T44 — Example app (`packages/ad_sdk/example`) hardcode App ID AdMob
  production thật (2026-07-19).** Phát hiện phụ trong lúc audit checklist
  AdMob console: `AndroidManifest.xml`/`Info.plist` của example app dùng
  chung App ID production thật với host app
  (`ca-app-pub-3004713799155145~9488250427`) dù toàn bộ ad-unit ID trong app
  này đều là ID test — sai vì đây là app demo public, không nên gắn tài khoản
  production thật. Fix: đổi sang App ID test công khai của Google
  (`ca-app-pub-3940256099942544~3347511713` Android, `~1458002511` iOS).
  Verify: `flutter analyze` clean, `app_boot_test.dart` 3/3 pass trên Pixel 7
  Pro xác nhận SDK vẫn init khỏe với App ID mới. Xem
  `doc/task/done/T44-example-app-real-admob-appid.md`. **Lưu ý số hiệu:** số
  T44 này trùng với entry "T44" phía trên (`requestPrivacyOptionsFlow()`,
  2026-07-15/16) — hai việc khác nhau, trùng số vì entry kia chỉ narrate
  trong doc chứ chưa từng có file `doc/task/done/T44-*` riêng khi ticket T44
  này được tạo. Không đổi số vì 3 commit/file liên quan đã merge — chỉ ghi
  chú để tránh nhầm khi tra cứu sau này.

- **T45 — 6 demo page trong example app thiếu integration test coverage
  (2026-07-19).** Audit tìm ra Mrec, Native ad, Monetization Arbitrator,
  Fill-Rate Monitor, consent-country, Diagnostics & self-check — ra mắt qua
  nhiều đợt trước đó (T31-T41) — chưa có test nào. Thêm 6 file test mới theo
  pattern sẵn có (navigate từ HomePage, thao tác control thật, assert state
  thật của `AdManager()`/`ConsentManager`, không chỉ "không crash"). Phát
  hiện + sửa 2 bug finder thật trong lúc viết test: `find.byType(FilledButton)`
  không match `FilledButton.icon` (Flutter match theo `runtimeType` chính
  xác, factory `.icon` build subclass riêng); và tiêu đề trùng giữa tile
  HomePage và AppBar trang được push khiến `findsOneWidget` fail (do
  `MaterialPageRoute` giữ trang cũ mounted offstage) — sửa bằng
  `findsWidgets`. Verify: `flutter analyze` clean; cả 6 file chạy trên Pixel
  7 Pro (`2B051FDH3006MU`) pass, 3 file phụ thuộc ad-network thật (mrec,
  native, diagnostics) chạy lại lần 2 vẫn ổn định, không flaky. Xem
  `doc/task/done/T45-example-missing-integration-tests-newer-demos.md`.

- **T46 — `flutter_lints` lệch version giữa example app và parent package
  (2026-07-19).** Example app pin `^4.0.0` trong khi `packages/ad_sdk`
  (parent) đã lên `^6.0.0`. Fix: bump example app theo. Verify:
  `flutter pub get` + `flutter analyze` clean, không phát sinh lint mới. Xem
  `doc/task/done/T46-example-flutter-lints-version-drift.md`.

- **Audit vòng 7 (2026-07-19) — 8.7/10, CÓ production-ready — F1/F3/F4/F6/F7/F8/F9
  đã fix, ĐÃ PUBLISH pub.dev 1.2.0 và tích hợp vào host.** Toàn bộ 9 finding
  của round 7 (F1-F9, gồm cả F2/F5 fix ở phiên trước) giờ đã fix: `event_bus.dart`
  replay buffer cho late subscriber (F1); `ad_manager.dart` nâng cảnh báo consent
  misconfig thành `assert()` dev-time + log warning nếu gọi UMP trước ATT
  trên iOS (F4, F9); `revenue_panel.dart` gate `kDebugMode` qua
  `debugModeOverride` test seam (F9); `example/ios/Runner/Info.plist` đồng
  bộ 152 `SKAdNetworkItems` khớp host app (F8); phần còn lại (F3, F6, F7, 2
  sub-item khác của F9) là doc-only trong `packages/ad_sdk/README.md`. Kết
  quả: 639/639 test pass, `flutter analyze` clean, build+install+run thật
  trên Samsung S24 Ultra (không crash, không real ad — R4 không kích hoạt) +
  iOS Simulator compile-only build SUCCEEDED. Chi tiết:
  `doc/audit/audit_claude.md`.
  **Publish + tích hợp (2026-07-19):** `packages/ad_sdk` bump `1.1.1` →
  `1.2.0`, `dart pub publish` lên pub.dev thành công; host `pubspec.yaml`
  đổi constraint `applovin_admob_sdk: ^1.1.0` → `^1.2.0`. SDK 1.2.0 kéo theo
  transitive deps mới đòi bump `connectivity_plus: ^6.1.1` → `^7.0.0` và
  `confetti: ^0.7.0` → `^0.8.0` ở host (cả 2 xác nhận an toàn — connectivity_plus
  chỉ dùng qua API ổn định trong `NetworkInfoService`, confetti không dùng
  trực tiếp trong `lib/`), kéo theo phải bump Android toolchain: AGP
  `8.9.1`→`8.12.1`, Gradle wrapper `8.11.1`→`8.13`, Kotlin `2.1.0`→`2.2.0`
  (`connectivity_plus` 7.x yêu cầu). Trong lúc verify "test full", phát hiện
  và fix thêm 1 lỗ hổng **không liên quan tới chuỗi bump trên**: 2 file test
  host (`test/vip_screen_widget_test.dart`,
  `test/wifi_stressor_screen_grace_nudge_test.dart`) construct `VipManager`
  thật không inject fake `VipEntriesStore`, nên đâm vào
  `flutter_secure_storage` platform channel thật trong môi trường
  `flutter test` — channel này **treo vô thời hạn thay vì throw**
  `MissingPluginException` (khác các plugin khác), gây timeout 10 phút/test.
  `packages/ad_sdk`'s own test suite luôn né lỗi này bằng
  `_FakeVipEntriesStore` (xem `vip_manager_robustness_test.dart`); 2 file host
  trên thiếu pattern này — đã bổ sung theo đúng pattern có sẵn. Verify cuối:
  `flutter pub get`/`analyze`/`build apk --debug` sạch, toàn bộ 80 test host
  (`flutter test` repo root) pass, `packages/ad_sdk` vẫn 639/639.

- **Audit vòng 8 (2026-07-19 đêm) — 8.6/10, CÓ production-ready — 6 finding
  Medium/Low, không blocking.** Phát hiện round 7 từng tự nhận sai (N1: vẫn
  còn log GAID ở một nhánh debug) cộng 5 finding mới khác. Chi tiết:
  `doc/audit/audit_claude.md`.

- **Audit vòng 9 (2026-07-20) — CÓ, 9.0/10, SDK bump `1.2.2` — cả 7 finding
  đều đóng.** N1/N2/N4/N5 fixed thật; N3/N6/F7 xem lại và giữ nguyên (verified
  as already-acceptable, không phải bỏ sót). 649/649 test pass.

- **CI iOS integration-test job + 2 flake fix (2026-07-21, PR #2 merged vào
  `main`).** Thêm job iOS Simulator integration test vào `.github/workflows/test.yml`
  (song song job Android emulator có sẵn) và fix 1 flake Android emulator OOM.
  Trong lúc làm CI xanh, phát hiện + fix thêm 3 lỗi không liên quan tới bump
  ban đầu: (1) `AdManager().initialize()`'s `consentFootgunWarning` assert
  trip trên iOS CI vì dart-define `SKIP_UMP=true` bỏ qua
  `requestUmpConsent()` — fix: gọi `AdManager().setConsent(AdConsent.conservative)`
  stub trước `initialize()` khi `_skipUmp` (`example/lib/main.dart`). (2)
  `app_boot_test.dart` splash-timeout flake trên Android CI — root cause là
  emulator contention sau 1 lần `adb uninstall` lỗi đẩy cold-start thật lên
  ~37s, quá budget cũ 30s (app vẫn boot thành công, không phải bug logic) —
  fix: nới poll budget 30s→45s. (3) `consent_country_demo_test.dart` tap
  "Set" trượt trên iOS Simulator vì bàn phím ảo thật mở ra co Scaffold lại,
  đẩy nút ra khỏi vùng đã `scrollUntilVisible` cho country field trước đó
  (Android CI tắt bàn phím ảo nên không tái hiện) — fix: `scrollUntilVisible`
  lại cho nút "Set" ngay trước khi tap. Kết quả cuối: cả 4 job CI xanh
  (`ad_sdk`, `host app`, Android + iOS integration test).

- **Audit vòng 10 (2026-07-22) — 8.8/10, CÓ production-ready, 6 sub-agent
  song song audit lại từ đầu (không kế thừa kết luận vòng 9).** 1 finding
  High phạm vi hẹp (R10-A, chỉ ảnh hưởng nếu host bật
  `autoRequestUmpConsent: true`), 3 Medium (R10-B COPPA đổi giữa phiên,
  VIP Android-reinstall-replay đã biết, R10-F test-ID landmine đã biết),
  còn lại Low/Info (R10-C/D/E/G). **Round 11 (2026-07-28) — cả 8 finding
  đã đóng**, thực thi qua kế hoạch 9-task (superpowers
  subagent-driven-development, trực tiếp trên `main`): đảo thứ tự UMP
  consent trước init adapter (R10-A, `ad_manager.dart`); hard-stop
  AppLovin khi COPPA đổi giữa phiên (R10-B, `setConsent()`); đồng bộ
  Android Auto Backup config `packages/ad_sdk/example` với host + sửa doc
  comment `_first_install_guard.dart` cho đúng thực tế (VIP
  reinstall-replay — **vẫn là giới hạn kiến trúc đã ghi nhận, không phải
  100% fix**, đúng ràng buộc no-backend); `assert()` debug chặn AdMob
  test ID nếu lỡ chọn provider AdMob (R10-F, `splash_screen.dart`);
  `NSUserTrackingUsageDescription` (iOS) viết lại tiếng Việt cụ thể hơn
  (R10-G); `_retryRefillAds()` no-op hoàn toàn khi offline (R10-C);
  timeout 20s cho `ConnectionNotifierTools.initialize()` (R10-D); doc
  giải thích lý do interstitial/rewarded không có watchdog (R10-E).
  Không thêm dependency mới (pub package/native lib), không
  backend/server. Kết quả: 657/657 test pass, `flutter analyze` sạch cả
  `packages/ad_sdk` và host, CI 4 job xanh, review toàn-branch cuối cùng
  (model Opus, 10 commit) verdict "Ready to merge: YES" (0
  Critical/Important, 3 Minor không chặn). Chi tiết:
  `doc/audit/audit_claude.md` mục "Round 10" / "Round 11".

- **R12-A dryRun release guard (2026-07-28 → 2026-08-01, 9/10 cuối).**
  `AdSafetyConfig.applyDryRunReleaseGuard()` tự ép `dryRun=false` trong release
  build (`assert()` bị strip ở release nên không tự bảo vệ được) + log qua
  `SafeLogger.critical()` (bỏ qua `AdLogLevel.none`). 5 vòng self-review hardening
  dần: hợp nhất check `kReleaseMode` rải rác qua `isActuallyRelease()`; xoá 1
  test vô nghĩa pass giả (AdMob mock luôn fail init trước khi chạm code nó
  tuyên bố kiểm chứng); sửa bug rò rỉ state thật trong `destroy()`
  (`_footgunBlocked`/`_umpRequested`/`_consentExplicitlySet` chưa từng được
  reset); cập nhật `README.md` + comment đầu `ad_manager_core_test.dart` đang
  mô tả sai hành vi dryRun cũ (warn-only) so với hành vi mới (silent
  force-correct).
  **Round 4 (2026-08-01, audit 8-finder-angle, 7/10 → 6 fix áp dụng):**
  thread nốt `isRelease` vào 2 chỗ còn sót
  (`ad_manager.dart` guard consent-footgun + `VipManager(...)` constructor)
  — trước đó 2 call site này gọi `isActuallyRelease()` không tham số nên
  luôn tương đương `kReleaseMode` thô (`false` khi `flutter test`); thêm
  seam test `VipManager.debugRunValidator()` + 2 test thật cho guard này
  (nhánh tương đương ở `ad_manager.dart:1228` **không thể** test end-to-end
  vì `initialize()` luôn fail ở bước khởi tạo native adapter dưới
  `flutter test` — giới hạn kiến trúc, đã ghi rõ trong comment thay vì giả
  vờ có coverage); gộp `SafeLogger._shouldLog` nhận tham số `bypassLevel`
  thay vì 2 nhánh trùng lặp trong `e()`; sửa số liệu sai
  (662/662 · 10/10) trong `audit_claude.md` bằng ghi chú làm rõ đây là
  snapshot cũ trước 3 vòng hardening sau; gộp nốt 1 đoạn comment lặp còn lại
  trong `ad_safety_config.dart` (giải thích lý do `isRelease` không đánh dấu
  `@visibleForTesting` ở `init()`) thành con trỏ về doc-comment của
  `applyDryRunReleaseGuard()`. Kết quả cuối: 674/674 test pass ở
  `packages/ad_sdk` (672 + 2 test mới), `flutter analyze` sạch cả 2 vùng.
  Chi tiết: `doc/audit/audit_claude.md` mục "Round 12".
  **Round 5 (2026-08-01, audit 8-finder-angle → 10 verifier, 7.5/10 → 2 fix
  áp dụng):** `_footgunBlocked` bị rò state qua re-init — nhánh auto-dispose
  của `initialize()` (khi gọi lại lần 2 mà không qua `destroy()`) đã reset
  timer/connectivity-watch/adapter nhưng **quên** reset `_footgunBlocked`, nên
  1 lần init cũ với `isRelease:true` (trip footgun) sẽ khoá ads vĩnh viễn dù
  init sau đó `isRelease:false`; đã thêm `_footgunBlocked = false;` vào đúng
  nhánh đó. `SafeLogger.critical()` vs `e(bypassLevel:true)` (finding đã
  approve từ vòng trước nhưng chưa làm) — gộp thành `_e()` private dùng
  chung, `bypassLevel` không còn public trên `e()`, chỉ `critical()` gọi được;
  xoá 2 test trùng đã assert hành vi này qua `e(bypassLevel:true)`. 1 finding
  PLAUSIBLE chấp nhận giữ nguyên: `applyDryRunReleaseGuard()` không dedup nên
  re-init lặp lại sẽ log `critical()` nhiều lần — nhưng không có auto-retry
  loop nào gọi `initialize()`/`AdSafetyConfig.init()` (`_retryRefillAds()`
  không đụng tới), chỉ 1 lần gọi từ `splash_screen.dart` nên latent, không
  active-triggered. Kết quả: 674/674 test pass, `flutter analyze` sạch host +
  `packages/ad_sdk` — 1 warning `invalid_use_of_visible_for_testing_member` ở
  `ad_manager.dart:1025` (pre-existing từ Round 4, `VipManager.isRelease` dùng
  ở production call site, ngoài phạm vi 2 finding được duyệt vòng này) đã fix
  ngay sau đó bằng cách xoá `@visibleForTesting` khỏi `isRelease` param trong
  `vip_manager.dart`, mirror đúng pattern đã dùng ở `ad_safety_config.dart`
  (`isRelease` không cần annotation vì an toàn đến từ `isActuallyRelease()`,
  không phải từ compile-time restriction) — 674/674 test pass, 0 warning.
  **Round 6 (2026-08-01, audit 8-finder-angle → 9 verifier, 2 CONFIRMED / 2
  PLAUSIBLE / 5 REFUTED):** nhánh reinit-without-`destroy()` của
  `initialize()` (dòng ~962) chỉ reset `_footgunBlocked` (fix Round 5) mà
  **quên** `_umpRequested`/`_consentExplicitlySet` — cùng lớp bug vừa fix, chỉ
  khác field: 1 init cũ đã request UMP/set consent xong, rồi re-init lần 2
  (không qua `destroy()`) với config thật sự không gather consent, thì
  `consentFootgunWarning()` vẫn đọc flag cũ = `true`, im lặng bỏ qua cảnh báo
  EEA/UK consent-footgun đáng lẽ phải trigger `_applyConsentFootgunGuard()`.
  Root cause: `destroy()` và nhánh reinit tự tay duy trì 2 danh sách reset
  field riêng biệt — đúng cơ chế đã gây ra bug Round 5. Đã fix triệt để hơn
  Round 5 (không chỉ patch thêm field): gộp 3 field guard-state
  (`_footgunBlocked`/`_umpRequested`/`_consentExplicitlySet`) vào 1 method
  dùng chung `_resetGuardState()`, gọi từ cả `destroy()` lẫn nhánh reinit —
  không còn 2 danh sách tay để lệch nhau lần 3. Thêm debug getter/setter cho
  `_umpRequested`/`_consentExplicitlySet` (mirror `debugFootgunBlocked` có
  sẵn) + 1 test mới xác nhận `debugResetGuardState()` clear cả 3 flag cùng
  lúc. Finding CONFIRMED thứ 2 (không cần fix thêm, chính là fix trên): thiếu
  shared reset method — verify xác nhận `AdSafetyConfig` đã có pattern này
  (`resetForReinit()`) làm đối chứng. 2 finding PLAUSIBLE giữ nguyên (rủi ro
  thấp, không sửa): `releaseFootgunWarnings`/`consentFootgunWarning` có
  ordering invariant giữa các bước trong `initialize()` chỉ enforce bằng
  prose comment (không assert/type) nhưng mỗi hàm chỉ 1 call site tuần tự nên
  khó vô tình vi phạm; đoạn doc-comment "barrel-export rationale" lặp lại
  giữa `ad_safety_config.dart`/`vip_manager.dart` (style, không tác hại). 5
  finding REFUTED: `SafeLogger.critical()` vẫn honor `tagFilter` (đã tài liệu
  hoá rõ là cố ý, không phải promise gap); debug-wrapper pattern
  (`debugApplyConsentFootgunGuard`/`debugRunValidator`) chỉ là 1 idiom lặp lại
  20+ lần trong codebase, không phải duplicate logic giữa 2 file; tham số
  `isRelease` thread qua 3 file là seam bắt buộc ở mỗi entry point test-
  injectable, không gộp được; `initialize()` có `isRelease` public không phải
  lỗ hổng bypass vì `isActuallyRelease() = isRelease || kReleaseMode` luôn
  đóng lại ở release build thật; `bypassLevel` bool riêng tư tốt hơn thêm enum
  `AdLogLevel.critical` (breaking change cho public config type). Kết quả:
  675/675 test pass (674 + 1 test mới), `flutter analyze` sạch.

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

> (A "🔐 Session 2026-06-15 — security + policy hardening" block was removed
> here — it covered the former host app's own keystore/gradle setup and a
> `wifi_stressor` module code-style cleanup, unrelated to this SDK.)

### 📣 Ad/SDK — audit vòng 6 follow-up T47/T48/T49 (2026-07-19)
- **T49 — `VipManager.addVip(stack: false)` giờ clamp `maxStackDuration`.**
  Nhánh `stack: false` (Q14A "latest expiry wins") giờ clamp `now + duration`
  về `now + maxStackDuration` giống hệt nhánh `stack: true` — 1 grant đơn lẻ
  có `duration` tự nó vượt cap không còn bypass được cap nữa.
  `packages/ad_sdk/lib/src/vip/vip_manager.dart`. Test mới trong
  `vip_manager_stacking_test.dart` + sửa lại 1 test cũ trong
  `vip_manager_robustness_test.dart` (test cũ khóa cứng đúng hành vi bug,
  đổi tên + assertion sang hành vi đã fix).
- **T48 — thêm test e2e cho VIP-trial 1-ngày.** Test mới trong
  `ad_manager_core_test.dart` gọi `AdManager().initialize()` thật (config
  AdMob + `FirstInstallVipGrace.day`) rồi assert `vip.isActive`/
  `activeListenable.value`/`expiresAt` qua toàn bộ init flow thật (không chỉ
  gọi `addVip()` cô lập). Phát hiện thêm 1 gotcha khi viết test: `AdPreferences`
  cache instance dạng static singleton — phải gọi `AdPreferences.resetForTest()`
  trong `setUp()`, nếu không state của 1 test trước rò rỉ sang (grace tưởng đã
  applied từ trước, silently no-op).
- **T47 — CI giờ chạy `integration_test/` trên Android emulator thật.** Job
  mới `sdk-integration` trong `.github/workflows/test.yml` dùng
  `reactivecircus/android-emulator-runner` (API 34, ubuntu-latest + KVM) chạy
  `flutter test integration_test` trong `packages/ad_sdk/example` — 20 file
  (mrec/native ad/arbitrator/fill-rate/consent-country/diagnostics demo…)
  không còn phải chạy tay. Chưa verify chạy thật trên GitHub Actions (chưa
  push) — cần theo dõi lượt CI đầu tiên sau khi merge.
- 644 → 645 test trong `packages/ad_sdk` (full suite pass, không regression).

## 🟡 In progress

> (A "Product track" bullet describing the former host app's Wave 7 work —
> data-usage limits, benchmark-vs-ISP, multi-server selection, auto-schedule
> reminders — was removed here as out of scope; it described a different
> app's roadmap, now in a separate repo.)

- **Ad/SDK track:** as of the 2026-08-19 audit + fix pass (`doc/audit/audit_claude_20260819.md`),
  the 3 real findings from that round are fixed (App Open staleness,
  `showAppOpenAdOnResume` safety-cap bypass, AppLovin banner/MREC native-view
  leak — see the 2.1.0 entry above), 857/857 tests passing. Open, non-blocking
  items: ATT-before-UMP ordering enforced only by a (now louder) warning, not
  a hard block; the published pub.dev listing needs a new version cut to
  pick up everything since 2.0.4. (2026-08-20: re-checked the old
  `MIGRATION.md`'s "2.0.0 breaking changes" §7 — it already covered all 3
  2.0.0 defaults; that prior claim of missing guidance was stale. The file
  was since merged into `doc/AD_PROMPT_FLUTTER.MD` → Appendix D per a direct
  user request, unrelated to that claim.) One standing technical item unchanged from
  prior rounds: `gma_mediation_applovin >=2.6.0` needs `meta ^1.17.0` while
  Flutter 3.35.1's `flutter_test` forces `meta 1.16.0` — blocked on a Flutter
  SDK upgrade, re-check ~2026-10-13 (see this repo's own `CLAUDE.md` for the
  full current pinning-wall detail).

> (Sections below — "Implemented — Wave 6/5/4/2/1/3", "Blockers", the manual
> release checklist, and the old dependency-recheck "Deferred" item — covered
> the former WiFi-stress-tester host app (network dashboards, chart types,
> room tagging, ISP-dispute export, thermal detection, its production AdMob
> App ID rollout, its root `pubspec.yaml`) and have been removed as out of
> scope for this SDK-only repo. See `doc/task/` / `doc/archive/` for the
> historical record if ever needed.)

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

> (A "🛜 Product" idea list — benchmarking/leaderboard, multi-server
> scheduling, custom test params, network-dashboard extras, theme toggle —
> was removed here as out of scope; it was the former WiFi-stress-tester host
> app's backlog, now in a separate repo.)

### 📣 Ad / SDK
- ~~Ad health screen: SDK init state, loaded slots, consent state, VIP state,
  last load error.~~ **Skipped (2026-07-13)** — already covered rải rác qua
  các trang có sẵn trong `packages/ad_sdk/example`: `StatePanelDemoPage` (SDK
  init/destroy, per-slot state/fails/lastError/lastLoaded),
  `ConsentDemoPage` (consent state), `VipDemoPage` (VIP state). Xây thêm 1
  màn hình gộp chỉ để tiện hơn — không đáng effort, sẽ duplicate UI có sẵn.

#### ✅ Implemented (2026-08-09) — "Trust & Analytics" layer (T23-T26)
Decision: after `doc/audit/audit_gemini.md` confirmed near-total compliance
(T01-T22), package that strength into a partner-facing product feature instead
of chasing incremental ops tricks. All 4 tasks were coded and merged earlier
than this doc reflected — verified 2026-08-09 by reading the source directly
and re-running the test suites (30/30 pass, `flutter test
test/compliance_report_test.dart test/ad_safety_config_risk_score_test.dart
test/ad_anomaly_event_test.dart test/adaptive_frequency_test.dart` in
`packages/ad_sdk`); task files live in `doc/task/done/T23-...md` .. `T26-...md`:
- **T23 — Compliance Report export.** `packages/ad_sdk/lib/src/compliance/`
  (`ad_event_log.dart` rolling ring buffer + `compliance_report.dart`
  structured safety/consent snapshot, exportable as JSON — evidence a partner
  can hand to Google/AppLovin during an account-suspension appeal). Test:
  `test/compliance_report_test.dart`.
- **T24 — Real-time policy risk score.** `AdSafetyConfig.policyRiskScore`
  (`ValueNotifier<int>`, `packages/ad_sdk/lib/src/core/ad_safety_config.dart`)
  turns existing internal signals (CTR, violation count, rapid-resume) into a
  single 0-100 score exposed reactively. Test:
  `test/ad_safety_config_risk_score_test.dart`.
- **T25 — Anomaly/fraud alert stream.** `AdAnomalyEvent`
  (`packages/ad_sdk/lib/src/state/ad_event.dart`) emitted on
  `AdManager().events` from `_triggerSuspiciousPause()` so partners can pipe
  anomalies into their own alerting (Sentry, Slack, etc.). Test:
  `test/ad_anomaly_event_test.dart`.
- **T26 — Adaptive frequency capping, Phase 1 only.**
  `AdaptiveFrequencySignals` (`packages/ad_sdk/lib/src/adaptive/
  adaptive_frequency.dart`) — instrumentation-only proxy signals
  (session-length-after-ad, time-to-next-open) logged for observation.
  Explicitly NOT auto-adjusting caps yet — no backend/LTV signal exists to
  validate a bandit algorithm safely; Phase 2 (actual adaptive capping) stays
  deferred until Phase 1 data exists. Test: `test/adaptive_frequency_test.dart`.

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
