# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.9.13] - 2026-09-02

Round-32 follow-up — user reviewed the ~15 MAJOR findings one by one
(non-technical walkthrough, plain-language pros/cons per item) and approved
a batch of them for this release. Two items were re-verified and downgraded
during that review: audit_round32_deep_consolidated.md's #6 (COPPA-AppLovin
part) was a **false positive** — `AppLovinAdapter` already tears down and
re-initialises correctly when the child-directed flag changes mid-session;
and the AVP1-legacy-VIP-key concern is a **documented intentional
tradeoff** (`signed_vip_key.dart`'s own comment: "AVP1 stays accepted so
keys already handed out keep working"), not a bug — kept as-is, no action.

**Fixed:**

- `remote_ad_safety_provider.dart`: `minSessionDurationBeforeAd` was missing
  the `min: 1` floor round-30 already gave its two sibling throttle fields —
  a remote config of `0` disabled the warm-up anti-bot gate outright.
- `ad_manager.dart`: `canShowRewardedInterstitialAd()` was the one of three
  fullscreen `canShow*` peeks missing the `AdLoadingDialog.isShowing` gate
  its two siblings both have — a host polling it while another fullscreen
  flow's non-dismissable loading dialog was up could open the RI disclosure
  dialog on top of it (UI stuck, not a double-shown ad).
- `example/lib/main.dart`: the splash's buffered App Open `onComplete`
  callback checked `mounted` but not `_navigated` — the exact race
  `AdReadinessSplashController` already guards against (round-31), missing
  from this hand-written example. A slow ad load finishing right as the
  hard-cap timer navigates away could show App Open on top of HomePage.
- `ad_bootstrap.dart`: `bootstrap()` had no bound on how long it waits for
  `AdManager.initialize()` — a wedged native init (never calls back) could
  leave a bare `await bootstrap(...)` splash frozen for the full ~130s
  worst-case retry pileup. New `AdBootstrapOptions.initTimeout` (default
  20s) bounds the wait without cancelling the real init, which keeps
  running and still updates `AdManager`'s state; pass `null` to restore the
  old unbounded wait.

**Documented (no behaviour change, reviewed and kept as intentional):**

- `vip_manager.dart`: the AVP2 bundle-binding check silently skips (rather
  than fails closed) when `PackageInfo.fromPlatform()` throws — comment
  expanded with the explicit tradeoff and a corrected note that passing an
  empty string instead of `null` would NOT actually fix it (verified:
  `signed_vip_key.dart`'s reject condition treats both identically).
- `ad_manager.dart`: `showAppOpenAd`'s `bypassSafety` param got a loud
  doc-comment warning — it is not technically restricted to the splash
  screen, only conventionally.
- `README.md`: documented that `AdScreenRouteLogger`'s dialog-stacking guard
  cannot see `OverlayEntry`-based popups (toast/loading libraries,
  `SnackBar`) — no SDK-side fix possible, host must avoid overlapping them
  with an App-Open-eligible resume window.

**Deferred to a separate follow-up (not in this release):**

- No automatic runtime failover between AdMob and AppLovin when one is
  degraded — provider selection is already fully runtime-configurable
  (`AdConfig.provider`, including a stable per-install A/B cohort via
  `pickProviderCohort()`), but switching mid-session today means the host
  calling `destroy()` + `initialize()` with a different provider itself;
  the SDK does not detect a degraded provider and do that automatically.
  Real feature work, tracked separately.
- AppLovin banner/MREC impression+revenue timing (counted at ad-fill, not
  real display) and AppLovin native ads never emitting a revenue event at
  all — both real, both approved to fix, in progress separately from this
  release.

Suite: 1559/1559 pass. `flutter analyze`: 0 issues.

## [2.9.12] - 2026-09-02

Round 32 — 3 fully independent CLI agents (codex, agy/Gemini, claude) audited
the SDK in parallel, each on its own isolated `git worktree`, with no shared
context with each other or with the orchestrating session. 3 different
verdicts came back (0/1/1 BLOCKER); the orchestrator then read the real
source to verify every BLOCKER claim before trusting it — both turned out
real, independent of each other, both on the consent path. `agy` missed both
(shallower read); its report is kept for reference in
`doc/audit/audit_agy.md` with a correction note, not as a production
verdict. Full detail: `doc/audit/audit_round32_deep_consolidated.md`.

**BLOCKER:**

- **Fix**: `applyConsentToProviders()` (`ad_consent.dart`) swallowed the
  exception from either provider write (AppLovin's fire-and-forget
  `setHasUserConsent`/`setDoNotSell`, or a thrown/timed-out AdMob
  `updateRequestConfiguration`) and then recorded `_lastAppliedToProviders =
  c` unconditionally regardless. Resume/reconcile compares device TCF state
  against that value and skips retrying once they match — so a transient
  write failure during a consent withdrawal could leave a provider
  personalised while the SDK believed it had already gone restrictive. Now
  only records it once both writes actually complete without throwing.
- **Fix**: `IabStorage.tcfAllowsPersonalisedAds()`'s `try { await
  _open().timeout(5s) } on StateError { return null; }` only caught the
  test-harness case. `_open()` itself already swallows everything except
  `StateError`, so the only other way to escape that clause is the
  `.timeout()` firing — a `TimeoutException`, not a `StateError` — if the
  open itself never settles (a wedged `PackageInfo.fromPlatform()` binder
  call is the realistic trigger, Android cold-start). That undid the exact
  fail-closed guarantee round-31 added for this function: 3 of 4 real call
  sites in `ad_manager.dart` have no try/catch around it, so the timeout
  could escape as an unhandled exception instead of failing closed. Added a
  `catch (e)` beside the existing `on StateError`.

Both fixed RED→GREEN (new tests: `ad_consent_test.dart` mocks a provider
write throwing and asserts the committed-consent value doesn't move;
`tcf_personalisation_consent_test.dart` uses `fakeAsync` + a new
`@visibleForTesting IabStorage.debugOpenOverride` seam — `Platform.isAndroid`
can't be faked in `flutter test`, so this is the only way to make the open
step itself hang without a real Android device). `flutter analyze`: 0
issues. Suite: 1555/1555 pass.

~15 further MAJOR findings from this round (no runtime AdMob↔AppLovin
fallback, AppLovin banner/native revenue-event gaps, `bootstrap()` with no
hard-cap, a couple of dialog-stacking edge cases, a missing `min:1` floor on
one remote-safety field, etc.) are catalogued in
`doc/audit/audit_round32_deep_consolidated.md` — left for a follow-up round,
prioritised with the user.

## [2.9.11] - 2026-09-02

**Published to pub.dev** — nhảy thẳng từ 2.9.6 (5 version 2.9.7-2.9.10
chưa từng lên pub.dev). Trước khi publish đã verify thật: pod install
pinning wall (AppLovinSDK resolve đúng 13.5.0), build+chạy `example/` thật
trên iOS Simulator và Android thật (TECNO SPARK Go 2024) — bao gồm form
UMP EEA thật (không priming dialog), xác nhận không lặp lại sau cold
restart.

Round 31 — full re-audit từ đầu của TOÀN BỘ `lib/src/` + `example/` (lần
đầu ai đọc riêng `example/`), ưu tiên sâu AdMob provider. 9 agent song
song, không tin báo cáo cũ, đối chiếu policy Google/Apple mới nhất khi
cần. Tìm 2 BLOCKER + ~20 MAJOR + ~6 MINOR thật; 2 finding khác hoá ra
false positive sau khi tự verify sâu (ghi lại dưới, không "sửa" bằng giải
pháp giả). Mọi fix RED→GREEN mutation-verified. Suite 1553/1553 pass.

**BLOCKER:**

- **Fix**: `AdMobAdapter.initialize()` gọi `updateRequestConfiguration`
  (mang cờ COPPA `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent`)
  SAU `MobileAds.instance.initialize()` — ngược thứ tự Google Flutter
  Targeting guide yêu cầu, và ngược chính pattern SDK đã tự sửa đúng cho
  AppLovin (MJ1). Mediation network con (Meta/Unity...) init bên trong
  `initialize()` có thể gửi request đầu tiên thiếu cờ trẻ em. Đổi thứ tự.
- **Fix**: `IabStorage.tcfAllowsPersonalisedAds()` không phân biệt được
  "chưa từng có TCF session" (an toàn, mặc định `true`) với "platform
  store đọc lỗi" (nguy hiểm, từng mặc định `true` giống hệt) — nếu đường
  đọc TCF trên iOS (chưa từng verify trên máy thật, CI chết từ
  2026-08-09) âm thầm lỗi, tái phát đúng BLOCKER round-6 (coi `obtained`
  là đủ để bật personalized ads dù EEA user đã từ chối). Đọc trực tiếp
  qua `_open()`, phân biệt store thật sự không đăng ký (test-only,
  không đổi hành vi) với lỗi đọc thật (fail-closed).

**Core (`ad_manager.dart`, `ad_safety_config.dart`, `remote_ad_safety_provider.dart`, `ad_preferences.dart`):**

- **Fix (MAJOR)**: `disableFillRateBaselineMonitor()` copy-paste sai từ
  `destroy()`, tắt luôn cả 3 tính năng opt-in khác không liên quan
  (`WaterfallTuner`/`SelfHealingObserver`/`JourneyPrefetcher`).
- **Fix (MAJOR)**: `_attachFullscreenDismissWatchers()` thiếu
  `rewardedInterstitialSlot` — format này (AdMob-only) vẫn dùng mốc
  dismiss "brittle" cũ (stamp lúc earn-reward, không phải lúc video thật
  đóng), App Open có thể bounce-back ngay sau RewardedInterstitial.
- **Fix (MAJOR)**: `refreshRemoteSafetyParams()` thiếu try/catch quanh
  merge override (khác `initialize()` có), và `posInt()` throw
  `UnsupportedError` với `Infinity`/`-Infinity` (`d == d.truncateToDouble()`
  đúng cho Infinity) — payload remote hỏng có thể crash. Thêm try/catch +
  sửa root cause (`isFinite` check).
- **Fix (MAJOR)**: daily ad count dùng ngày lịch LOCAL
  (`DateTime.now().toIso8601String()`), không như mọi rolling window khác
  trong file (đều dùng `millisecondsSinceEpoch` tuyệt đối) — đổi múi giờ
  thiết bị (không cần chỉnh đồng hồ) là reset counter tuỳ ý. Đổi sang UTC.
- **Fix (MAJOR)**: CTR-anomaly detection tự khoá vĩnh viễn — show bị chặn
  không tính impression để pha loãng tỉ lệ, nên lần show tiếp theo sau khi
  hết pause tự động re-trigger ngay với ratio cũ, escalate vô hạn. Thêm
  gate "chỉ đánh giá lại sau ≥5 impression MỚI kể từ lần trigger trước" —
  không reset counter thô (sẽ phá `ctrComponent` của risk score).
- **Fix (MINOR)** cùng chỗ: exponent clamp (4) khiến `_maxSuspiciousPause`
  (24h) không bao giờ đạt tới (tối đa thực tế 8h) — nâng clamp lên 6.
- **Fix (MAJOR)**: decay math cho suspicious-violation-count không clamp
  `hoursSince` — đồng hồ bị vặn lùi (không cần tiến, khác MJ9) làm hệ số
  decay > 1, KHUẾCH ĐẠI violation count thay vì giảm. Thêm `math.max(0, …)`.
- **Fix (MINOR)**: `unitDouble('suspiciousCtrThreshold')` chấp nhận `0.0`
  — backend serialize thiếu field thành `0` sẽ khiến MỌI click bị coi là
  bất thường. Thêm sàn `> 0.0`.

**AdMob adapter:**

- **Fix (MAJOR)**: banner/MREC/native chưa từng wire `onAdImpression`
  thật — dùng `onAdLoaded` (fill, không phải impression thật) làm proxy,
  không bao giờ emit `AdImpressionEvent` cho 3 định dạng này, và làm méo
  mẫu số CTR-fraud detection. Wire đúng callback thật.
- **Fix (MINOR)**: banner/MREC dùng `onAdOpened` cho click, native dùng
  `onAdClicked` — hai sự kiện được Google tài liệu hoá là khác nhau.
  Thống nhất về `onAdClicked` cho cả 3.

**AppLovin adapter:**

- **Fix (MAJOR)**: App Open chưa từng được thêm ad-identity tracking mà
  round-29 đã thêm cho Interstitial/Rewarded — `onAdHiddenCallback` tự
  tài liệu là "unreliable, có thể trễ 10-30s", late callback từ cycle cũ
  có thể set `_displayConfirmed`/resolve nhầm cycle mới. Thêm `_appOpenAd`
  + identity guard cho cả 3 callback (displayed/display-failed/hidden).
- **Fix (MINOR)**: remote safety override thiếu 2 field T126
  (`maxSameNetworkShowsPerWindow`, `networkFatigueWindowMs`) — network-
  fatigue guard không remote-tunable được dù mọi field số khác đều có.
- **Fix (MINOR)**: doc comment sai ở `_emitRevenueIfPresent` (nói revenue
  đến từ load callback — thực ra là display/impression time, hành vi
  đúng, chỉ comment sai).
- Đối chiếu tự verify: 2 finding khác của audit lần này (banner/mrec
  `incrementDailyAdCount`/`incrementPlacementDailyCount` thiếu write-chain;
  widget listener thiếu `_teardownStarted` guard) hoá ra **false positive**
  — lần lượt vì `SharedPreferences` legacy cache mutate đồng bộ (không có
  race thật trong Dart đơn luồng) và vì `_bannerDisposed`/`_mrecDisposed`
  đã tự bảo vệ qua scratch-object fallback. Không sửa; ghi lại lý do +
  test pin đúng hành vi hiện tại để tránh "sửa" lại nhầm sau này.

**VIP:**

- **Fix (MAJOR)**: `RedeemedKeyLedger._writeChain` là field instance-level
  (không static) — mirror đúng bug pattern `VipManager._saveQueue` đã sửa
  ở round-10 nhưng KHÔNG áp dụng ở đây. `AdManager` không truyền lại ledger
  cũ khi `destroy()`+`initialize()` lại → 2 instance ghi đè Keychain lên
  nhau → 1 kid đã redeem có thể "biến mất" khỏi ledger bền vững, cho phép
  redeem lại sau reinstall trên iOS. Đổi sang static, mirror chính xác
  `_saveQueue`'s `_savesInFlight` pattern.
- **Ghi nhận (không sửa bằng checksum)**: high-water-mark chống tua đồng
  hồ và danh sách kid đã redeem trên Android đều là plain
  `SharedPreferences`, không mã hoá — nhưng KHÔNG thêm checksum: chính
  lịch sử audit của repo này (M6, `_vip_entries_store.dart`) đã chứng
  minh checksum không-khoá với salt nằm trong source code published lên
  pub.dev không phải bảo vệ thật trước đúng kẻ tấn công cần chặn. Ghi rõ
  đây là giới hạn chấp nhận được của kiến trúc "không backend", cùng tầng
  rủi ro (cần root/trích xuất vật lý) với các giới hạn khác đã biết.
- **Ghi nhận**: `_first_install_guard.dart`'s bypass-result matrix thiếu
  1 dòng — genuine first launch trên máy MỚI restore từ iCloud backup của
  máy cũ đã nhận grace bị false-positive block. Trade-off sản phẩm thật,
  không có accessibility value nào chặn được cả 2 hướng cùng lúc.

**Widget:**

- **Fix (MAJOR)**: `AdReadinessSplashController`'s buffer-dialog
  `onComplete` chỉ check `ctx.mounted`, không check `_navigated` — hard-cap
  timer có thể fire (điều hướng sang Home) TRONG LÚC buffer 1s vẫn đang
  đếm, route splash cũ vẫn `mounted` trong lúc exit-transition → App Open
  có thể show SAU KHI đã điều hướng. Thêm check `_navigated`.
- **Fix (MAJOR)**: `NativeAdWidget`'s retry-after-30s listener
  (`nativeHasError`) chỉ subscribe MỘT LẦN ở `initState` — sau bất kỳ chu
  kỳ dispose/revive nào (consent gate đóng-mở lại, rất phổ biến) bundle
  mới được tạo với notifier mới, listener cũ chết im lặng, quay lại đúng
  bug round-29 tưởng đã fix. Track + re-subscribe đúng notifier hiện tại
  mỗi lần `_initNative()` chạy.
- **Fix (MAJOR)**: banner/MREC chỉ dựa `RouteAware`, không phủ được
  bottom-nav dựng bằng `IndexedStack`/`Visibility(maintainState: true)`
  (không có Route change nào để RouteAware thấy) — ad ở tab ẩn tiếp tục
  refresh/request nền, đúng loại vi phạm policy "requesting ads that
  aren't visible". Thêm `TickerMode.of(context)` detection (bắt được
  `Visibility(maintainState: true)`/`CupertinoTabScaffold`, KHÔNG bắt
  được `IndexedStack` trần — ghi rõ giới hạn còn lại + workaround trong
  doc comment của cả 2 widget).
- **Fix (MINOR)**: `DebugAdOverlay`'s stream subscribe chỉ thử 1 lần ở
  `initState` — mount trước khi `enableFillRateBaselineMonitor()` chạy
  thì mất tín hiệu alert vĩnh viễn. Retry mỗi `build()` (rẻ, chỉ debug
  tool).

**Monetization (chỉ tài liệu hoá, không đổi hành vi):**

- `WaterfallTuner.recommendation()`/`SelfHealingObserver` không bao giờ
  có thể trả về non-null trên thiết bị thật, vì kiến trúc 1 install =
  1 provider cố định suốt vòng đời khiến `otherKey` luôn rỗng. Đã opt-in
  sẵn (off theo mặc định) — ghi rõ giới hạn thật vào doc comment của cả
  2 class + 2 method `enable*` trên `AdManager`, để host không kỳ vọng
  sai tính năng "flagship" này sẽ tự kích hoạt.

**Consent/GDPR/COPPA/CCPA:**

- **Fix (MAJOR)**: prompt ATT (iOS) không có mutex "on-screen" như UMP
  form — cùng loại dialog native ngoài Flutter route mà
  `AdScreenRouteLogger`/App-Open-resume-guard không thấy được. Tái dùng
  chính xác `markUmpFormOnScreen()` (ref-counted, backstop 15 phút) thay
  vì xây cơ chế song song; release gắn vào future GỐC (không timeout) để
  tránh đúng bug UMP form từng gặp (timeout Dart-side không đóng dialog
  native thật).
- **Fix (MAJOR)**: không có cảnh báo nào khi app khai `isAgeRestrictedUser:
  true` (COPPA) nhưng để `umpTagForUnderAgeOfConsent` ở mặc định `false`
  trong khi UMP flow vẫn chạy — form UMP chuẩn (206 đối tác) có thể hiện
  cho audience tự khai là trẻ em. Thêm `coppaUmpMismatchWarning()`
  (pure + static, cùng hợp đồng `consentFootgunWarning`).
- **Fix (MINOR)**: doc comment liệt UMP form + ATT prompt vào "NOT handled
  by SDK, dùng package `umpsdk`" — package đó không tồn tại, và cả 2 thực
  ra ĐÃ được SDK tự triển khai (`requestUmpConsent()`/`requestAtt()`).
- **Tính năng mới**: `CcpaOptOutToggle` — widget "Do Not Sell or Share My
  Personal Information" cho CCPA/CPRA (Cal. Civ. Code §1798.135), vốn yêu
  cầu là lựa chọn end-user thực thi được, không phải hằng số dev hardcode
  như `consent_dialog.dart`'s binary dialog vẫn đúng khi giữ nguyên cho
  COPPA/GDPR. Thêm `AdManager().setDoNotSell(bool)`/`.doNotSell` (máy móc
  đã có sẵn từ trước — `AdConsent.doNotSell` đã flow đúng tới cả 2
  provider + persistence; chỉ thiếu entry point tiện lợi + UI thật).

**Example app (`example/lib/main.dart`) — lần đầu có ai đọc riêng qua 31 round:**

- **Fix (MAJOR)**: `mrecId` dùng chung ad-unit-id Native Advanced với
  `nativeId` — MREC thực ra chỉ là banner ở size khác, phải dùng Banner
  test ID. Trang demo MREC không load được creative test khi build với
  `AD_PROVIDER_ADMOB=true` (chính path CI dùng).
- **Fix (MAJOR)**: `AdMobConfig` thiếu `rewardedInterstitialId` — trang
  demo riêng (round-27 làm để đóng coverage gap cho định dạng AdMob-only
  này) không bao giờ có thể show ad thật; test integration hiểu nhầm kết
  quả "chắc chắn fail" thành "flaky do fill/timing".
- **Fix (MAJOR)**: `AppOpenDemoPage` (StatelessWidget) dùng `context` sau
  callback bất đồng bộ (`loadAppOpenAd`) không check `context.mounted` —
  mọi chỗ khác trong cùng file đều có guard này, đây là code mẫu dễ bị
  app khác copy nguyên lỗi.

## [2.9.10] - 2026-09-02

Round 30 — lấp 2 khoảng trống round 29 chưa đọc: `lib/src/utils/` (nền
persistence) và `lib/src/config/` + `applovin_bridge.dart` (cấu hình +
lớp gọi native AppLovin thật). 2 agent đọc hết, không diff, tìm 4 MAJOR
thật. Mọi fix RED→GREEN mutation-verified.

- **Fix (MAJOR)**: AppLovin test-device registration (`setTestDeviceAdvertisingIds`)
  was called AFTER `_bridge.initialize()` — verified against the real
  `applovin_max` 4.6.4 native plugin source (Android/iOS) that the field is
  only ever read once, inside `initialize()` itself, then nilled. The
  developer/QA device was never actually registered as a test device on
  AppLovin. Reordered to match the consent-flags pattern right above it
  (MJ1).
- **Fix (MAJOR)**: `refreshRemoteSafetyParams()` merged remote overrides
  onto the raw `config.safety` instead of the ramp-adjusted
  `effectiveSafety`, silently reverting every field a `safetyRampSchedule`
  stage had adjusted back to day-0 config on every refresh. Factored out a
  shared `_rampAdjustedSafety()` used by both `initialize()` and refresh.
- **Fix (MAJOR)**: remote safety overrides had no upper bound — only
  `dryRun` was guarded against a safety-defeating payload. A remote config
  could set `minTimeBetweenFullscreenAds: 0` (kills the anti-fraud
  throttle) or any cap field to an arbitrarily large number (functionally
  unlimited ads). Added sane min/max bounds per field.
- **Fix (MINOR)**, same file: `posInt()` required `v is int` exactly,
  unlike `unitDouble()`'s more permissive `is num` — a remote-config
  backend emitting `8.0` for a whole-number field was silently dropped.
  Now accepts whole-valued doubles.
- **Fix (MAJOR)**: `AdPreferences.getInstance()` checked its cached
  singleton only before its internal `await`, never after — two concurrent
  callers before the singleton was first set each built a separate
  instance with independently-diverging mutable state (verified with a
  throwaway reproduction: a fill-rate baseline sample silently dropped).
  Switched to a `Completer`-based guard, mirroring what
  `SharedPreferences.getInstance()` itself already does.
- Doc-only: `async_epoch.dart`'s class comment claimed zero production
  usages; `AdLoadingDialog` has used it since T115.

1515/1515 tests pass, analyze clean. See
`doc/audit/audit_round30_deep_consolidated.md` for the full writeup,
including one agent-reported "dead code" nit that turned out to be a false
positive on re-verification (a grep that missed `test/`).

## [2.9.9] - 2026-09-02

Round-29 follow-up — closes the one gap 2.9.8 deferred: AppLovin's half of
the cross-cycle late-callback fix (AdMob's half shipped in 2.9.8).

- **Fix (MAJOR)**: AppLovin wires one persistent listener per ad type at
  `initialize()` (not a fresh closure per `show()` call like AdMob), so it
  had no way to tell a stale cycle's late native event apart from the
  current one. Added `_interstitialAd`/`_rewardedAd` ad-identity tracking —
  every show-lifecycle callback (`onAdDisplayedCallback`,
  `onAdDisplayFailedCallback`, `onAdHiddenCallback`,
  `onAdReceivedRewardCallback`) now `identical()`-checks the `MaxAd` it was
  handed before mutating the slot or resolving the caller. A stale/late
  event is discarded instead of stealing a newer cycle's caller or, worse,
  silently dropping an earned reward.
- 2.9.8 attempted this and reverted it — the identity check broke 14+
  existing tests in `test/applovin_adapter_test.dart` because its `_fakeAd()`
  helper created a fresh `MaxAd` per call instead of reusing one instance
  across load→show→hide (unlike the real AppLovin SDK, which keeps one ad
  object alive for that whole lifecycle). Fixed properly this time: updated
  every affected test to thread the loaded ad's actual reference through,
  which is also more realistic test modeling than before. Two new tests
  added (`round-29 audit follow-up`) mutation-verified the fix itself
  (RED→GREEN).
- 1505/1505 tests pass, analyze clean.

## [2.9.8] - 2026-09-01

Round-29 audit — user pushback that round 28 (and the 27 before it) were
"too rushed" and diffed only since the last round instead of re-reading
each subsystem from scratch. This round did that: 6 agents each read one
whole subsystem end-to-end with no baseline assumed, found 6x the real
issues round 28 did. All RED→GREEN mutation-verified; see
`doc/audit/audit_round29_deep_consolidated.md` for the full writeup.

**BLOCKER (availability — the SDK could wedge part or all of itself):**
- `showRewardedAd()`'s two native platform-channel calls
  (`_loadRewardedOnDemand`, `ad.showRewarded()`) had no try/catch — a throw
  left `_rewardedInFlight` stuck `true` forever, permanently blocking every
  future rewarded show (including the VIP watch-to-extend flow).
- `AdManager._disposeAdapter()`'s `await old.dispose()` had no `.timeout()`,
  unlike its two sibling awaits in the same teardown (round-27 fix) — a
  hung native `dispose()` call meant `destroy()` never returned and every
  later `initialize()` waited on it forever.
- AppLovin's fullscreen load callbacks (App Open/Interstitial/Rewarded)
  never got round-27's AdMob-only `_fullscreenDisposed` guard — a load
  landing after `dispose()` still mutated a slot on an abandoned adapter.

**MAJOR:**
- `ConsentManager.reset()` reset to `ConsentSettings.unset`, silently
  clobbering `isAgeRestrictedUser` (COPPA)/`doNotSell` (CCPA) — both
  app-level flags, not per-user answers — contradicting its own doc
  comment, which claimed no provider side-effect.
- The rapid-resume rate limiter `.clear()`ed its own rolling window on
  trip, so it only ever blocked the (N+1)th resume of a burst before
  resetting to zero instead of enforcing a real N/60s cap.
- AdMob's adaptive banner computed its width once at first mount;
  rotation/resize/foldable-unfold never re-triggered a reload at the new
  width.
- `AdaptiveAdSurface`'s resize debounce only checked `fullscreenBusy` when
  armed, not when it fired — a fullscreen ad starting mid-debounce still
  let the format swap underneath it, contradicting the class's own doc
  comment.
- AdMob banner/MREC route-away only hid the widget (no pause API exists on
  the Flutter plugin) — the cached native ad kept refreshing while
  invisible. Now torn down on route-away and reloaded on return, matching
  what "paused" actually means for AppLovin's side.
- Cross-cycle late-callback races (AdMob only this round — see below) in
  Interstitial/Rewarded/RewardedInterstitial: a stale cycle's late
  dismiss/fail could steal a newer cycle's caller or, worse, silently drop
  a genuinely-earned reward. App Open's existing guard was reviewed and
  left as `== null` (correct for its case — see the source comment for why
  a stricter check regressed a real test).
  - **AppLovin side not fixed this round** — it uses one persistent
    listener per ad type (wired at `initialize()`), not a fresh closure per
    `show()` call, so the fix needs ad-identity tracking rather than a
    local flag. Attempted, reverted: it broke 14+ existing tests whose
    `_fakeAd()` helper creates a fresh `MaxAd` per call rather than sharing
    one instance across load→show→hide, which a real device does. Tracked
    as a follow-up requiring that test-suite convention to change first.

**MINOR:**
- Custom consent dialog: `barrierDismissible: false` never blocked the
  Android back button/gesture (only the tap-outside barrier) — added
  `PopScope`.
- VIP redeem key field had no `maxLength` — a huge paste ran Ed25519/
  SHA-512 (pure-Dart) on the UI isolate unbounded. Capped at 512.
- `TopToast._animateOut`'s `await ctrl.reverse()` could hang forever if
  `dispose()` ran mid-reverse (a superseding toast) — `Ticker.dispose()`
  only completes `.orCancel`'s completer, not a plain await's. Switched to
  `.reverse().orCancel` + catch.
- `NativeAdWidget` never retried after a load failure (unlike Banner/Mrec,
  which get a fresh shot via consent/personalisation/initRevision events)
  — added a 30s backoff retry.
- `GmaShowCallbacks.onImpression` was wired at the bridge layer but no
  adapter call site ever passed it — finished the wiring, added the
  matching `AdImpressionEvent` (mirrors `AdClickEvent`).
- README never warned integrators about AdMob's ad-placement policy
  (banner/interstitial near tappable controls risks invalid-traffic
  enforcement) — the SDK can't enforce this itself, so it's now at least
  documented.
- Custom consent dialog: Reject button got `flex: 1` vs Allow's `flex: 2`
  (half the width) on top of its own ghost styling — equal width now.
  Cosmetic only; this dialog isn't the actual EEA-compliance surface
  (Google's own UMP form is, and it's unstyled by this SDK).

## [2.9.7] - 2026-09-01

Round-28 audit fix — the one new MAJOR found (only 1 of 3 independent
reviewers caught it; verified against source before fixing):

- **Fix (MAJOR)**: `showModalBottomSheet` defaults to
  `useRootNavigator: false`, unlike `showDialog`'s `true`. In an app with
  nested Navigators (bottom-nav tabs, a `go_router` `ShellRoute` branch), a
  plain `showModalBottomSheet` call pushes onto the nested Navigator, which
  `AdScreenRouteLogger` (registered on the root Navigator per the integration
  contract) never observes — `isDialogOnTop` stays `false`, so a resumed App
  Open ad could show on top of the bottom sheet. Added
  `showAdSafeModalBottomSheet` (`lib/src/core/ad_route_observer.dart`), a
  drop-in wrapper that always forces `useRootNavigator: true`. Documented in
  README's integration contract section and the App Open/modal caveat.
  Mutation-verified: `test/ad_route_observer_test.dart` builds a nested
  Navigator with only the root one observed, confirms a plain
  `showModalBottomSheet` call is invisible to `isDialogOnTop` (the bug) and
  `showAdSafeModalBottomSheet` is visible (the fix).

## [2.9.6] - 2026-09-01

Round-27 audit follow-through — the 2 MAJORs the round-26 audit deferred are
now fixed, plus the example app's ad-surface coverage gap it and `agy`
independently flagged is closed:

- **Fix (MAJOR, round 26 finding #1)**: `RedeemedKeyLedger.markRedeemed()`
  read-modify-wrote the iOS Keychain with no serialization — two
  near-simultaneous signed-VIP-key redemptions could both read the same
  pre-write snapshot, then race to write, silently dropping one `kid` from
  the durable one-time-use ledger. Now chains every write onto the previous
  one (same idiom as `AdEventLog._persistChain`). Mutation-verified: new
  test in `test/redeemed_key_ledger_test.dart` fires two concurrent
  redemptions against a mock storage that snapshots its pre-delay state, and
  asserts both kids land (revert → red, drops one kid; fix → green).
- **Fix (MAJOR, round 26 finding #2)**: `AdMobAdapter`'s `onFailed` branch
  for all 4 fullscreen ad types (app open, interstitial, rewarded, rewarded
  interstitial) had no `_discardIfDisposed`-equivalent guard, unlike
  `onLoaded`. A load failure delivered after `dispose()` still mutated slot
  state and emitted through `eventSink`. Added the same `_fullscreenDisposed`
  check to all 4, and `dispose()` now also nulls `eventSink` last as a
  second line of defense. Mutation-verified: new test group in
  `test/admob_adapter_test.dart` (one case per ad type) using a bridge that
  can defer its `onFailed` callback past `dispose()`.
- **Add**: `showRewardedInterstitialAd()` had zero example-app coverage at
  any level despite being a fully supported, README-documented ad surface —
  found independently by both `agy`'s round-27 audit and a direct grep
  (`0 matches` for `RewardedInterstitial` anywhere in `example/lib/`).
  Added `RewardedInterstitialDemoPage` (home-list tile, same pattern as the
  other demos), a widget test (`example/test/rewarded_interstitial_demo_page_test.dart`),
  and an on-device integration test
  (`example/integration_test/rewarded_interstitial_ad_test.dart`) verified
  passing on an Android emulator.
- **Refactor**: `example/lib/main.dart` — merged the 18 files T117 (2.7.0)
  split it into back into one file. Reason: pub.dev's "Example" tab renders
  only the example app's entry-point `.dart` file, not files it
  imports/exports, so post-T117 a pub.dev visitor evaluating the package
  before installing it only saw a ~90-line stub of import/export statements
  instead of any of the 18 real demos — confirmed by fetching the live
  pub.dev Example tab directly. The T117 split remains the right call for
  day-to-day editing in isolation; kept as one file anyway because pub.dev
  presentation was judged more important here. No behavior change — verified
  by `flutter analyze`/`flutter test` (both packages) passing unchanged
  before/after the merge.

## [2.9.5] - 2026-09-01

- **Fix (audit round 27, MAJOR)**: `AdManager.destroy()`'s `await
  _eventLog?.flush()` (added in 2.9.4 for T102) had no timeout, unlike every
  other bounded teardown wait in the same method (`_eventStream.close()`,
  the fullscreen-show drain). A stuck platform-channel `SharedPreferences`
  write would have hung `destroy()` forever and parked every subsequent
  `initialize()` behind it via `_destroyInFlight`. Now wrapped in the same
  2s timeout pattern as the adjacent waits — on timeout, teardown continues
  and logs a warning instead of hanging. Found independently by 3 reviewers
  (`codex`, `agy`, `claude`) in the same audit round; see
  `doc/audit/audit_round27_consolidated.md`. Mutation-verified: a new test
  in `test/destroy_awaits_event_log_flush_test.dart` (revert → 10s hang
  and red assertion, fix → green in <3s).
- **Fix (test-only)**: `example/test/home_page_test.dart` asserted 17
  `DemoTile`s; the 2.9.1 Adaptive Surface demo (T124) brought the count to
  18 and the test wasn't updated. Found by `agy` in the round-27 audit.

## [2.9.4] - 2026-09-01

- **Fix (T102, finally closed after 3 rounds)**: `AdManager.destroy()` now
  awaits the event log's flush before nulling it, closing a
  destroy()→initialize() race that could silently lose queued compliance
  events. The fix itself was correct on the first attempt; what took 3
  rounds was a `flutter test` hang the fix exposed — root cause was a *test*
  bug (`ad_manager_core_test.dart`'s remote-safety-provider timeout test
  mixed `fakeAsync` with real platform-channel work, leaving an orphaned
  tail running in real wall-clock time after the test's virtual zone
  closed; `unawaited(...)` used to hide it, `await` exposed it), not a
  production bug. Fixed the test to use real time instead of `fakeAsync` for
  that scenario. Mutation-verified with a new AdManager-level test
  (`test/destroy_awaits_event_log_flush_test.dart`).

## [2.9.3] - 2026-09-01

T115 (`doc/task/done/T115-standardize-async-cancellation-primitive.md`):
`AdLoadingDialog`'s ad-hoc `_generation` int counter (the stranded-dialog
guard) is now the first production use of the `AsyncEpoch` primitive built
in round-27 batch D. Internal representation change only — no observable
behaviour change, confirmed by the existing "stranded-dialog fix" test group
passing unmodified. The rest of the SDK's generation/bool-disposed/Timer
idioms (`ad_manager.dart`, both adapters, UMP, VIP, splash) are deliberately
NOT touched — those are individually risky migrations on files already
audited 26+ rounds, left for dedicated follow-up tickets.

## [2.9.2] - 2026-09-01

- **Fix**: `ComplianceReport.redacted()` only nulled out a redacted field's
  value, leaving the key present (`{'consentCountry': null, ...}`). A profile
  is meant to strip the field entirely — a null value still tells whoever
  reads the exported report that the SDK tracks that field at all. Now the
  key is removed. Caught by a real-device integration test
  (`example/integration_test/compliance_redaction_test.dart`, built while
  QA-hardening the round-27 features) that a unit test alone hadn't exercised
  against a real, device-generated `AdEventLog`.

## [2.9.1] - 2026-09-01

QA pass on the round-27 features added in 2.5.0-2.9.0: added example demos
for the ones with a UI surface, plus a widget test for a real gap that pass
turned up.

- **Fix**: `AdScreenState.buildBanner()`/`buildMrec()`/`buildNative()` — the
  helper the README documents as the standard `AdScreen` integration
  path — never accepted a `placement` parameter, even after T107 added
  `placement` to `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` directly.
  Any host following the documented pattern instead of instantiating the
  widgets by hand had no way to reach it — every per-placement stat/cap
  silently stayed on `AdPlacement.unspecified`. All three helpers now take
  an optional `placement` (default unchanged) and forward it.
- Example app: added a live demo for `AdManager().stateSnapshot` (T109) to
  the Slot state panel, a "Preview outcome (no device call)" button using
  `simulateConsentOutcome()` (T120) to the Consent/GDPR demo, and a new
  Adaptive surface demo page (T124) with a width slider.

## [2.9.0] - 2026-08-31

Round-27 batch E (final batch of the round-27 backlog) — 4 done, 1
investigated and correctly not attempted.

- **New**: `AdSafetyParams.maxSameNetworkShowsPerWindow`/
  `networkFatigueWindowMs` — a creative/network fatigue guard. If one
  mediated network keeps winning the waterfall for a format inside a
  rolling window, that format cools down instead of continuing to serve a
  possibly-stale/low-quality network back to back. Fail-open by design: a
  format nothing has ever reported network metadata for is never blocked.
  Off by default (999 in the `debug` preset, same as every other cap).
- **New**: `SelfHealingObserver` (opt-in via
  `AdManager().enableSelfHealingObserver`) — flagship self-healing runtime,
  **observe-only** prototype. Reuses `WaterfallTuner`'s fill-rate×eCPM
  scoring to emit `AdSelfHealingObserveEvent` onto `events` the first time a
  format's trailing data recommends the other provider. Never switches
  anything itself — full auto-act needs both adapters alive in the same
  session, a real architecture change left for a dedicated follow-up.
- **New**: `AdManager().bypassAuditTrail` (always on) + `callSiteTag`
  parameter on `showAppOpenAd`/`showRewardedAd` — flagship
  proof-of-compliance. Every real `bypassSafety`/`bypassVipGuard` call is
  recorded and exportable as an Ed25519-signed bundle
  (`exportSignedBypassAuditTrail()`, verify with
  `tool/bypass_audit_replay.dart`), reusing the same on-device signing
  infrastructure as the compliance report (T96) and incident bundle (T125).
- **New**: `MonetizationDigitalTwin` (`AdManager().buildMonetizationDigitalTwin()`)
  — flagship Monetization Digital Twin, **v0, deliberately rescoped** to one
  policy axis (`maxFullscreenAdsPerDay`) instead of the full ticket's five.
  Deterministic, read-only replay over existing `AdEventLog` history —
  forecasts daily impressions/revenue under a hypothetical daily cap. The
  other four axes (retry, provider split, VIP duration, preload) would each
  require re-implementing `AdSafetyConfig`'s live decision logic as a
  second, pure, replayable copy — real XL risk, left as follow-up tickets.
- **Investigated, not implemented**: a VIP device-transfer token signed
  with the on-device compliance-signing key, as the backlog originally
  described it, is **forgeable** — that key is randomly generated per
  install with no shared root of trust between devices, so anyone could
  self-sign an arbitrary "days remaining" token that verifies against its
  own embedded public key. Also found that most of the underlying need
  already works today: `AVP2` signed VIP keys are redeemed against a
  purely local, per-device ledger, so a still-valid key STRING already
  redeems again on a fresh install with zero new code — the real gap is a
  missing UX affordance (an API to look up a still-valid VIP entry's
  original key string to copy before switching devices), not a new signing
  scheme. Left open with the full reasoning in
  `doc/task/todo/T130-flagship-vip-device-transfer-token.md` pending a
  decision on the correct (much smaller) fix.

## [2.8.0] - 2026-08-31

Round-27 batch D — 3 new opt-in features, 1 primitive built (not yet
migrated anywhere), 1 refactor investigated and correctly not attempted.

- **New**: `WaterfallTuner` (T122) — opt-in local fill-rate/eCPM scorer per
  (provider, format, placement), `AdManager().enableWaterfallTuner(...)`.
  Recommends a provider for the host's *next* session; never auto-switches,
  never loads a shadow ad.
- **New**: `JourneyPrefetcher` (T123) — opt-in smart prefetch,
  `AdManager().enableJourneyPrefetcher(...)`. Host calls `notifySignal(signal,
  type)` at journey points that typically precede a fullscreen ad; learns a
  rolling time-to-show average and stops preloading eagerly once a signal's
  average lead time exceeds `maxHoldDuration`. Bypasses no gate — calls the
  same public `loadX()` a host could call directly.
- **New**: `AdaptiveAdSurface` widget (T124) — picks between banner and MREC
  by available width (debounced, freezes while a fullscreen ad is busy).
  Native intentionally excluded from auto-selection — its content is
  host-authored, so width alone isn't a sufficient signal.
- **Internal**: `AsyncEpoch` primitive (T115) — the generation/dispose/
  invalidate primitive several subsystems could eventually share. Built and
  tested on its own; deliberately NOT wired into any existing call site yet
  (`ad_manager.dart`, both adapters, UMP, VIP manager, splash controller,
  loading dialog) — each migration is its own risky change on files audited
  26+ rounds, left for dedicated follow-up tickets.
- **Investigated, not done**: unifying banner/MREC/native lifecycle across
  the two adapters (T114) — read the actual duplication first: 30+ touch
  points per format, several wrapping identity-check guards inside the
  load/callback path itself (the exact logic 26 rounds of audit tuned). Not
  safely refactorable as a single indivisible pass; left open with a
  per-format migration path suggested for next time.

## [2.7.0] - 2026-08-31

Round-27 batch C — five more tickets from `doc/task/BACKLOG-sdk-2026-08-31.md`
(T116, T106, T108, T117, T125), each with new tests:

- **New**: shared adapter contract-test suite (T116) — `test/adapter_contract_test.dart`
  runs the same scenario matrix (consent epoch, show mutex, dispose, late
  callback after dispose, revenue, App Open watchdog, N-instance banner
  slots) against both `AdMobAdapter` and `AppLovinAdapter`. Test-only; no
  production code changed.
- **New**: `bootstrap(AdBootstrapOptions)` (T106) — sequences
  `requestAtt() → requestUmpConsent() → initialize()` in the one order the
  README already documented doing by hand, returning
  `AdBootstrapResult { att, ump, initSuccess, gaid }`. Non-breaking: the
  lower-level calls are unchanged, `bootstrap()` only wraps them.
- **New**: `AdRetryPolicy` (T108) — optional per-slot retry policy layered on
  `Backoff` (now exported): `isRetryable(errorCode)` to stop retrying
  dead-end errors, stable per-failure jitter, and
  `resetOnConnectivityRestored` so a network-outage failure doesn't wait out
  a backoff computed while offline. Defaults to `null` everywhere — no
  behavior change unless a host opts a slot in via
  `AdManager().adapter?.interstitialSlot.retryPolicy = ...`.
- **New**: `IncidentRecorder`/`IncidentBundle` (T125) — a small bounded ring
  buffer of state-transition snapshots (distinct from the existing 5000-entry
  `AdEventLog`), exportable as an Ed25519-signed bundle (reusing the same
  on-device key as `exportSignedComplianceReport()`) and replayable fully
  locally via `dart run tool/incident_replay.dart <path>`.
- **Chore**: `example/lib/main.dart` (T117) split from ~2729 lines into
  `config/`, `bootstrap/`, `shared/`, and one `demos/*.dart` file per format
  (16 files) — `main.dart` now only holds `main()` plus a barrel `export` of
  every split file, so nothing under `example/test/` or
  `example/integration_test/` needed changes.

## [2.6.0] - 2026-08-31

Round-27 batch B — five more enhancement/idea tickets from
`doc/task/BACKLOG-sdk-2026-08-31.md`, each with new tests:

- **New**: `AdManager().refreshRemoteSafetyParams()` (T111) — re-fetches and
  applies `RemoteAdSafetyProvider` params on demand, mirroring
  `refreshRevocationList()`'s already-established fail-open pattern, instead
  of requiring a full `destroy()`+`initialize()` cycle to pick up a remote
  config change.
- **New**: `AdConfig.safetyRampSchedule` (T121) — an optional, fully local
  (no network) `Map<Duration, AdSafetyParams>` keyed by install age (e.g.
  D0/D3/D7/D30), letting an app ramp caps up gradually without any
  backend. Applied before `remoteSafetyProvider`, so a remote override
  always wins if both are configured.
- **New**: `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` (T107) now accept
  an optional `placement` constructor parameter (default
  `AdPlacement.unspecified`, not a breaking change) — the `AdClickEvent`
  each widget emits on an AppLovin click now carries it instead of always
  reporting `unspecified`.
- **New**: `AdManager().stateSnapshot` (T109) — one
  `ValueListenable<AdSdkStateSnapshot>` combining
  isInitialised/canRequestAds/isOffline/isVipActive/fullscreenBusy, coalesced
  onto a microtask, instead of hand-wiring five separate notifiers.
- **New**: `FakeAdProviderAdapter` (T118) — a fully offline
  `AdProviderAdapter` implementation (no network, no ad-unit ID) for
  CI/demo/App-Store-review builds, wired in via the existing
  `AdManager.debugAdapterFactory` seam. Renders an unmistakably-fake
  placeholder for banner/MREC/native instead of silently rendering nothing.

## [2.5.0] - 2026-08-31

Round-27 roadmap, batch A (`doc/task/BACKLOG-sdk-2026-08-31.md`) — five
enhancement/idea tickets, all purely additive (new optional params, new
methods, new classes), no breaking changes:

- **New**: `AdSafetyParams.maxPerPlacementAdsPerDayById` (T113) —
  `Map<String, int>?` keyed by `AdPlacement.id`, alongside the existing
  `maxPerPlacementAdsPerDay: Map<AdPlacement, int>?`. Unlike that field, this
  one can be used inside a `const AdSafetyParams(...)` declaration (`String`
  has primitive equality; `AdPlacement`, which overrides `==`, does not).
- **New**: `MonetizationArbitrator(fillRateBaselineMonitor: ...)` (T112) —
  opt-in; when passed, an active `FillRateBaselineMonitor` regression alert
  for a slot is an additional veto signal in `decide()`, still subject to the
  same `vetoRate` guardrail. `null` (the default) is byte-for-byte unchanged.
- **New**: `ReportRedactionProfile` + `ComplianceReport.redacted(profile)`
  (T110) — `fullLocal` (no-op) and `supportSafe` (strips `consentCountry` and
  `placement` from every event entry) built in, or construct a custom
  profile with any `Set<String>` of event fields. `ComplianceReport` also
  gained `schemaVersion` in `toJson()`.
- **New**: `AdManager().explainLastSkip(AdSlotType)` (T119) — human-readable
  answer to "why isn't this ad showing?", reading the same `AdSkipEvent` data
  already emitted on `AdManager().events` (T77). `null` if nothing has been
  skipped for that slot yet this session.
- **New**: `simulateConsentOutcome(AdConsent, {AdConfig?})` +
  `ConsentSimulationResult` (T120) — pure, side-effect-free preview of what
  `applyConsentToProviders` would send to AdMob/AppLovin for a hypothetical
  consent combination, with zero platform-channel calls. Both now share one
  internal decision function, so the simulation can't drift from the real
  apply path.

## [2.4.5] - 2026-08-31

Round-27 continued: T103, T104, T105 (`doc/task/BACKLOG-sdk-2026-08-31.md`,
bugs B8/B9/B10). Each mutation-verified.

- **Fix (T103)**: the example app's own splash screen (`example/lib/main.dart`)
  used a `ValueNotifier<bool>` purely as a guard flag — nothing ever listened
  to it. A native ad-load callback arriving after the splash widget's own
  `dispose()` still wrote to it, throwing "A ValueNotifier was used after
  being disposed." Replaced with a plain `bool`, set `true` as the very first
  line of `dispose()` — a plain field is always safe to read/write regardless
  of widget lifecycle, closing the whole bug class rather than one race
  window in it.
- **Fix (T104)**: `AppLovinAdapter._disposedNativeKeys` (a tombstone `Set`
  guarding against a late native-ad callback resurrecting a disposed
  instance) never shrank — a screen scrolling many native ads through a
  long-lived `ListView` leaked one entry per ad that scrolled away and was
  never revived. Now a `LinkedHashSet` bounded at 200 entries, evicting the
  oldest tombstone once exceeded.
- **Fix (T105)**: `onAdOpened`/`onAdClicked` (AdMob banner/MREC/native) had no
  identity guard at all, unlike `onAdLoaded`/`onAdFailedToLoad` (round-26 #2
  only fixed the latter). A click landing after `disposeXInstance()` still
  counted against CTR-fraud tracking and emitted an `AdClickEvent` for a
  placement that no longer existed. Also nulled `AppLovinAdapter.eventSink` in
  `dispose()` — its bridge listeners are nulled there too, but a callback
  already queued at that instant still runs on its old closure and still
  reaches `_emit`, which reads `eventSink` at call time.

## [2.4.4] - 2026-08-31

Round-27 continued: T101 (`doc/task/BACKLOG-sdk-2026-08-31.md`, bug B2).

- **Fix**: `AdPreferences.recordFillRateBaselineSample()` wrote without any
  ordering guarantee — two samples fired close together (e.g. a load event
  immediately followed by a revenue event) could both read the same on-disk
  snapshot, and whichever write landed last silently discarded the other's
  delta. `FillRateBaselineMonitor`'s 7-day regression detector (T97) could
  therefore under-report or mis-time an alert. Writes are now chained
  (`_fillRateBaselineChain`), the same idiom `AdEventLog._persistChain`
  already used for the identical class of bug. Mutation-verified.

T102 (bug B3, `_eventLog.flush()` not awaited before `destroy()` nulls it)
was investigated and a fix attempted: changing `unawaited(...)` to a bare
`await` closes the race but makes `flutter test` hang indefinitely on
`ad_manager_core_test.dart` — some existing test/scenario there leaves the
event log's persist chain waiting on a write that never resolves. Reverted;
the ticket stays open (`doc/task/todo/T102-...md`) with this finding recorded
so the next attempt doesn't re-discover it. A bare `await` is confirmed
unsafe; a version with a bounded timeout was deliberately not implemented
either, since a timeout would mask whichever real bug the hang is exposing
rather than fix it.

## [2.4.3] - 2026-08-31

Round-27: after round-26, three independent reviewers (codex, Gemini, Claude)
read the whole SDK again looking for BUGS, enhancements, tech debt and new
feature ideas beyond what round-26 covered — see `doc/task/BACKLOG-sdk-2026-08-31.md`.
Five of the newly-found bugs are fixed here, each mutation-verified (revert
the fix, watch the new test go red first) except B5 (example-app-only, no
unit test harness for it):

- **Fix (P0)**: `AdManager.pickProviderCohort()`/`experimentBucket()` collapsed
  every install into the SAME bucket when called in the exact order their own
  docstring requires — before `initialize()`. `AdPreferences` hadn't
  bootstrapped yet and the device GAID hadn't been fetched yet, so the
  install id used to hash the bucket silently fell back to an empty string
  for every device. The A/B provider-split feature (`pickProviderCohort`) was
  a no-op for any host following the documented call order. Now mints a
  random id in memory the first time it's needed pre-bootstrap (stable for
  the life of the process) and hands it to `AdPreferences` to persist once it
  bootstraps, so it's the SAME id — not a second random one — that becomes
  stable across future launches too. Both functions stay synchronous; no
  signature change.
- **Fix**: `installAdCrashGuard()` wasn't idempotent — a repeated
  `initialize()` in one process (provider switch, logout/login) stacked
  another closure layer around `FlutterError.onError`/
  `PlatformDispatcher.onError` on top of the last one every time, so a crash
  got handled N times and the old closure chain never got collected. Now
  tracks the identity of the handler it last installed and no-ops only when
  that handler is still in place.
- **Fix**: a scheduled consent-dialog `Timer` and its re-scheduling guard
  flag were only cleaned up inside `destroy()`. A host calling `initialize()`
  again WITHOUT `destroy()` first (a documented, supported "auto-disposing
  previous" path) reached none of that cleanup, leaving a stale Timer
  (capturing the OLD `AdConfig`/`ConsentManager`) alive into the new session.
  Moved into `_resetGuardState()`, the one function both entry points already
  share for exactly this class of bug.
- **Fix**: `TopToast` — an older toast's own delayed dismiss (fired late,
  right after a newer toast replaced it) could remove the newer toast instead
  of itself, since both shared one static dismiss callback. The delayed
  dismiss is now a cancellable `Timer` (cancelled on dispose) and dismissal
  is scoped by identity — a toast can only ever remove itself, never
  whichever one happens to be current.
- **Fix (example app)**: `example`'s `EventBuffer` subscribed to
  `AdManager().events` once at startup; `destroy()` closes and replaces that
  stream, so the "Event stream" and "Revenue dashboard" demo pages silently
  stopped updating after using the "Slot state panel" demo's own
  Destroy/Re-initialize buttons. Now re-subscribes on every
  `AdManager().initRevision` change.

No behaviour a host observes through documented, non-internal APIs changes;
nothing here is a breaking change.

## [2.4.2] - 2026-08-31

Round-26 audit, finding #5 — closed on a third attempt after the first two
(closing/reopening `_canRequestAds` directly, then mirroring the round-11
`_pessimisticGateClose`/epoch mechanism) each regressed the existing
consent-gate test suite and were reverted.

- **Fix**: `AdManager.setConsent()`'s tightening path (a GDPR withdrawal, a
  fresh CCPA opt-out) called `applyConsentToProviders()` with the ad gate
  wide open. That function applies to AppLovin synchronously but awaits
  AdMob's `updateRequestConfiguration` — a concurrent load firing in that
  window could go out under AdMob's OLD, more permissive global
  configuration. `canRequestAds` now also checks a new
  `_consentProviderApplyInFlight` flag, set only around that one `await` and
  only for a tightening change. It is deliberately independent of
  `_pessimisticGateClose`/`_consentIntentEpoch` — those solve a different
  problem (a queued apply's not-yet-known outcome) and are untouched by this
  fix, so it cannot interact with round 11-21's recovery machinery.
- Mutation-verified: `test/consent_provider_apply_in_flight_test.dart` (revert
  → red, fix → green), plus the full existing suite (1342 tests) confirmed
  clean, including the exact three tests the first fix attempt broke and the
  thirteen the second attempt broke.

## [2.4.1] - 2026-08-31

Round-26 audit: three independent reviewers (codex, Gemini, Claude) plus a
line-by-line pass of my own, re-verifying the seven production requirements
against the current source and the live pub.dev listing. Consolidated verdict
in `doc/audit/audit_round26_consolidated.md`. Three findings fixed, each
mutation-verified (proven by reverting the fix and watching the new test go
red first):

- **Fix**: `AdManager.destroy()` could tear an adapter's native listeners down
  while a rewarded (or rewarded-interstitial) ad was still on screen. For
  AppLovin specifically, a reward event already in flight from the native SDK
  at that moment landed on a listener that had just been nulled and was
  silently dropped — a user who finished watching a rewarded ad right as
  `destroy()` ran (provider switch, logout, SDK reset) was told they earned
  nothing despite watching the whole thing. `destroy()` now waits up to 5s for
  a showing fullscreen ad to resolve on its own before tearing the adapter
  down; the wait is bounded so a wedged native SDK can never hang `destroy()`.
- **Fix**: the SDK's own post-splash auto-show consent dialog scheduled itself
  via a bare `Future.delayed` with nothing keeping a handle on it. A
  `destroy()` followed by a fresh `initialize()` (a different `AdConfig`, e.g.
  a QA build vs. production) inside that delay window still let the stale
  closure fire and apply the OLD config — including `testDeviceIds` — on top
  of the new session. The delay is now a cancellable `Timer`, cancelled by
  `destroy()`.
- **Fix**: `AdReadinessSplashController.dispose()` didn't mark itself
  navigated. If the splash widget was disposed (app backgrounded and killed
  mid-splash, or the route popped) while an app-open-ad load was still in
  flight, the late callback still ran the host's `onReady` navigation
  callback against an already-deactivated `BuildContext` — "Looking up a
  deactivated widget's ancestor is unsafe."

No behaviour a host observes through documented, non-internal APIs changes;
nothing here is a breaking change.

One additional finding (a narrow timing gap between AdMob and AppLovin
receiving a tightened consent decision through the SDK's *built-in* consent
dialog — the UMP path was already hardened against this in round 21/22) was
investigated and a fix attempted twice; both attempts regressed the existing
consent-gate recovery test suite and were reverted. It remains open, tracked
in `doc/audit/audit_round26_consolidated.md`, and only matters if you enable
`autoShowConsentDialog` for an EEA audience at scale.

## [2.4.0] - 2026-08-29

Round-23 audit: a full pass over the SDK, the example app, every doc in the
package and the live pub.dev listing, against the seven production
requirements. Three independent reviewers plus a line-by-line pass of my own,
then a second review round on the changes themselves; every finding was
re-verified against the source before being accepted (several were downgraded
or refuted). Consolidated verdict in
`doc/audit/audit_round23_consolidated.md`.

### ⚠️ Behaviour changes — read before upgrading

Nothing here changes a signature, so this compiles as a drop-in upgrade. Two
values that a host can *read* now mean something different, which is why this
is a minor bump and not a patch:

- **`RewardResult.shown` now means "the native SDK confirmed the ad reached the
  screen"**, and defaults to `false`. It used to default to `true` on every
  path, including the ones where no ad was ever displayed. If your app reads
  the `shown` argument of `showRewardedInterstitialAd(onDone: (shown, earned))`,
  re-check what you do with it: it is now the display signal, not a
  "the show attempt happened" signal, and it is `true` for a real display the
  user closed before the reward point.
- **`AdShowEvent.success` for `rewarded` and `rewardedInterstitial` now reports
  the DISPLAY, not the reward.** It used to carry `earned`. If you were
  counting rewards off the event stream, count `AdRewardEvent` instead — that
  is what it is for, and it is unchanged. `AdShowEvent.success` for banner,
  interstitial and app-open is unchanged.

- **`showRewardedInterstitialAd()` now shows a disclosure screen before the ad.**
  Google's policy for the format requires it: the user must be told an ad is
  coming and what the reward is, and be given a way out. `AdScreenState`
  renders one by default — pass `showDisclosure: false` only if your app
  already presents its own, and override `disclosureTitle` /
  `disclosureButtonLabel` to localise it. Declining costs nothing: no ad, no
  impression, no budget spent.

- **`AdRevenueEvent.placement` now reports where the ad was actually shown.**
  Before this release every revenue event arrived as
  `AdPlacement.unspecified`, and App Open always claimed `AdPlacement.splash`
  even on a resume. If you were grouping revenue by placement, the buckets
  change shape — they start being correct. Banner, MREC and native still report
  `unspecified`: nothing "shows" them, so there is no placement to take.

### Fixed

- **A wrong device clock could permanently ERASE a paid VIP grant.** The SDK
  keeps a high-water mark of the furthest instant the clock has ever read, so
  that winding the date backwards cannot resurrect an expired grant. If that
  mark ever got poisoned — a phone with a flat battery boots years in the
  future, the user opens the app once, NTP corrects it later — the expiry sweep
  compared every VIP row against the poisoned mark, decided they were all over,
  and deleted them from disk. Unrecoverable: there is no backend, and the key
  id is already burned in the one-time-use ledger, so re-entering the key the
  customer paid for answered "already used". A row is now deleted only once the
  clamped clock **and** the raw device clock both say its window has *ended* —
  a window that has not STARTED yet (a grant taken while the clock was running
  ahead) is kept too, which matters on iOS where the VIP row is Keychain-backed
  and survives a reinstall while the clock mark does not. A poisoned mark can
  still suppress an entitlement; it can no longer destroy one.

- **One tap on "watch an ad" laundered a revoked key's window past the
  revocation list.** VIP grants stack globally by design, so redeeming a signed
  30-day key and then watching one rewarded ad for "+1 day" moved the whole 30
  days into the `WATCH_AD` entry — where the revocation clamp, which matches on
  `SIGNED_<kid>`, could no longer reach it. Publishing a CRL for a leaked,
  refunded or resold key did nothing. Stacked grants now carry, transitively,
  what they absorbed, and the clamp matches on that too.

- **A cached revocation list verified itself, and a future-dated one could
  switch revocation off forever.** At startup the cached CRL was verified
  against a public key stored beside it in the same plaintext record — self-
  attesting. Anyone able to write app preferences could mint their own key
  pair, sign an empty CRL dated far in the future, write both, and permanently
  wedge the "only accept a newer list" rule against every CRL the publisher
  will ever issue. The cache's `issuedAt` is now latched only once the host's
  own key has confirmed it. The revoked set from an untrusted cache is still
  applied — it can only ever narrow a grant.

- **A child-directed flag set during init never reached AppLovin MAX.** MAX
  reads the flag once, at native SDK init, and that init is awaited for up to
  20 seconds. A host that starts `initialize()` and presents its age gate at
  the same time — the ordinary splash shape — could call
  `setConsent(AdConsent(isAgeRestrictedUser: true))` inside that window and
  have it silently dropped: the adapter had already been told `false`, and
  `setConsent()`'s own re-init branch could not run on a first init. MAX served
  ads to a user the host had declared child-directed. Init now re-checks the
  flag on the way out and discards the adapter if it changed.

- **App Open ads were drawn on top of live banners and MRECs.** Google's App
  Open guidance names this placement as prohibited. The resume path walked
  straight into it: inline surfaces are made visible again on resume, and only
  then does the App Open decide to present. Banners and MRECs are now blanked
  for the duration of the fullscreen ad and restored on dismiss (and after a
  failure). A surface hidden for another reason — route-paused, backgrounded —
  stays hidden. Nothing to call; a custom adapter that does not implement the
  new `InlineAdVisibility` capability keeps the old behaviour.

- **The monetization arbitrator priced every ad format out of one pool.** A
  content feed emitting cheap banner impressions dragged the trailing average
  below the *rewarded* threshold, so the next rewarded opportunity — worth many
  times a banner — was vetoed in favour of a VIP nudge, and the emitted
  `ArbitratorNudgeEvent` quoted an eCPM belonging to a different format. The
  same bug compared non-USD revenue against a threshold documented in dollars.
  Each format is now priced from its own history, in its own currency.

- **A rewarded interstitial that was displayed but dismissed early did not
  consume an impression.** The count sat inside `if (result.earned)`, so
  repeating the pattern handed out materially more fullscreen inventory than
  the anti-invalid-traffic caps allow — the publisher's AdMob account carries
  that risk, not the SDK's. It now counts display, like every other fullscreen
  format, and the matching `AdShowEvent` no longer reports `success: false` for
  an ad that was on screen.

- **An iOS Keychain timeout consumed the 1-day trial the user never got.** The
  first-install guard reads the Keychain to decide whether the grace has
  already been given. If that read never answered, the SDK still marked the
  grace as applied — a one-way flag — so the trial was burned without ever
  being granted. The mark now happens only when the guard actually answers; a
  timeout simply tries again next launch.

- **A whitelisted test device lost VIP after ~90 days and could not get it
  back.** `AdConfig.vipDeviceGaids` grants a long window that the stacking cap
  clamps to ~90 days, then set a one-way "already applied" flag — so when the
  clamped window ran out the device silently went back to seeing ads, with no
  way to re-grant short of clearing app data. The grant is re-applied when the
  whitelist still matches and no VIP is active.

- **Banners stayed blank at the exact moment VIP expired.** Gaining VIP hid
  them immediately; losing it did not bring them back until something else
  happened to rebuild the widget. The VIP transition now signals the banner to
  reload.

- **A CCPA / US-state sale opt-out written by a CMP now actually reaches both
  ad providers.** The SDK has parsed `IABUSPrivacy_String` since 2.3.0 and
  reported it through `AdManager().usPrivacyOptedOut`, but `AdConsent.doNotSell`
  was writable by the host and by nothing else — so a user who opted out through
  a CMP still had AppLovin `setDoNotSell(false)` and AdMob
  `restricted_data_processing` unset unless the host separately noticed the
  string and called `setConsent` itself. The opt-out is now reconciled at SDK
  init and on every app resume (so one made while the app was backgrounded lands
  too), and applied to both providers. Tighten-only: a string that says the user
  did NOT opt out, and the absence of any string, never clear a `doNotSell` the
  host set deliberately. `IABGPP_HDR_GppString` is still deliberately not
  decoded — see the new README section "CCPA / US state privacy".
- **A VIP reward earned while the SDK is re-initialising is no longer lost.** The
  watch-ad-for-VIP flow held the VIP manager it read before showing the ad; a
  provider switch or re-init during the ad discarded that manager, so the grant
  was dropped while the screen still reported success. The grant now goes to
  whichever manager is live when the ad finishes.
- **An SDK teardown can no longer roll back the VIP revocation list.** A
  revocation-list fetch still in flight when the SDK was destroyed used to write
  its (older) result over the newer list the re-initialised SDK had already
  cached, making a revoked key redeemable again on the next launch. The fetch is
  now discarded if the manager that started it has been torn down — including a
  teardown that lands while the fetched list is being applied to existing
  grants.
- **A VIP redeem interrupted by an SDK teardown no longer consumes the key.**
  The one-time-use ledgers were written even when the entitlement itself was
  dropped (a discarded manager must not write over the live one's store), which
  left a paying customer with a burned key and no VIP window — durably on iOS,
  where the replay record survives a reinstall. The key is now marked used only
  once the grant has actually been persisted.
- **A refused native AdView destroy could arm a retry timer that outlived
  `destroy()`.** `destroy()` cancels the retry timers it can see, but a destroy
  still in flight fails afterwards and used to schedule a fresh one, which then
  called into a bridge whose listeners were already cleared. It now stops
  retrying once the teardown has begun; the retry chain is unchanged on a live
  adapter.
- **An AppLovin banner/MREC preload landing during `destroy()` aborted the rest
  of the teardown.** The AdView-destroy loops awaited the native bridge while
  iterating a map that the in-flight preload then inserted into, throwing
  `Concurrent modification during iteration`. The exception was swallowed one
  layer up, so the host saw a successful teardown while MREC views were left
  alive, pending `loadAppOpen`/interstitial/rewarded callbacks were never
  answered, and the old adapter kept its config. Repeated destroy/re-init cycles
  accumulated native views.
- **An AdMob ad delivered after `destroy()` leaked its native ad object.** GMA
  can hand over a fill at any time, including after teardown; the four
  fullscreen load handlers stored that late ad into an adapter that had already
  released everything it held, and since the next `initialize()` builds a fresh
  adapter, nothing ever disposed it. Late fills are now released on arrival.
  Banner/MREC/native were already covered by their per-key identity guard.
- **A valid VIP key was rejected as "invalid or expired" when redeemed in the
  first second after app launch.** The connectivity plugin's first snapshot
  after process start can report offline on a device that is online (seen in 3
  of 36 launches on a real phone), and the redeem gate trusted that single
  read. It now polls for up to 2s and lets the first positive answer through.
  A genuinely offline redemption also stops lying about the cause:
  `SignedVipRedeemResult.isOffline` is set (the `status` stays
  `VipRedeemStatus.invalid`, so no exhaustive `switch` in a host app breaks),
  and the shipped `VipRedeemScreen` shows a new `VipRedeemStrings.offlineMessage`
  ("No internet connection. Connect and try again — your key is still valid.")
  instead of the invalid-key message.
- **An ad load could start during `destroy()`, and its callback could crash the app.**
  The four `loadX` methods now refuse while a teardown is in flight, and an
  `AdSlot`'s state notifier drops (and counts) writes that arrive after it was
  disposed. Before this, a native load callback landing after teardown wrote a
  disposed `ValueNotifier` and threw `A _SlotStateNotifier was used after being
  disposed` — reachable by any app that called `destroy()` while an ad was
  loading. Requests fired during a teardown are also pure waste: never shown,
  but counted by the ad network as a request with no impression.
- **A VIP rewarded ad could play, and pay out, over an SDK being torn down.**
  The teardown check sat at the head of each show method, but the VIP
  "watch an ad to extend your window" path then waits up to 15s for an
  on-demand load, and the re-check after that wait did not know a `destroy()`
  had started meanwhile. The teardown is now part of the shared fullscreen
  busy gate, so every ad type and every post-wait re-check inherits it. The
  public `fullscreenBusy` notifier is recomputed on both edges of a teardown.
- **`AdManager().adapter` returns `null` while a teardown is in flight.**
  The adapter's own `show…` methods are public and answer to none of the
  safety layers in `AdManager`, so a host holding the adapter could drive the
  native layer straight past consent, caps and the fullscreen mutex during a
  teardown. Fetching it mid-teardown now yields nothing to call. (Banner /
  MREC / native widgets read this getter and correctly stop building.)
- **A resume that started just before `destroy()` could still show an ad.**
  Detaching the lifecycle observer stops a *new* resume, not one whose 500ms ad
  buffer was already running — its completion callback found the adapter still
  live and showed an App Open ad on top of an SDK being torn down. No fullscreen
  ad (App Open, interstitial, rewarded, rewarded interstitial) can now start
  while a teardown is in flight; the attempt is reported as a
  `teardown_in_flight` skip event instead.

- **One paused `events` subscriber could hang `destroy()` — and brick the SDK.**
  The teardown awaited the event-stream close with no bound. A host subscription
  may legally be paused (route transition, backpressure), and a paused subscriber
  buffers the done event, so the close never completed — while every later
  `initialize()` parked behind the in-flight teardown and `isInitialised` still
  answered `true`. The wait is now capped at 2s with a warning log.

- **An App Open ad could be shown on top of an SDK being torn down.** The app
  lifecycle observer was detached at the very end of `destroy()`, and the resume
  fallback timer cancelled later still, both after the teardown's awaits — across
  which the adapter and config are untouched, so every guard on the resume path
  still passed. A user returning to the app mid-teardown could be shown an ad,
  with the native call landing on an adapter about to be disposed. Both are now
  disarmed before the teardown's first await.

- **The 5-minute ad-refill poll can no longer fire inside a teardown.** The poll
  guards itself on `isInitialised`, which is `_config != null && _adapter != null`
  — and both fields stay non-null until well past the teardown's first `await`. So
  a tick landing in that window passed every guard and refilled ads into an adapter
  about to be disposed. The poll and the connectivity watch are now both stopped
  before the first await, matching what re-`initialize()` already did.

- **A pending init retry can no longer bring the SDK back after `destroy()`.**
  The retry timer was cancelled at the end of the teardown, so it stayed armed
  across the event-stream close and the adapter dispose. A retry firing in that
  window waited the teardown out and then built a whole new session — adapter,
  timers, connectivity watch and ad requests — moments after the host's
  `await destroy()` returned. The retry is now cancelled before the teardown's
  first await.
- **Two `destroy()` calls at once no longer tear the SDK down twice.** The
  second caller waited for the first teardown and then ran a whole extra one:
  every widget subscribed to `initRevision` rebuilt twice, and if the app had
  already restarted the SDK in between, the redundant teardown disposed the
  *new* session's adapter — ads silently dead for the rest of the process.
- **A cancelled init retry no longer strands the caller it was holding.** When
  native init fails the SDK arms a backed-off retry that owns the caller's
  `onComplete`. Cancelling that retry — which both a fresh `initialize()` and
  `destroy()` do — threw the callback away with the timer, so that caller was
  never answered at all. A splash that tapped its own "Retry" button mid-backoff
  therefore waited out its hard-cap timer even though the SDK had come up. The
  callback is now handed to the replacing attempt (and hears its real result),
  or answered `false` by the teardown.
- **A reported init failure no longer leaves the SDK claiming it is
  initialised.** If a step *after* the ad provider came up threw — applying
  consent to the providers, or reading the stored IAB consent string — the host
  was told initialisation failed while `AdManager().isInitialised` still
  answered `true`, with a live native adapter and its listeners still attached.
  An app that does not re-initialise on failure leaked that adapter for the rest
  of the process, and it kept serving ads. The SDK now tears the adapter down
  before reporting the failure, so the two answers agree — and it does so even
  when the ad provider's own teardown throws, which used to abandon the state
  reset half-way and bring the same contradiction back.
- **`destroy()` now really stops an `initialize()` that is still running.**
  Native SDK init can take up to 20 seconds, and an app that gave up and tore
  the SDK down in the meantime used to have it come back to life afterwards:
  the finishing attempt installed its ad provider, timers and connectivity
  watch into the torn-down SDK and reported success, so `isInitialised` went
  `true` again moments after the app had been told the SDK was gone. Such an
  attempt now releases what it built and reports failure instead. Same for the
  narrower window while consent is being applied to the providers.
- **A parked caller can no longer be stranded** by another parked callback that
  calls `initialize()` again, or by one that throws. A callback that re-enters
  `initialize()` while the queue is being answered is handed the result being
  delivered on the spot instead of parking behind it. The queue is also capped
  at 32 waiting callers (the 33rd is told `false` at once rather than parked),
  and a caller that parks during `destroy()`'s own teardown — a window that had
  already drained the queue — is answered by the abandoned attempt rather than
  waiting for a callback that would never fire.
- **A consent answer from a torn-down session can no longer open the live
  session's ad gate.** The UMP consent flow is not awaited (it presents a native
  form and can take minutes), so its result could land after the app had torn
  the SDK down and initialised it again — and it was written to the ad gate
  regardless. A session that is deliberately holding ads back until its own
  consent flow answers, or that runs a stricter config (an under-age-tagged one,
  say), could therefore be overruled by an answer gathered for a session that no
  longer exists. UMP results and the fail-open error path are now bound to the
  session that started them, matching the privacy-options form.
- **`destroy()` no longer takes a session that started during its teardown apart
  with it.** Tearing the SDK down involves waiting on the ad provider, and an
  `initialize()` arriving in that window used to be built and then dismantled by
  the rest of the teardown — most visibly it lost the app-lifecycle observer, so
  App Open on resume and the ad pause/resume hooks silently stopped working for
  the rest of the process. `initialize()` now waits for an in-flight `destroy()`
  to finish, so a destroy-then-initialise pair does what the app asked, in the
  order it asked.
- **An abandoned `initialize()` can no longer damage the session that replaced
  it.** Two failure paths did not know they had been superseded. One: an attempt
  whose provider init came back `false` after `destroy()` still armed its
  5-second retry timer, so the torn-down SDK re-initialised itself, and still
  fired the init-completion event with `false` — and because the event bus
  replays its most recent event, a splash that subscribed late was told init had
  failed even when a later attempt had succeeded. Two: an attempt that *threw*
  after another attempt had already won decided what to tear down by reading the
  shared state, so it disposed the winner's live provider and flipped
  `isInitialised` back to `false` for a session that never failed. Both now bow
  out and report only to their own caller. Same check added after the VIP load
  and the consent bootstrap, so a `destroy()` during either can no longer leave
  a torn-down SDK holding live VIP or consent state.
- **`SafeLogger.critical` can no longer be hidden by `logTagFilter`.** It
  already ignored `AdLogLevel.none`; it now ignores the tag filter too. The two
  events that use it — a release build forcing `dryRun` back off, and a config
  that can never gather consent — mean your own configuration is wrong, and the
  consent one is the difference between showing an EEA/UK user a consent form
  and not. An app filtering logs down to its own tags used to lose it silently.
  Ordinary `d()`/`w()`/`e()` still respect the filter exactly as before.
- **A second `initialize()` call made while the first is still running is no
  longer answered with silence.** It used to log "skipping duplicate" and
  return without ever calling that caller's `onComplete` or firing an event, so
  an app whose splash awaited the second call waited forever. Such callers are
  now parked and told the real result of the in-flight attempt (and told
  `false` if `destroy()` happens first). They still never start a second ad
  provider.
- **The iOS "you called `initialize()` before `requestAtt()`" warning now
  actually fires under test**, which is how it was found to be untestable in the
  first place: it asked `dart:io` whether the platform is iOS, and now asks
  Flutter. Same answer on a real device.
- **A host `onLog` callback that throws can no longer strand the SDK.** Every
  log now goes through one guarded emitter, so an exception out of your own log
  sink is caught and reported instead of unwinding whatever the SDK was doing —
  which, for logs written from inside a teardown's `catch`, meant the state
  reset stopped half-way.
- **An app that calls `initialize()` again from its own failure callback is no
  longer ignored.** The in-progress guard was still held while `onComplete(false)`
  ran, so a host retrying with a fallback configuration from inside that callback
  was dropped silently: it had been told initialisation failed and its own
  recovery then did nothing.
- **A developer warning no longer silently disables ad loading for the whole
  session (debug/profile builds).** The two `assert`s described below ran ahead
  of the App Open + banner preload, the ad retry timer and the connectivity
  watch. In a non-release build the assert threw and all of those were skipped,
  so ads simply never loaded — a symptom that looks nothing like the warning
  that caused it. Both `assert`s are now **gone**: an assert inside a `try` that
  catches everything can never crash anything, it only produced a stack trace
  the SDK then logged as if init itself had failed. The warnings are now
  `SafeLogger.critical` instead, which reaches your own `onLog` sink and is not
  silenced by `AdLogLevel.none`. The release-mode consent block, and the rule
  that no ad is requested while no consent flow is configured, are unchanged.
- **A splash screen no longer hangs waiting for an init-completion event that
  never comes (debug/profile builds).** The SDK's two developer warnings — no
  consent flow configured, and `requestAtt()` never called on iOS — are
  `assert`s, and they ran *before* `initialize()` told the host it had finished.
  In any non-release build the assert threw, the init body swallowed it, and the
  host callback plus the completion event were skipped even though native init
  had actually succeeded: a splash built on the documented contract (subscribe
  to the init event) sat there until its own hard-cap timer rescued it. The
  warnings now fire after completion is reported, and a host `onComplete` that
  throws can no longer swallow the event either.
- **A failure after native init no longer re-initialises the SDK every 5
  seconds forever.** The auto-retry budget is reset once the adapter comes up,
  so anything throwing after that point — including a host `onComplete`
  callback that throws — got an unbounded retry: rebuild the adapter, throw
  again, reset the budget, retry again. Such a failure is now terminal and
  reported once; a genuinely failed native init keeps the bounded retry it
  always had.
- **Ad impressions are now counted from whether the ad reached the screen, not
  from how the show ended.** Three separate symptoms turned out to be one
  mistake: a rewarded ad the user closed after two seconds, a
  rewarded-interstitial that never displayed, and an app-open ad resolved by
  the 90-second hard cap were all mis-accounted. A real display that earned no
  reward counted as nothing (so the daily/hourly caps that protect the AdMob
  account stopped seeing those impressions), while a show that never reached
  the screen was reported to the host as `shown: true`. There is now one
  authoritative signal, `AdSlot.displayConfirmed`, set when the native SDK
  confirms the ad is on screen, and both adapters plus `AdManager` read it.
- **`RewardResult.shown` now defaults to `false` and means "the native SDK
  confirmed this ad reached the screen"** — independent of `earned`. It used
  to default `true`, so every never-displayed path reported a display.
  Hosts reading `onDone(shown, earned)` get the truth now; a host that treated
  `shown` as "the user watched something" should re-check that assumption.
- **AdMob's app-open slot never called `markDisplayed()`** — the only
  fullscreen slot that didn't, which is why its hard-cap path could not tell a
  real display from a lost callback.
- **A device clock parked in the future can no longer mint a permanent VIP**
  (MJ9, carried as a documented limitation for three rounds). Setting the clock
  a year forward, redeeming any grant, then correcting the clock used to leave
  an entry that never expired, because the anti-rollback high-water mark was
  the only clock consulted and it agreed the entry was mid-window. An entry now
  additionally has to have *started* according to the raw device clock, while
  expiry keeps using the mark — so the 30-day-rollback defence is unchanged.
  A suppressed entry is never deleted, only suppressed, so a customer whose
  device clock was genuinely fast when they paid keeps their grant.
- **VIP grants are persisted as UTC.** They were written as local ISO-8601
  with no timezone marker, so the same text read back on a device that had
  changed zone (a flight west, a region's UTC-offset change) resolved to a
  different instant — up to a day earlier. `VipManager` then read the grant as
  expired and `_purgeExpired()` deleted it, with no server to restore from.
  Entries are stamped UTC on write and converted back to local on read, so
  every existing consumer (display, countdowns, `difference`) is unchanged.
  Entries written by 2.3.4 and earlier still decode.
- **The VIP grace nudge no longer fires at grant time.** Its default threshold
  (24h) is exactly the default first-install trial length (24h), so a
  brand-new user saw "your VIP is about to run out" on their first launch. The
  threshold is now capped at half the granted window, in both the check and
  the timer that schedules it.
- **A revoked VIP key id (`kid`) is now matched case-insensitively at
  redemption.** Clamping an already-granted window matched through
  `normaliseKey` (upper-cased) while the redemption gate compared exact case,
  so a CRL whose kid case differed from the key's clamped the old grant but
  still handed out a fresh one for the same revoked key. Both mint tools
  (`tool/vip_mint.dart`, `tool/vip_crl_mint.dart`) now upper-case kids, and
  keys minted before that still match.
- **`compliance_signing.dart` returned a `Future` without awaiting it inside a
  `try`**, so a corrupt stored seed threw past the fallback instead of minting
  a fresh key pair. (Also the 20 pana points that warning was costing.)
- **`pubspec.yaml` pointed at a repository that 404s** (`FlutterBase2025` →
  `FlutterBase2026`), which broke the source links and the License link on the
  live pub.dev page.

### Documentation

- README: the `buildAdmobNativeView(key)` sample now compiles, the `logLevel`
  default is documented as build-mode-gated (debug `.verbose`, release
  `.warning`), the Step 5 splash sample no longer leaks its `SimpleEventBus`
  listener and now calls `requestAtt()` before `initialize()`, the `AdConfig`
  configuration reference lists the four params it was missing
  (`maxVipStackDuration`, `onPrivacyPolicyTap`, `disableAppLovinCmpFlow`,
  `enableCrashGuard`), and the quick-start floor is current.
- `doc/AD_PROMPT_FLUTTER.MD`: the flagship splash snippet compiles again
  (`adMob:` → `admob:`).
- Stale version pointers and test counts refreshed in `CLAUDE.md`,
  `doc/README_TESTING.md`, `doc/feature.md` and `doc/architecture.md`.
- The offline VIP redemption path and the always-on QA test-device hashes are
  now commented at the source as deliberate product decisions, so reviewers
  stop re-filing them as defects.

### Changed

- `flutter_secure_storage` widened to `>=10.0.0 <12.0.0`. This package still
  resolves 10.x (11 needs win32 ^6, which `package_info_plus 9` blocks, and
  `package_info_plus 10` needs Flutter >= 3.38.1) — the wide bound lets a
  consuming app that is already there pull 11.

## [2.3.4] - 2026-08-25

Nine further QC rounds (13-22) on the consent path alone, all of them driven by
on-device verification rather than by the unit suite. Both final reviewers
scored the result 10/10 with zero findings. Verified on a Samsung A50 and a
Samsung A11 (the consent resume backstop, 5/5 on each).

### Fixed

- **A rewarded ad can now be watched more than once per session (AdMob).**
  Found by an on-device smoke test with real AdMob test ads, not by the suite:
  AdMob delivers `onUserEarnedReward` *before* `onAdDismissed`, and the reload
  hung off the reward callback — so it ran while the spent ad was still cached
  and did nothing, and no second reload ever came. After one completed rewarded
  ad the slot stayed empty for the rest of the session, so the next "watch an
  ad for a reward" tap silently did nothing until the app was restarted. The
  refill now happens on dismissal, where the spent ad is already cleared, and
  still goes through AdManager's own gate (VIP / daily cap / consent / network).
  Rewarded Interstitial had the identical shape and is fixed with it. The
  AppLovin adapter was never affected — it reloads inside its own
  `onAdHiddenCallback`.

- **Withdrawing consent through the Privacy Options form now applies even when
  the form is open for a long time.** Found by on-device verification (Pixel 7
  Pro, EEA debug geography — see `doc/audit/audit_round13_device.md`), not by a
  test: the flow gave up waiting after 20 seconds, read the consent status
  *while the native form was still on screen*, and never read it again. A user
  who spent longer than that in the form and then withdrew consent kept getting
  personalised ads for the rest of the session, with their own withdrawal on
  record. The wait is now the same human-reading bound as the initial consent
  form (`kFormDismissTimeout`), a late dismiss re-reads and re-applies the real
  choice, and every app resume re-applies consent when the device's IAB TCF
  state disagrees with what the providers were told — so a withdrawal cannot be
  lost even if the dismiss callback never arrives at all.
- **A consent withdrawal now applies with no network at all.** The re-apply that
  carries a withdrawal used to re-read the device's TCF state a second time, and
  used to wait on UMP unbounded. Offline, or during a UMP outage, that second
  read could throw or come back empty — and "no TCF data" means "assume
  allowed", so a re-apply that was meant to carry a refusal came back out of the
  pipeline as a grant, leaving both providers personalised under a user's
  refusal. The withdrawal is now settled by the refusal the caller already read:
  the UMP read is bounded to 2 s and optional, the ad gate is closed for the
  duration of the write and reopened by an owed-recovery debt that a reconnect
  also pays, and a newer host `setConsent` landing mid-check always wins.

## [2.3.3] - 2026-08-23

Six more independent QC rounds (7-12) over the whole package, against the seven
product requirements. Every claim below is backed by a test verified red against
its own reverted fix — nothing else. Full write-ups in `doc/audit/`.

### Security

- **A withdrawn consent no longer leaves a personalised load in flight.** Only
  one of the three consent axes was tracked, so withdrawing while a request was
  already out let that request complete and serve under the old string. Every
  slot loaded under a superseded consent epoch is now refused at show time and
  reloaded.
- **UMP `obtained` is no longer read as consent to personalised ads.** It only
  means the user answered the form; the actual TCF purposes are now parsed
  before anything personalised is requested.
- **A missing UMP platform channel fails closed in release too.** It used to
  fail open, which on a device where the channel was unavailable meant serving
  ads to an EEA user who was never asked.
- **No ad can be drawn over an open consent form.** Presenting the privacy
  options / re-consent form now blocks full-screen ads for as long as the form
  is up (ref-counted, with a logged 15-minute backstop so a dropped dismiss
  callback cannot block ads for the rest of the process).
- **A plaintext-fallback VIP grant is only trusted when the Keystore is
  broken.** That fallback exists for devices whose secure storage does not work;
  a fallback entry on a device whose Keystore is healthy has no legitimate way
  to exist, so it is now clamped instead of accepted outright.
- **A revocation list now clamps grants the revoked key already made,** and the
  cached list is applied on every startup, not only when a fresh one is
  fetched.
- **A host re-init no longer forgives an invalid-traffic escalation,** and
  `bypassSafety: true` (the splash App Open ad) no longer skips the
  invalid-traffic pause.

### Fixed

- **Blank banner/MREC that never recovered.** The rate limiter reported a
  throttled load as an error, which the recovery loop treated as a broken slot,
  which re-entered the limiter — a grey box for the rest of the session.
  Display errors and "needs recovery" are now separate states, and the recovery
  bypass is itself rate-limited.
- **A full-screen slot could wedge for the session.** A swallowed show on
  either provider left the slot in `showing` forever; both providers now
  release it.
- **AppLovin banner/MREC could stick in `loading` forever** (watchdog added) and
  could resurrect a key disposed mid-preload, leaking the native ad view.
- **A transient secure-storage read no longer costs a paying customer their
  VIP.** A failed read is now told apart from "no VIP data" and retried inside
  the session instead of running the whole session as non-VIP.
- **VIP writes are strictly ordered process-wide.** A discarded manager's
  in-flight write could land on top of its replacement's and resurrect an
  entitlement that had just been revoked. Startup stays bounded: the load's
  drain gives up rather than hanging on a wedged platform write.
- **A redeem on a disposed manager no longer burns the customer's one-time
  key.**
- **The ad-click latch is spent by the resume that saw it,** so returning from
  an ad click cannot trigger an App Open ad.
- **The M6 fallback clamp is anchored to the grant timestamp,** so a failed save
  no longer rolls the clamp forward on every launch.


### Fixed — lifecycle & cache-expiry round (audit MINOR m15/m16/m18/m22/m24/m36)

Each item below is backed by a test that was verified red against its own
reverted fix, and nothing else.

- **A cached ad could read as "fresh" for the rest of the session after a
  clock change.** The freshness check compared wall-clock `now` against the
  wall-clock load stamp with no lower bound, so a backwards clock change
  (manual, or an NTP correction) put the stamp in the future, made the computed
  age negative, and kept the ad inside its validity window forever. Both the
  reuse-on-load and the refuse-to-show-a-stale-ad guards stopped working. A
  negative age now counts as stale.
- **Discarding an expired ad blocked its own replacement.** All four AdMob
  full-screen formats recorded a cache expiry as a *load failure*, which starts
  the exponential-backoff cooldown. The refill fires from the very callback the
  discard invokes, so it landed inside a cooldown window the discard had just
  created and the slot stayed empty until the next periodic retry — no ad for
  the next several show attempts. An expiry now just empties the slot; the load
  path never failed.
- **`canShowInterstitial()` / `canShowRewardedAd()` could report `true` for an
  ad that would not be shown.** Both only asked whether the slot was ready, so
  a cached AdMob ad that aged past its 1h content validity while the host was
  polling still reported showable — and the show call then discarded it. A host
  gating a button on these got a button that did nothing.
- **Revenue could be reported for a disposed full-screen ad.** Every
  `google_mobile_ads` wrapper cleared its full-screen content callback on
  dispose but left the paid-event listener wired, so a paid event arriving after
  disposal still emitted revenue through the old event sink.
- **AppLovin: destroy retries outlived the adapter.** The retry that makes
  `destroyWidgetAdView` succeed once the native view has finished detaching
  slept on an untracked timer, so a chain started by the last widget unmount
  before teardown kept calling into the bridge for up to ~1.7s after
  `dispose()` had already cleared every native listener. The retries are now
  cancelled by `dispose()`.
- **Per-widget notifiers were leaked when a key never got a slot.** Both
  adapters' `dispose()` walked only the slot maps, but the per-key listenable
  bundles (and AppLovin's per-key ad-view-id notifiers) are created
  independently of the slot, so any key that only ever had those kept its
  `ValueNotifier`s alive for good.

## [2.3.2]

### Fixed — independent review, round 3

Two independent QC passes over the round-5 work found these. As above, each
claim is backed by a test verified red against its own reverted fix.

- **AppLovin native ads never came back after a consent change.** Withdrawing
  personalisation consent (or closing and reopening the consent gate) makes the
  widget drop its live native instance and immediately re-load — reusing the
  same instance key, because that key *is* the widget's `State`. A tombstone
  added to stop late callbacks from resurrecting a dead key was permanent, so
  the reload got a disposed slot and disposed `ValueNotifier`s instead: the ad
  never returned for the rest of that widget's life, and callbacks wrote to
  disposed notifiers. The tombstone is now lifted when a live widget re-loads
  the key, while a late callback for a key nobody revived still gets the shared
  disposed sentinel — so the leak the tombstone exists to prevent still cannot
  happen. AdMob was unaffected (it guards by slot identity, not by key).
- **A throwing event-bus subscriber could take down the splash screen.**
  `SimpleEventBus.fire` guarded every listener so one failure couldn't block
  the others, but the later-added replay in `listen` did not — so a subscriber
  that threw escaped straight out of `listen()` into its caller. Per the
  integration contract that caller is a `listen()` line in the consuming app's
  splash. Guarded, matching `fire`.

### Fixed — independent review, round 2

A second independent reviewer went over the round-5 diff after it shipped
(same discipline as the first: every claim below is backed by a test that
fails against the reverted fix, not taken on trust).

- **An abandoned consent form could mute the UMP gate for the rest of the
  session.** The round-1 fix for "the backstop could present a second form on
  top of one our own timeout couldn't close" simply stopped retrying entirely
  once that happened — worse than not having the fix at all: a user who
  answered the still-open native form 10 seconds later got zero ads until an
  app restart, whereas the un-patched backstop at least kept retrying and
  could reopen the gate. Both the periodic backstop and the reconnect retry
  (which never checked this state at all) now recheck Google's local,
  already-cached consent decision — no form, no network call — so they can
  self-heal without risking a second dialog.
- **The App Open hard-cap watchdog compared a field to itself.** It read
  `_appOpenAd` fresh when the timer fired and checked that value against
  itself, which is always true and guards nothing. Not reachable through any
  load/show path today (other guards happen to cover it), but a maintenance
  hazard for the next change here — fixed to capture the specific ad at arm
  time, same as every other call site in the file already does.
- **A test canary asserted its own hand-rolled copy of a config object,
  never production's.** Deleting the field it exists to guard from the real
  code left the test green. The production build is now exposed for the test
  to call directly.

### Fixed — 8 of 12 round-5 fixes that shipped with no regression test

Same review found a large fraction of round-5's diff was revertible in bulk
with the suite staying green — the fix existed but nothing exercised it. Each
one below now has a test verified red against its own reverted fix:

adapter-orphan-on-failed-init disposal, the new banner/MREC/native load
watchdog (plus its dead-cache cleanup and a dispose-during-await race in the
banner path), the AppLovin COPPA re-init reachability fix, the UMP mutex's
240 s self-heal timeout, `AdLoadingDialog.show()`'s flag-ordering fix, and
the banner widget's consent-withdrawal listener (the fix already existed;
only a counter was asserted, not the widget behaviour it drives). Two related
fixes — the identical one for MREC/native widgets, and a rewarded-dialog
ownership check that turned out to be unreachable through any current call
path — remain unverified; see `doc/audit/audit_claude.md`'s handover section.

Round-5 audit, commits 2–3: the rest of the consent surface, then the
fullscreen-lifecycle failures that could kill a surface for a whole session.

### Fixed — issues found by an independent review of the fixes above

An independent reviewer was pointed at the round-5 diff before it shipped. It
found that three of the flagship fixes did not work on their own main path, and
that one of them made a transient hang permanent. All of it was confirmed by
reading the code, not taken on trust — and one of the reviewer's own
recommendations was rejected after reading the test that documents the opposite
invariant (see below).

- **The "withdrawing personalisation discards cached ads" fix was dead code.**
  It compared `_consent` against the incoming consent inside the listener, but
  `setConsent()` assigns `_consent` *first* and only then calls
  `ConsentManager.set()`, whose `ValueNotifier` notifies synchronously — so the
  listener always saw the new value on both sides and the guard could never
  fire. Every withdrawal route (`showPrivacyOptions()`, `requestUmpConsent()`,
  a host's own `setConsent`) goes through exactly that sequence, so personalised
  fullscreen ads already in the cache were still shown. Now compares against
  what was last actually applied to the adapter, which no assignment order can
  break. Regression test included, and verified to fail against the old code.
- **Its inline-ad half was a no-op too.** Bumping `initRevision` cannot rebuild
  a banner that is already showing: each widget's listener only re-inits when it
  has no ad, and withdrawing personalisation does not close the `canRequestAds`
  gate that would clear that state. A dedicated `personalisationRevision`
  signal now tells banner/MREC/native to drop their live instance and reload.
- **The COPPA-on-AppLovin recovery could not be reached.** `setConsent()`
  returned early when the SDK was not initialised, *above* the block that
  rebuilds the adapter — but the child-directed abort is exactly what leaves it
  uninitialised, so the host's later "not a child after all" call returned
  before the recovery ran. The block now runs first, and the last known-good
  config survives adapter teardown so there is something to rebuild from.
- **The new banner/MREC/native load watchdog relabelled the slot without
  clearing the dead ad.** `loadBanner` early-returns while the key is still in
  `_bannerAdsByKey`, so the cached-but-dead ad blocked every later load for
  that widget instance; only a remount (which produces a new key) appeared to
  recover. The watchdog now drops the ad object as `onAdFailedToLoad` does.
- **The UMP in-flight mutex had no deadline** — the one guard added this round
  without one. `setConsent` → `_persist()` → `updateRequestConfiguration` are
  all unbounded, so a single wedged channel meant every later
  `requestUmpConsent()` joined a future that could never complete: the gate
  would stay shut with no self-heal, strictly worse than the lockout this round
  set out to fix. Now capped at 240 s, and the lock is only released by the
  call that owns it.
- **After the 180 s form timeout the periodic backstop could present a second
  consent form** on top of the first, which `Future.timeout` does not close.
  The backstop now recognises that state and rechecks Google's already-cached
  consent decision (no form, no network call) instead of presenting another
  one — see "Fixed — independent review, round 2" below for why the first cut
  of this (standing down entirely) was itself a regression.
- Smaller ones from the same review: the IAB read's deadline now covers
  `PackageInfo` (an unbounded channel it was skipping), `AdLoadingDialog.show()`
  got the same flag-ordering fix its sibling already had, the rewarded path no
  longer claims ownership of a dialog it did not open, and the App Open hard cap
  clears the field by identity like the callbacks do.

### Changed — after the review

- `AdConfig.autoShowConsentDialog` now documents that it has **no effect** with
  the default `autoRequestUmpConsent: true`. The behaviour was introduced above
  on purpose — the built-in dialog is not a certified CMP and produces no TCF
  string — but shipping a default-true flag that silently does nothing, with no
  word in its own doc, is its own kind of trap.
- `shared_preferences_android` is declared without an upper bound. A `<3.0.0`
  cap would become a new pinning wall for every consuming app the moment
  `shared_preferences` requires 3.x. A compile-time canary test guards the
  platform API this package leans on instead.

### Fixed — lifecycle (commit 3)

- **App Open could die for the rest of the session, and leak two native ads
  doing it.** After the 90 s hard cap force-dismissed a show, AdManager
  reloaded and a new ad took the field — and then the abandoned ad's native
  callback arrived and cleared that field unconditionally, destroying the
  replacement. `appOpenSlot` still reported ready, so `showAppOpen` returned
  false against a null ad forever, and `_retryRefillAds` only refills
  idle/cooldown slots so nothing repaired it. Callbacks now clear the field
  only while it still points at their own ad, and the watchdog disposes the ad
  it gives up on instead of just forgetting it.
- **The App Open watchdog was armed after `await ad.show(...)`.** If the
  platform call itself never resolved — the exact hang the watchdog exists for
  — it was never armed at all. Armed before the await now.
- **`AdLoadingDialog.showAdBuffer` could block every fullscreen ad for the
  session.** It set `_isShowing = true` before `Navigator.of()` and the route
  push, neither guarded, and every caller is fire-and-forget: a throw left the
  flag stuck true, so `_fullscreenBusyReason` reported "ad loading buffer
  showing" forever, and `onComplete` never ran — hanging a splash that awaited
  it. The flag is now raised only once the route exists, and a failure still
  calls `onComplete` as the docstring promises.
- **`AdLoadingDialog.dismiss()` could strand a later dialog with no way to
  close it.** Unlike `resetState()` it did not bump the generation, so a
  sleeping `showAdBuffer` timer woke up, believed it was still current, and
  cleared state belonging to a NEWER dialog — which then had
  `barrierDismissible: false`, `PopScope(canPop: false)` and a `dismiss()`
  that early-returns: a frozen UI. The rewarded on-demand path also stopped
  dismissing dialogs it never opened.
- **A failed `initialize()` left the adapter alive.** AppLovin wires its four
  native listeners before awaiting SDK init, so on the 20 s timeout branch the
  native side could still come up and keep calling into slots this manager had
  abandoned — up to four orphans across the retry chain, each holding ~15 live
  `ValueNotifier`s.
- **Banner / MREC / native could sit "loading" forever.** They had no load
  watchdog (all four fullscreen formats do), so a GMA listener that never fired
  left the slot refusing every later `beginLoad()` and the widget showing its
  shimmer placeholder with `hasError` false. Now bounded at 30 s, which lands
  the slot in `cooldown` — a state a remount retries.
- **The crash guard's slot recovery skipped rewarded-interstitial, MREC and
  native.** That pass is the *only* recovery for a slot stuck `showing`, since
  those formats deliberately have no show-watchdog; if the callback that would
  have advanced the slot was the thing that crashed, it stayed stuck.
- **Four `show*` catch blocks dropped the ad without disposing it**, leaking
  the native object. Reachable: `gma_bridge` awaits `setServerSideOptions()`
  before showing, and a platform call can throw.

### Fixed — consent (commit 2)

- **The consent-footgun guard was fail-open on AdMob.** It treated
  `disableAppLovinCmpFlow: false` as proof that a consent flow existed, but
  that flag is only ever read by `AppLovinAdapter.initialize`, so on AdMob it
  means nothing. The combination `provider: admob` +
  `autoRequestUmpConsent: false` + `disableAppLovinCmpFlow: false` — a config
  the SDK accepts silently — produced no warning and left `canRequestAds` at
  its default `true`: EEA/UK users served ads with no consent flow at all.
  AppLovin's CMP now only counts when AppLovin is the active provider.
- **AppLovin received its privacy flags after `AppLovinMAX.initialize`, not
  before.** On an ordinary cold start (host never called `setConsent`, so
  nothing was buffered) the post-init `applyToProviders` was the first time
  AppLovin heard about consent — MAX documents these as init-time settings.
  `AdProviderAdapter.initialize` now takes the consent state so each adapter
  can apply it in the order its own SDK requires.
- **`tagForUnderAgeOfConsent` never reached AdMob.**
  `AdConfig.umpTagForUnderAgeOfConsent` only fed UMP's consent form, so an app
  declaring an under-age audience got the right form and then sent every ad
  request out with no under-age signal. Now set on `RequestConfiguration` —
  only ever as `yes`; absent an explicit declaration it stays `unspecified`
  rather than asserting `no`.
- **A UMP re-run could silently wipe a CCPA opt-out or the COPPA flag.**
  `AdManager._consent` was a second source of truth that
  `ConsentManager.set()`/`reset()` never updated, so anything rebuilding an
  `AdConsent` from it (a UMP backstop retry, `showPrivacyOptions()`) wrote
  `doNotSell: false` back to disk, to AdMob's `rdp` extra and to AppLovin's
  `setDoNotSell`. The two are now kept in sync at the single point every
  consent change already flows through.
- **Withdrawing personalisation mid-session did not invalidate already-loaded
  ads.** `applyConsent` only affects future requests, so the personalised
  app-open/interstitial/rewarded ads already in the cache were still shown and
  banners kept refreshing; ad age was the only thing that could discard them.
  New `AdProviderAdapter.discardCachedFullscreenAds()` runs on a
  `true → false` transition, alongside an `initRevision` bump for inline ads.
  Never touches an ad that is on screen.
- **COPPA on AppLovin was a one-way door.** Setting `isAgeRestrictedUser: true`
  correctly hard-stops ad requests (MAX 4.x has no runtime API for it), but
  correcting the flag back to `false` left every AppLovin surface dead for the
  rest of the process with nothing in the log to say why. The adapter is now
  re-initialised when the flag changes in either direction.
- **`tcfConsentString` always returned `null` on real devices.** It read
  through the legacy `SharedPreferences` API, which on Android reads its own
  private file (UMP writes to the app's *default* store) and on iOS prefixes
  every key with `flutter.` (UMP writes none). Its unit test passed against
  `setMockInitialValues`, so the API looked wired for four audit rounds while
  answering `null` to every caller. Now reads the platform's own store —
  verified on Android hardware, returning a real TCF v2 string.
- **iOS: a failed ATT status read could trigger Apple's tracking prompt from
  inside `initialize()`.** An unreadable status fell through to "do not defer",
  which then called `AdvertisingId.id(true)` — and that `true` asks the plugin
  to raise the ATT prompt, outside the host's control. Unknown is now treated
  like `notDetermined`, as is a `notDetermined` that survives a timed-out
  `requestAtt()`. The status read itself is now bounded at 5 s, matching what
  the self-check already did to the same call.
- **The built-in consent dialog could ask an EEA user on UMP's behalf.** It is
  a two-button sheet, not a certified CMP, and produces no TCF string — yet a
  "yes" from it was written through to AppLovin. It is now skipped whenever UMP
  owns consent, including when UMP came back inconclusive (the path that made
  this reachable).
- **A one-time connectivity-watch failure disabled the fast path for the whole
  session.** `_startConnectivityWatch()` was called exactly once and is
  best-effort, so a plugin init that threw left `isConnected` pinned to its
  optimistic seed: every offline load just failed into backoff and
  refill-on-reconnect never happened. The poll tick now re-attempts it.
- The consent-footgun check no longer races the un-awaited auto-UMP flow, the
  first-install Keychain read is bounded at 5 s (failing safe: skip the grant),
  and `_attRequested` is reset by `destroy()` like the other guard flags.

### Added

- `AdManager.usPrivacyOptedOut` and `AdManager.gppConsentString` — the IAB US
  Privacy and GPP signals a CMP leaves in platform storage.
  `usPrivacyOptedOut` returns `null` when no string exists, deliberately
  distinct from `false`: `AdConsent.doNotSell` is host-set only, so
  `exportComplianceReport` reported `doNotSell: false` for a California user
  who had opted out through a CMP. GPP is exposed raw rather than decoded —
  mis-parsing a privacy signal is worse than not parsing one.
- `debugFormDismissTimeoutOverride` — lets an on-device harness cap the
  consent-form wait, since no harness can tap a native dialog and would
  otherwise sit out the full 180 s.

### Changed

- `AdProviderAdapter` gains `consent:` on `initialize` and a new
  `discardCachedFullscreenAds()`; `GmaBridge.updateRequestConfiguration` now
  takes the COPPA/TFUA tags (`RequestConfiguration` replaces rather than merges,
  so passing only test-device ids wiped them). Breaking only for a custom
  adapter or bridge implementation.
- Declares `shared_preferences_android` directly. It is already in every
  Android build as the implementation of `shared_preferences`; the direct
  dependency exists solely because `SharedPreferencesAsyncAndroidOptions` —
  the only way to point a read at the app's default preference file, where UMP
  writes — is not re-exported by `shared_preferences`.

## [2.3.1] - 2026-08-22

Consent-path hotfix. Every item below was found by the round-5 audit and the
first two were reproduced on real hardware (Pixel 7 Pro, `debugGeography:
debugGeographyEea`, real UMP forms) before and after the fix.

### Fixed

- **Audit round 5 — the consent form was re-shown on every launch to an
  EEA/UK user who had already answered it.** The flow gated on
  `isConsentFormAvailable()`, which reports whether a form *exists*, not
  whether consent is *required* — and a form stays available after consent,
  because that is what backs the Privacy Options entry point. Confirmed on a
  real device (Pixel 7 Pro, `debugGeography: debugGeographyEea`): a cold
  restart with consent already granted logged `status=obtained
  formShown=true` and put the form back on screen. Now uses Google's own
  `ConsentForm.loadAndShowConsentFormIfRequired` behind a
  `status == required` guard, so an already-answered user is never asked
  again and the common (non-EEA) case skips the platform call entirely.
- **Audit round 5 — the consent gate could stay shut for a whole session
  with no way to recover.** `_umpAttemptFailed` was `result.error != null`
  alone, but UMP returns `error == null` with `canRequestAds == false`
  whenever it resolves from cache without being able to serve a form — the
  ordinary "flaky network on first launch in the EEA" case. Both retry paths
  gate on that flag, so the gate stayed closed for the rest of the process:
  **zero ads, no self-heal short of an app restart**, even once the network
  came back. It now also covers an inconclusive result and a still-closed
  gate.
- **Audit round 5 — the consent form gave the user only 20 s to answer.**
  The dismiss timeout was shared with the network steps, so a person reading
  a real GDPR form (206 partners, an expandable "Learn more") had the flow
  abandoned out from under them, resolving the ad gate before they had
  chosen. Split out to 180 s for the human step; the no-network case is
  still bounded by the 20 s guard on `requestConsentInfoUpdate`, and a cap
  still exists so an unattended simulator cannot hang the flow forever.
- **Audit round 5 — the UMP retry paths could run several consent flows at
  once, and dropped `tagForUnderAgeOfConsent` when they did.** Concurrent
  callers now join the in-flight request instead of presenting a second
  form and racing each other's writes to the gate; retries replay the
  params of the original call, so a child-directed app no longer collects
  consent through the wrong form (which would not have been valid for an
  under-age audience) and an EEA-debug run stays reproducible.
- **Audit round 5 — the periodic UMP backstop was unbounded.** With the
  widened failure flag above, an EEA user who legitimately chose "reject"
  also reads as "gate closed", so the backstop would have re-run the consent
  flow every 5 minutes for the rest of the session. It is now capped, and
  never re-runs for a user UMP already got an answer from.

### Added

- `example`: `--dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>`
  drives the real EEA consent path on a test device. Without it a tester
  outside the EEA can never reach UMP's `required` branch, so every EEA-only
  code path stays unexercised — that blind spot is what let the two consent
  bugs above ship. `UMP_TEST_ID` is the hashed device id UMP prints to the
  log on first run.

## [2.3.0] - 2026-08-21

### Added

- `AdMobConfig.effectiveTestDeviceIds` / `kQaTestDeviceHashes` — this team's
  own QA device fleet's AdMob test-device hashes are now always merged into
  `RequestConfiguration.testDeviceIds` on every `initialize()`/consent
  re-apply, regardless of what a host app configures in `testDeviceIds`.
  Keeps manual QA on real hardware from ever counting as real
  impressions/clicks (and the invalid-activity rate-limit risk that comes
  with it), without the host app having to know or maintain the list.

### Fixed

- **Audit fix — `initialize()`'s `autoRequestUmpConsent` branch could fail
  open on a real consent-fetch error, not just an unwired UMP channel.**
  Any exception used to fail the gate open; now only `MissingPluginException`
  (channel genuinely not wired) fails open — every other exception (a real
  UMP fetch failure) fails closed, so a network hiccup can no longer
  silently ship ads with no verified consent decision.
- **Audit fix — `destroy()`/`_resetGuardState()` left the previous session's
  device GAID behind.** A stale GAID surviving past teardown into the next
  `initialize()` is a privacy leak; it's now cleared as part of guard-state
  reset.
- **Audit fix — reopening the `canRequestAdsListenable` gate mid-session
  never triggered a frame in `BannerAdWidget`/`MrecAdWidget`/
  `NativeAdWidget`.** `_onCanRequestAdsChanged()`'s reload path relied on
  `addPostFrameCallback`, which does not itself schedule a frame — the
  reload silently no-opped until some unrelated frame happened to fire.
  Fixed by calling `WidgetsBinding.instance.scheduleFrame()` alongside it.
- **Audit fix — `MonetizationArbitrator`'s with-estimator branch could veto
  ads at zero eCPM.** The no-estimator branch already guarded on
  `ecpm > 0`; the with-estimator branch was missing the same guard, so a
  session with no revenue events yet (`ecpm == 0`) could still have ads
  vetoed whenever the host's likelihood estimator reported > 0.5. Both
  branches now require `ecpm > 0` before vetoing.

## [2.2.0] - 2026-08-20

### Added

- `AdManager().currentDeviceGaid` and `AdManager().adMobTestDeviceHashHint()` —
  the latter returns instructions (device's current GAID included, clearly
  labeled) for finding this device's AdMob test-device hash via logcat tag
  `Ads`, since Google has no public API/formula for that hash. Intended for
  a host app's own debug UI; distinct from the GAID, which is not valid for
  AdMob's `RequestConfiguration.setTestDeviceIds()`.

## [2.1.0] - 2026-08-19

### Fixed

- **2026-08-19 audit: App Open (and interstitial/rewarded/rewarded-interstitial)
  could be shown stale past their expiry window.** The 4h/1h `isAdFresh`
  check was only ever consulted when *loading* (reuse-if-fresh) — `show*()`
  never checked it, so a ready ad that sat unused past expiry (app
  backgrounded a long time, then resumed) could still be shown. For App
  Open specifically this violates Google's documented policy of discarding
  and reloading rather than showing a stale ad. Fixed for all 4 AdMob
  fullscreen types: a stale ready slot is now discarded (native ad
  disposed, slot marked failed → cooldown, eligible for reload) instead of
  shown.
- **2026-08-19 audit: `showAppOpenAdOnResume()` bypassed the daily/session
  safety cap outside the one case (splash) this SDK's own contract
  allows.** It always called `showAppOpenAd(bypassSafety: true, ...)`, so a
  resume-triggered App Open skipped the daily/hourly/session cap and
  CTR-fraud pause entirely while still counting toward the cap via
  `recordFullscreenAdShown()` — an asymmetric bypass. Fixed to
  `bypassSafety: false`; the resume-specific timing gates
  (`canShowAppOpenOnResume`) are unchanged and still apply.
- **2026-08-19 audit: AppLovin banner/MREC widgets leaked their native
  `MaxAdView` on normal disposal.** `disposeBannerInstance`/
  `disposeMrecInstance` released only the Dart-side `AdSlot`/
  `BannerListenables`/`ValueNotifier` — they never called
  `destroyWidgetAdView`, so every `BannerAdWidget`/`MrecAdWidget` that
  permanently unmounts leaked the native ad view. AdMob's equivalent path
  was already correct. Fixed to release the native `AdViewId` on dispose.
- **2026-08-19 audit: `requestAtt()`-before-UMP ordering had no
  release-build footgun.** Forgetting to call `requestAtt()` before
  `initialize()`/`requestUmpConsent()` on iOS was only ever a
  `SafeLogger.w` inside `requestUmpConsent()` itself — easy to miss.
  Added `attOrderFootgunWarning`, wired into `initialize()` alongside the
  existing consent footgun check (loud in every build, not release-gated
  to a hard block since this is a revenue/attribution risk, not a
  legal-compliance one like the consent footgun).

- **Fork-review of the 2026-08-16 audit fixes (2026-08-17): stale load-watchdog
  timer race in `AdSlot.armLoadWatchdog()`.** The watchdog `Timer` created by
  the previous fix kept no handle, so re-arming it (the adapter's own
  internal reload-after-show-failure path does this) left the earlier
  timer alive. If a fast reload started well inside the first timer's
  window, the stale timer could still fire and call `markFailed()` against
  the *new* loading attempt, cutting its real timeout short. `AdSlot` now
  cancels any previously-armed watchdog before arming a new one, and
  `dispose()` cancels a still-pending watchdog too (it previously could fire
  `markFailed()` — a `state.value` write — against an already-disposed
  `ValueNotifier`). 2 new tests in `test/ad_slot_test.dart`. Also tightened
  2 existing tests from the same audit round that didn't actually regress
  if their fix were reverted (`test/vip_revocation_test.dart`'s CRL→AVP1
  relabeling test — documented why that direction is inherently protected
  by Ed25519 rather than by the fix; `test/connectivity_refill_test.dart`'s
  overlapping-call race test — strengthened to assert on the log line the
  discard branch emits, since `_connectivityReady` alone reads identically
  with or without the fix in this unit-test environment).

- **P2 audit cleanup (2026-08-16), two minor findings.**
  - `destroy()` only cleared the banner load-cooldown map, missing
    mrec/native (all 3 added together at T65) — a `destroy()` + fresh
    `initialize()` within the cooldown window (without unmounting the
    widget) left MREC/Native inconsistently "still on cooldown" vs Banner.
    1 new test in `test/ad_manager_test.dart`.
  - Re-entering `initialize()` a second time without an intervening
    `destroy()` (the "auto-disposing previous" branch) didn't remove the
    consent listener before re-adding it — since `ConsentManager` is itself
    a persistent static singleton (survives this branch same as the
    adapter is torn down and recreated), N such re-inits left N copies of
    the listener stacked on it, each firing `applyConsent` redundantly per
    consent change. Fixed by removing it first, mirroring `destroy()`'s own
    cleanup. Not independently unit-tested: reaching the listener
    registration requires a real native adapter `initialize()` call to
    succeed first, which isn't reachable in this repo's plain
    `flutter test` environment (native plugin channels are unavailable) —
    verified correct by code inspection (exact mirror of `destroy()`'s
    already-tested `removeListener` call) rather than by a new test.
- **`_startConnectivityWatch` could leak a `StreamSubscription` across two
  overlapping `initialize()` calls — caught by internal audit, 2026-08-16.**
  It's called `unawaited` from `initialize()`, which can itself finish (and
  reset its own re-entry guard) well before this method's up-to-20s
  connectivity-plugin-init await resolves. A second `initialize()` call
  starting before the first's watch resolved could overlap two invocations
  of this method; whichever resolved last silently overwrote
  `_connectivitySub`, leaking the other's subscription forever. Added a
  generation token (same pattern as `enableFillRateBaselineMonitor`'s fix
  above) so a call that loses the race bails out before ever subscribing,
  instead of clobbering (or being clobbered by) a newer one;
  `_stopConnectivityWatch` also bumps it so a still-pending start can't
  resurrect state after a stop. 2 new tests in
  `test/connectivity_refill_test.dart`.
- **Rewarded Interstitial (T89) was missing from the 5-minute connectivity
  backstop refill entirely — caught by internal audit, 2026-08-16.**
  `_retryRefillAds` only checked `appOpenSlot`/`interstitialSlot`/
  `rewardedSlot` — if a rewardedInterstitial's first load ever failed
  (no network / no-fill) and it was never shown, nothing would ever refill
  it again. Added the same idle/cooldown check for
  `rewardedInterstitialSlot`. 1 new assertion in
  `test/connectivity_refill_test.dart`. (Also updated 4 test fake adapters
  — `banner`/`mrec`/`native_ad_widget_test.dart`,
  `connectivity_resilience_test.dart` — to implement
  `rewardedInterstitialSlot`/`loadRewardedInterstitial` for real instead of
  relying on `noSuchMethod`, since this change made them reachable for the
  first time.)
- **`NativeAdWidget` on AppLovin leaked a live `BannerListenables` bundle
  per scrolled-past native ad in a `ListView` — caught by internal audit,
  2026-08-16.** `MaxNativeAdView`'s listener callbacks re-resolve
  `adapter.native(instanceKey)` on EVERY invocation (unlike
  `BannerAdWidget`/`MrecAdWidget`, which capture their listenables ONCE at
  load start), so a callback that arrived after `disposeNativeInstance(key)`
  already removed the map entry would silently `putIfAbsent` a brand new,
  never-disposed bundle for that permanently-gone (per-widget-instance) key
  — unbounded, one leak per native ad scrolled past (T73's in-feed use
  case). `AdMobAdapter` was unaffected (captures its listenables/slot
  locals once, doesn't re-resolve per callback). Fixed by tracking disposed
  keys in `AppLovinAdapter` and returning the shared already-disposed
  placeholder for any of them instead of auto-vivifying a fresh one. 1 new
  test in `test/applovin_adapter_test.dart`.
- **AppLovin's internal reload-after-show-failure could leave a slot stuck
  `loading` forever — caught by internal audit, 2026-08-16.** After a show
  fails/dismisses, `AppLovinAdapter` reloads by calling the native bridge
  DIRECTLY (`_bridge.loadAppOpenAd`/`loadInterstitial`/`loadRewardedAd`),
  bypassing `AdManager.loadX()` entirely — which is the only place a load
  watchdog otherwise gets armed (`_armLoadWatchdog`/T76). If AppLovin's
  native SDK never calls back for one of these specific reloads (the exact
  callback flakiness T76's watchdog exists to guard against), the slot had
  no recovery path and stayed `loading` forever — every later load call is
  a no-op while already loading. `AdMobAdapter` was unaffected (its load
  path only has one call site, always AdManager-orchestrated). Fixed by
  adding `AdSlot.armLoadWatchdog(label, timeout)` (the same logic
  `AdManager._armLoadWatchdog` already had, now shared) and arming it
  directly at all 6 adapter-internal reload sites (2 per ad type — one from
  `onAdDisplayFailedCallback`, one from `onAdHiddenCallback`). 3 new tests
  in `test/applovin_adapter_test.dart`.
- **`canShowInterstitial`/`canShowRewardedAd`/`canShowRewardedInterstitialAd`
  could permanently escalate a CTR-anomaly lockout just from being polled —
  caught by internal audit, 2026-08-16.** All 3 are read-only "should I
  enable my ad button" queries, but internally called
  `AdSafetyConfig.canShowFullscreenAd()` — the SAME function the actual show
  flow uses, which has a side effect: on a CTR anomaly it re-arms an
  escalating suspicious-pause window. Since a blocked ad never adds an
  impression, CTR can never recover on its own, so every poll after each
  pause window naturally expired re-triggered and escalated the exact same
  violation forever, from nothing but a UI-enable-state check (e.g. a
  "Watch Ad" button rebuilding on a timer) — zero new clicks required. Fixed
  by adding `AdSafetyConfig.canShowFullscreenAdPeek()` (identical checks,
  zero side effects — mirrors `dailyCapReached()`'s existing "safe to poll"
  contract) and switching all 3 query methods to use it;
  `AdManager`'s actual `showInterstitial`/`showRewardedAd`/
  `showRewardedInterstitialAd` show flows are unchanged (still use the
  side-effecting variant, correctly, since those represent a genuine show
  attempt). 2 new tests in `test/ad_safety_config_test.dart`.
- **[Security] VIP-key revocation list (CRL, T95) missing domain separation
  from VIP keys — caught by internal audit, 2026-08-16.** `verifySignedCrl`
  and `verifySignedVipKey` both verified an Ed25519 signature over the raw
  payload bytes with no format tag mixed in. A CRL's payload shape
  (`<issuedAtEpoch>|<kids>`) is identical to an AVP1 VIP key's shape
  (`<seconds>|<kid>`) — since a CRL is *designed* to be broadcast publicly
  (no secrecy requirement), anyone who observed a real signed CRL could
  relabel its prefix from `CRL1` to `AVP1` and redeem it as a real VIP key
  valid for however many "seconds" the CRL's `issuedAt` epoch happened to
  equal (tens of years). Fixed by signing/verifying `"CRL1|" + payload`
  instead of the payload alone for CRLs specifically — AVP1/AVP2 signing is
  deliberately left untouched (changing it would break every VIP key a host
  app has already minted and distributed; CRL had not shipped yet, so no
  migration is needed for it either). `tool/vip_crl_mint.dart` updated to
  match, and now also sanitizes `|` out of `--kids` like `vip_mint.dart`
  already does for `--kid`. 2 new regression tests in
  `test/vip_revocation_test.dart` lock in both directions (CRL→AVP1 and
  AVP1→CRL1 relabeling both now rejected).
- **`AdManager.enableFillRateBaselineMonitor` race leaked the loser of two
  overlapping calls — caught by internal audit, 2026-08-16.** The method
  awaits `AdPreferences.getInstance()` before constructing its monitor;
  calling it twice without awaiting the first left whichever call resolved
  first's instance orphaned (its `AdManager().events` subscription never
  cancelled, silently persisting to `SharedPreferences` forever) once the
  second call's assignment overwrote the field. Fixed with a generation
  token so only the call that resolves *last* wins, and any loser disposes
  its own instance instead of leaking it; `disableFillRateBaselineMonitor`
  and `destroy()` also bump the token so an in-flight `enable` call can't
  resurrect a monitor after either wins. 3 new tests in the new
  `test/ad_manager_fill_rate_baseline_test.dart`.
- **`AdManager`'s ATT doctor check (T98) had no upper bound on a hung
  platform channel — caught by internal audit, 2026-08-16.** `_selfCheckAtt`
  now wraps the read in `.timeout(const Duration(seconds: 5))` — every
  `runIntegrationSelfCheck` item is awaited sequentially, so a channel that
  never completes would otherwise hang the entire doctor run indefinitely
  instead of failing just this one item.

### Added

- **`NativeAdWidget` gate-recheck behavior locked in by regression tests
  (T100).** Verified: a consent revoke or later rebuild after the gate has
  already passed (but before the native ad finishes loading) does not
  retroactively cancel an in-flight load — consistent with
  `BannerAdWidget`/`MrecAdWidget`, which gate `canRequestAds` only at
  request time too, never reactively in `build()`. No code change; closed
  as "current behavior consistent + acceptable" with 2 new tests
  documenting it, per the ticket's own escape hatch.
- **`monetization_arbitrator_test.dart` gains `showRewardedInterstitialAd`
  veto coverage (T99).** The `onLowValueAdVetoed`-style hook the ticket asked
  for already existed (`ArbitratorNudgeEvent` on `AdManager().events`, wired
  at all 3 fullscreen show call sites since T89 added the rewarded-
  interstitial slot) — this closes the one real gap, a missing test for the
  rewarded-interstitial veto path, and documents `showRewardedInterstitialAd`
  explicitly in the README's arbitrator section.
- **Runtime integration doctor — `AdManager.runIntegrationSelfCheck` extended
  (T98).** Flagship: 3 new read-only checks — "Navigator key wired" (fails if
  `setNavigatorKey` was never called), "Route observer wired" (real evidence
  via `AdScreenRouteLogger`'s new navigation-event counter, not just "was it
  constructed"), and "ATT status readable (iOS)" (catches a broken
  `app_tracking_transparency` native embed without ever showing the real
  system prompt). Results now render directly in the built-in
  `DebugAdOverlay` via a manual "🩺 Run integration doctor" tap (not
  auto-run — the existing per-ad-type checks attempt real ad loads).
  Deliberately does NOT add SKAdNetwork/`Info.plist`/`AndroidManifest.xml`/
  pod-graph checks — those need new native platform-channel code (or, for
  the pod graph, aren't a runtime concept at all); see README for the exact
  reasoning.
- **`FillRateBaselineMonitor` — 7-day on-device fill-rate/eCPM regression
  detector (T97).** Flagship: `AdManager().enableFillRateBaselineMonitor(...)`
  compares THIS SESSION's fill rate and average revenue-per-ad
  (`AdRevenueEvent.valueMicros`) against a rolling 7-calendar-day baseline
  persisted locally — fully on-device, no backend, no shadow ad requests.
  Fires an alert once per slot the first time it regresses by at least
  `regressionThreshold` (default 20%) below the device's own baseline, needs
  `minSamples` on both sides before trusting a comparison, and excludes
  today's own in-progress day from its own baseline. Wired into
  `AdDiagnostics.fillRateRegressionBySlot` and rendered directly in the
  built-in `DebugAdOverlay`.
- **Cryptographically-signed compliance report export — `AdManager.exportSignedComplianceReport` (T96).**
  Flagship: wraps the existing `exportComplianceReport` bundle with an
  on-device Ed25519 signature (key minted once per install, persisted via
  `flutter_secure_storage`) so an edit made to the exported JSON AFTER export
  is detectable — tamper-evidence for an ad-network dispute appeal. Verify
  with `verifySignedComplianceReportJson` or the new standalone
  `tool/verify_compliance_report.dart` CLI. See README's "Cryptographically-
  signed compliance report export" for the precise (deliberately limited)
  threat model this does and doesn't cover.
- **VIP key revocation list (CRL) — `VipManager.refreshRevocationList` (T95).**
  Flagship: an offline-signed revocation list closing the SDK's known
  leaked-key gap (a redeemable-forever `kid` once shared) without a backend.
  Mint with `tool/vip_crl_mint.dart` using the SAME Ed25519 private key as
  `tool/vip_mint.dart` — no new key material. Host fetches the raw signed CRL
  via a new `VipRevocationProvider` interface (mirrors `RemoteAdSafetyProvider`'s
  shape) and calls `refreshRevocationList` periodically (once/day suggested);
  verified CRLs are cached to disk and re-verified on every read, and a
  revoked `kid` is rejected by `redeemSignedKey` going forward. Fails open on
  every error (no provider, fetch throw, `null`, bad signature, replayed/older
  CRL) — never blocks a legitimate redemption. Does not claw back a grant
  already made before the revocation landed. See README's "Revoking a leaked
  key (CRL)".
- **`AdReadinessSplashController` (T94).** Officializes the splash-screen
  orchestration boilerplate the README documented by hand — subscribe-
  before-init, the hard-cap timer, `markSplashActive`/`incrementSplashCount`/
  `markSplashInactive`, the re-entrant-splash guard, the buffered App Open
  ad with `bypassSafety: true`. One `start()`/`onReady` call; your splash
  screen still renders 100% its own UI. `dispose()` also clears the SDK's
  splash-active state if the widget is torn down before `onReady` ever fires.
  Also fixes two stale spots in the README found while writing this: a
  broken code fence that had been splitting the `_SplashScreenState` example
  in two (the "Per-platform ad-unit ids" section was accidentally inserted
  mid-class, leaving the rest unfenced), and outdated wording claiming
  `SimpleEventBus` never replays events to late subscribers — it does now
  (see the "F1" comment in `event_bus.dart`).
- **`AdSafetyParams.maxPerPlacementAdsPerDay` (T92).** Optional additional
  daily cap keyed by `AdPlacement`, checked alongside (never instead of) the
  existing global daily cap at show time. `null` by default — fully
  backward-compatible. Emits an `AdSkipEvent` with `reason: 'placement_cap'`
  when it blocks. Note: can't be set via a `const AdSafetyParams(...)` call
  (`AdPlacement`'s custom `==` isn't const-map-key-safe) — use a regular
  constructor call or `.copyWith(...)`.
- **`BannerAdWidget` collapse/expand animation (T91).** New
  `collapseAnimationDuration` param (default 250ms) wraps the banner in
  `AnimatedSize`, so no-fill/cooldown/VIP collapsing (and a real ad becoming
  ready) animates the height change instead of an abrupt
  `SizedBox.shrink()` layout jump. Pass `Duration.zero` for the old
  instant-jump behavior.
- **`AdManager().pickProviderCohort()` (T90).** Deterministic 50/50 AdMob vs
  AppLovin MAX A/B split, built on `experimentBucket`. Pick before building
  `AdConfig` (provider is fixed for the session). No new compliance-report
  plumbing for comparing cohorts — every event already carries `providerTag`.
- **`AdManager().experimentBucket(key, buckets: n)` (T93).** Deterministic,
  local-only A/B bucket assignment — hashes GAID (or a lazily-generated
  pseudonymous install id when GAID is empty/all-zeros) with `key`. No
  network, no new dependency; lighter-weight than `RemoteAdSafetyProvider`
  for hosts that just want to compare two local `AdSafetyParams`/arbitrator
  configs.
- **Rewarded Interstitial ad type — AdMob only (T89).**
  `AdMobConfig(rewardedInterstitialId: ...)` +
  `AdManager().loadRewardedInterstitialAd()` /
  `showRewardedInterstitialAd(onDone: (shown, earned) => ...)` /
  `canShowRewardedInterstitialAd()`. Google's format shown at a natural
  transition point rather than behind an explicit "watch ad" tap. AppLovin
  MAX has no equivalent ad unit type — that adapter's implementation is a
  documented no-op. No VIP-bypass-to-extend-VIP flow and no SSV params for
  this ad type, unlike `showRewardedAd` (see the doc comments for why).
- **`RemoteAdSafetyProvider` (T88).** Optional `AdManager().initialize(...,
  remoteSafetyProvider: ...)` hook so a host can adjust `AdSafetyParams`
  (daily/hourly caps, throttle, CTR threshold, ...) from a backend (Firebase
  Remote Config, a self-hosted API, ...) without an app store release.
  Provider-agnostic — no new dependency added. A slow (>5s), throwing, or
  `null`-returning provider falls back to the local `config.safety`
  unchanged; each override key is independently validated. Ad-unit-ID
  remote override was considered but is out of scope for this first pass —
  see the ticket for why.

### Removed

- `Backoff` (from `src/state/backoff.dart`) is no longer exported from the
  package barrel (T78). It was always an internal detail of
  `AdSlot.beginLoad()`'s default cooldown parameter — not referenced by
  any documented public API. If you constructed one directly, import
  `package:applovin_admob_sdk/src/state/backoff.dart` instead.

## [2.0.4] - 2026-08-09

Docs-only. No code changes. Prompted by an independent multi-agent audit
(Claude/Codex/Gemini, `doc/audit/audit_*.md`) flagging that the pubspec
description overclaimed "Offline VIP redeem".

### Changed

- pubspec `description` — "Offline VIP redeem" → "Offline-verified VIP
  codes". The Ed25519 signature check is fully offline, but
  `redeemSignedKey` has rejected the redeem *attempt* while offline since
  2.0.1 (deliberate anti-abuse gate) — the old wording implied the whole
  flow works offline, which it hasn't since that release.
- README — added a "Known limitation — redeem attempt requires
  connectivity" callout next to the signed-VIP-keys section, spelling out
  the same distinction.

## [2.0.3] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — a Quickstart section with the minimal
  `setNavigatorKey`/`navigatorObservers`/`requestUmpConsent`/`initialize`/
  `buildBanner` snippet, so the pub.dev "Example" tab is self-contained
  instead of only linking out to the package README.

## [2.0.2] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — an index of the 16 demo pages in `example/lib/main.dart`
  (one row per page: what it demonstrates), so the pub.dev "Example" tab has
  something to navigate besides a 2,500+ line raw file.

## [2.0.1] - 2026-08-09

Non-breaking bug fixes, cross-checked by three independent agents (Codex,
agy, a second Claude instance) with every finding verified against the
source. 698/698 tests pass; manually verified on a real Android device.

### Fixed

- **`AdManager.initialize()` bounded auto-retry.** A failed adapter init
  (bad ad unit ids, missing native config, transient SDK error) now retries
  up to 3 times with backoff (5s/15s/30s) before giving up for the session,
  instead of leaving the host permanently uninitialized until the next app
  launch or an explicit re-`initialize()` call.
- **`onComplete` now fires exactly once per host-initiated `initialize()`
  call.** Previously it could fire on every failed attempt in addition to
  the terminal outcome (up to 4 times across the retry budget), violating
  the 1.x callback contract of firing once with the final result.
- **Stale internal-retry flag could leak into a later legitimate call.** A
  retry timer firing while another `initialize()` call already held the
  busy guard left `_isInternalInitRetryCall` stuck `true`, causing the next
  real host-initiated call to be misclassified as an internal retry.
- **`VipManager` clock-rollback guard applied consistently.** The
  clock-rollback-resistant "now" getter (`_effectiveNow`, clamped against a
  persisted high-water mark) was already used for expiry/stacking
  calculations but was missed in `_refreshGraceNudge` and
  `_scheduleNextExpiry`, which still read the raw device clock — a backward
  clock jump could desync the grace-nudge and next-expiry timers from the
  rest of the VIP state.

### Changed

- **`VipManager.redeemSignedKey` now rejects redemption attempts while the
  device is offline**, returning `VipRedeemStatus.invalid` with a
  "no network connection" message, before running Ed25519 signature
  verification. Deliberate anti-abuse tightening — a host at 2.0.0 that
  allowed a signed key to be redeemed while offline will see those attempts
  rejected at 2.0.1. Ed25519 verification itself is still fully offline
  (no server call, no shared secret); only the redemption *attempt* now
  requires connectivity.

### Known limitations (unchanged, not new in this release)

- `VipManager.redeemVip`'s separate host-supplied-validator path is not
  gated by the offline check above — only `redeemSignedKey` is. Consumers
  using `redeemVip` with their own validator should apply their own
  connectivity check if desired.
- `AdManager.isConnected` optimistically returns `true` if read before the
  connectivity watcher is ready, or if the platform check throws — a small
  fail-open window on cold start.

## [2.0.0] - 2026-08-02

Breaking. Comes out of a full audit against seven production requirements
(`doc/audit/audit_claude_20260802.md`), cross-checked by three independent
agents, with every finding verified against the source.

### Breaking

- **`autoRequestUmpConsent` now defaults to `true`.** With the old defaults
  (`false`, plus `disableAppLovinCmpFlow: true` and
  `autoShowConsentDialog: true`) a host that changed nothing tripped the
  consent-coverage footgun, which hard-blocks every ad request in a release
  build — and the built-in dialog could not clear the block, because it applies
  consent directly to the providers and never routes through `setConsent()`.
  The result was a release that requested **zero ads, silently**: the `assert`
  next to the block is stripped in release, leaving one log line. Hosts that
  already call `requestUmpConsent()` themselves are detected and the automatic
  call skips, so UMP still runs exactly once.
- **`maxVipStackDuration` now defaults to 90 days** instead of `null`
  (uncapped). Pass `null` explicitly for the old behaviour, knowing the only
  remaining ceiling is the ~100-year sanity bound in the key parser.
- **Signed VIP keys default to a new `AVP2` format** carrying an expiry and an
  app binding inside the signed payload. `AVP1` keys already issued still
  verify; `tool/vip_mint.dart` mints AVP2 unless `--v1` is passed.
- New dependency: `package_info_plus`, used to read the bundle id that AVP2
  keys are checked against.

### Fixed

- **Interstitial and rewarded ads could stack on each other.**
  `showAppOpenAdOnResume` checked the other two fullscreen slots and the dialog
  stack, but `showInterstitial` and `showRewarded` each checked only
  themselves, so a call while another fullscreen ad was showing put one ad on
  top of another — an AdMob and AppLovin policy violation.
  `AdSafetyConfig.canShowFullscreenAd()` does not cover this: it is a
  time-based frequency gate, not a state mutex. All three paths now share one
  predicate.
- **Banner/MREC/native loads ignored the consent, VIP, cap and connectivity
  gate — in both adapters.** None of the ten load entry points consulted
  `canReload`, so a resume after a banner error (or any other caller) could
  fire an ad request while `canRequestAds` was false, while the user was VIP,
  or past the daily cap. Requesting an ad with `canRequestAds == false` is a
  UMP policy violation, and it was invisible from the UI because the widget
  layer hides banners for VIP users anyway. The `canReload` seam existed on
  `AdMobAdapter` but was dead code — only AppLovin ever called it.
- **A failed UMP attempt was never retried.** On reconnect the SDK refilled ad
  slots but not consent, so an EEA user whose first launch had no network never
  saw a consent form for the rest of the process. Now retried on the
  offline→online transition, and only when the previous attempt actually
  failed, so a user who already answered is not asked again.
- **A UMP status of `unknown` silently downgraded a stored consent.** `unknown`
  means UMP could not determine anything, not that the user refused, but it
  mapped to `hasUserConsent: false` and overwrote a choice the user had already
  made — visible in the logs as `load → consent=true` followed by
  `set → consent=false`. Inconclusive results now leave the persisted value
  alone. `required` still maps to `false`: there the form is genuinely needed
  and was not completed.
- **The consent SDK could abort `initialize()`.**
  `requestConsentInfoUpdate` is a callback API returning `void`; when the UMP
  channel is not registered it throws from a future nobody awaits, so the error
  escaped as an unhandled zone error that a `try`/`catch` around the call could
  not catch. Unreachable while the default was `false`; now contained.

### Documentation

- `maxVipStackDuration`'s docstring claimed the non-stacking path was never
  clamped. It was wrong — `VipManager.addVip` has clamped both paths since the
  single-entry cap was added. (The year-2099 legacy-GAID migration grant really
  is exempt, but because it constructs its `VipEntry` directly.)
- README now states plainly that VIP anti-bypass is Keychain-durable on iOS and
  weak on Android, where clearing app data resets both the trial and key reuse,
  and that offline keys cannot be revoked.
- The example's demo keypair is now marked as public knowledge and unsafe to
  ship.


## [1.2.4] - 2026-08-01

Metadata only — no code, API or behaviour change from 1.2.3.

### Changed
- Shortened the package `description` and all three `screenshots:`
  descriptions to under 160 characters. pub.dev enforces two different limits
  and neither is reported by `pub publish --dry-run`: the upload API rejects
  anything over 200 characters, while pana's scoring wants under 160 or it
  drops 10 points from "Provide a valid pubspec.yaml" and another 10 from
  "Package has an example and has no issues with screenshots". 1.2.3 uploaded
  fine at 187-197 characters but scored 130/160 for that reason.

## [1.2.3] - 2026-08-01

### Fixed
- `autoRequestUmpConsent` was never honoured during `initialize()` — a host
  that opted into automatic UMP now actually gets the consent request before
  ad requests start (R10-A).
- A COPPA flag set mid-session now hard-stops AppLovin ad requests instead of
  only applying to the next SDK init (R10-B).
- `_retryRefillAds()` returns immediately while the device is offline, instead
  of burning retry budget on requests that cannot succeed (R10-C).
- `ConnectionNotifierTools.initialize()` is bounded by a 20s timeout, so a
  hung connectivity plugin can no longer stall SDK init indefinitely (R10-D).
- `_footgunBlocked` leaked across re-init: one release-mode `initialize()`
  could permanently block ads for every later init in the same process. The
  same bug class then recurred for `_umpRequested` / `_consentExplicitlySet`,
  so `destroy()` and the re-init branch now share one `_resetGuardState()`
  instead of two hand-maintained reset lists.
- `applyDryRunReleaseGuard()`'s `isRelease` is threaded into the last two call
  sites (the `ad_manager.dart` consent-footgun guard and the `VipManager`
  constructor) that still fell back to raw `kReleaseMode` under `flutter test`.

### Changed
- Example app now mirrors the host's Android Auto Backup configuration, so the
  VIP-reinstall-replay path behaves the same in the example as in production.
- `SafeLogger`: `critical()` and `e(bypassLevel: true)` consolidated onto one
  internal `_e()`; `_shouldLog`'s `bypassLevel` branches merged.
- `VipManager`'s `isRelease` parameter is no longer `@visibleForTesting`
  (mirrors `ad_safety_config.dart` — the safety comes from
  `isActuallyRelease()`, not from a compile-time restriction).
- Added `repository` / `homepage` / `issue_tracker` / `topics` and an explicit
  `platforms: android, ios` to the pubspec; whole package reformatted with
  `dart format`. No API or runtime change.

### Documentation
- Explained why interstitial and rewarded ads intentionally have no watchdog,
  unlike App Open (R10-E).

## [1.2.2] - 2026-07-20

### Changed
- `SafeLogger`'s default log level is now `kDebugMode`-based (verbose in
  debug, warning-and-above in release) instead of always-verbose — a host
  that never calls `AdManager.setLogLevel()` no longer leaks raw GAID and
  other diagnostic detail into release logs by default.
- The consent-coverage footgun (AppLovin CMP disabled + `autoRequestUmpConsent`
  false + `requestUmpConsent()` never called before `initialize()`) now hard-
  blocks ad requests in release builds (`kReleaseMode`), not just a dev-time
  `assert()` (which strips in release and was previously log-only in
  production). The block clears automatically the moment `setConsent()` is
  called — directly by a host's own consent UI or internally by
  `requestUmpConsent()` — and triggers a refill of any ad slots held back
  while it was active.

### Fixed
- `NativeAdWidget`'s `MaxNativeAdView` listener callbacks now check
  `adapter.isInitialised` before writing to its `ValueNotifier`s or firing a
  click event, closing the same disposed-adapter race already guarded on the
  AppLovin banner/mrec views.

## [1.2.1] - 2026-07-19

### Added
- `VipManager.firstInstallGrantDueListenable` — fires once when the
  first-install VIP grace window is granted (previously silent/log-only),
  paired with `lastFirstInstallGrantDuration` and
  `acknowledgeFirstInstallGrant()`. Mirrors the existing
  `graceNudgeDueListenable` pattern. `AdManager.initialize()` now calls
  `notifyFirstInstallGrant()` right after granting the window.

## [1.2.0] - 2026-07-19

### Added
- `RevenuePanel` gained an optional `debugModeOverride` constructor param
  (test-only seam, `@visibleForTesting`) so the widget's `kDebugMode` gate
  can be exercised from `flutter test`.

### Changed
- `SimpleEventBus` now replays the last-fired event to a listener that
  subscribes *after* the event already fired, closing a gap where late
  subscribers silently missed init-completion signals. `clearAll()` (called
  from `AdManager.destroy()`) resets the replay buffer.
- `RevenuePanel` now fully gates on `kDebugMode` (or the override above): no
  event subscription and `SizedBox.shrink()` render in release builds,
  instead of only skipping the visual chrome.

### Fixed
- `ad_manager.dart` escalates the existing silent log warning for a
  misconfigured consent flow (AppLovin CMP disabled, `autoRequestUmpConsent`
  false, `requestUmpConsent()` never called before `initialize()`) to a
  dev-time `assert()` — asserts strip in release, so production behavior is
  unchanged, but dev/test builds now fail loudly instead of silently
  shipping with no consent flow.
- `requestUmpConsent()` now logs a warning if called before `requestAtt()`
  on iOS (ATT must run first per platform policy) — log-only, non-blocking.

### Docs
- Clarified in the README: the AdMob-per-request-tag vs. AppLovin-full-abort
  COPPA asymmetry is intentional (each provider's native API surface
  differs), not an inconsistency; `enableFillRateMonitor`/`enableArbitrator`
  are production-safe opt-in tools with no `kDebugMode` distinction; UMP→
  AppLovin consent sync is boolean-only by design since AppLovin MAX SDK
  12.0.0+ auto-reads the IAB TC-String directly; pointers to the existing
  CCPA `CupertinoSwitch` pattern and `consent_dialog.dart`'s binary-only
  rationale for hosts that need more UI; noted the Android VIP-key
  reinstall-replay limitation.
- `example/ios/Runner/Info.plist` synced from 50 → 152 `SKAdNetworkItems`
  entries to match the host app.

## [1.1.1] - 2026-07-18

### Changed
- Bumped `confetti` `^0.7.0` → `^0.8.0` and `connection_notifier` `^2.0.1` →
  `^4.1.0` (dependency freshness, closes Pub Points "up-to-date dependencies"
  gap). No API surface used by this package (`ConnectionNotifierTools
  .initialize()`/`.isConnected`/`.onStatusChange`) changed across
  `connection_notifier`'s 3.x/4.x majors — those breaking changes only
  affected its widget/UI layer, which this SDK doesn't use.

## [1.1.0] - 2026-07-18

### Added — Native Ad format v1 (`buildNative()`)
- New `AdSlotType.native` + `AdScreen.buildNative()`. AdMob renders via
  Google's `NativeAd`/`NativeTemplateStyle(templateType: TemplateType.medium)`
  (same preload-then-`AdWidget` pattern as banner/MREC; the template
  self-draws its own "Ad"/AdChoices label). AppLovin renders via a
  self-contained `MaxNativeAdView` with a custom Dart child layout
  (`MaxNativeAdIconView`/`TitleView`/`MediaView`/`BodyView`/
  `CallToActionView`), for which the package self-draws its own "Ad"
  compliance badge (mirrors MREC's `_MrecContainer` badge). v1 ships one
  fixed layout — not a customizable editor. See README § "Native Ad (v1)".

### Added — MREC ad format (`buildMrec()`)
- Medium-rectangle banner variant (`AdSlotType.mrec`), same lifecycle shell
  as banner (RouteAware pause/resume, VIP suppression, offline collapse,
  auto-refresh gate).

### Added — Smart Monetization Arbitrator + fill-rate monitor
- `monetization_arbitrator.dart`: opt-in per-slot provider arbitration with a
  guardrail against flapping between providers. `fill_rate_monitor.dart`:
  tracks per-slot fill rate over a rolling window for arbitration decisions
  and diagnostics.

### Added — Mediation waterfall reporting
- Adapters now surface mediation waterfall/network response data through the
  existing `AdEvent` stream for host-app-side analytics.

### Added — Consent-country analytics
- Consent events now carry the resolved consent country (GDPR/CCPA scope) so
  host apps can break down consent-rate metrics by region.

### Added — Config validation preflight
- `ad_diagnostics.dart` / `integration_self_check.dart` gained checks that
  catch common misconfiguration (missing ad unit IDs, mismatched provider
  config) before the SDK starts requesting ads.

### Fixed — [High] `AppLovinAdapter.preloadMrec()` crashed the host app when MREC wasn't configured
- `AdManager.initialize()` (and the VIP-loss handler) unconditionally
  preload the MREC slot alongside banner, regardless of whether the host
  app actually uses `buildMrec()`. For AppLovin, an unconfigured MREC
  resolves `AppLovinConfig.mrecId` to its default empty string, and
  AppLovin's native `MaxAdViewImpl.loadAd()` throws
  `IllegalArgumentException: No Ad Unit ID specified` synchronously inside
  an Android `Handler` callback — outside Dart's platform-channel
  try/catch, so it crashed the whole process instead of surfacing as a
  catchable Dart error. Any AppLovin-provider host app that doesn't
  configure MREC (i.e. virtually all apps, since MREC only shipped this
  release) would crash on every SDK init. `preloadMrec()` now skips the
  native preload entirely when `cfg.mrecId` is empty.

### Fixed — [High] `AppOpenTrigger.splashOnly`/`resumeOnly` only gated the SHOW path, not LOAD
- `showAppOpenAd`/`showAppOpenAdOnResume` respected `appOpenTrigger`, but
  `loadAppOpenAd()` (init/VIP-change/retry-refill) never checked it — under
  `splashOnly`/`resumeOnly` the App Open slot kept getting refilled and could
  sit `ready` indefinitely (AppLovin has no AdMob-style 4h TTL), wasting
  network requests/fill quota. Default `both` was unaffected (both gates are
  no-ops there). Now gated behind the same `appOpenTrigger` check as the show
  path.

### Fixed — `redeemVip()` demo mode (`validator == null`) no longer accepts any key in release builds
- Legacy `redeemVip()` accepts any key when `AdConfig.vipKeyValidator` is
  `null`, intended as a zero-config demo mode. A host app that forgot to wire
  a validator would ship this silently — any user typing any string got free
  VIP. `_runValidator` now refuses (`return false`) when `validator == null`
  and `kReleaseMode` is true; debug/profile builds keep the original
  demo-mode passthrough so wiring the integration still works without a
  validator during development. Does not affect `redeemSignedKey()`
  (Ed25519-verified, the path production code actually uses).

## [1.0.24] - 2026-07-16

> Published in two commits the same version: 2026-07-10 (consent-on-init +
> ATT/UMP timeout fixes below) then 2026-07-16 (privacy-options timeout +
> CCPA toggle + SKAdNetwork expansion + doc fixes). Both are live on pub.dev
> under `1.0.24` — the split below is historical, not two releases.

### Fixed — `requestPrivacyOptionsFlow()` could hang forever on a served-but-never-dismissed form (T44)
- The native "Privacy Options" form's dismiss callback only fires after
  `ConsentForm.showPrivacyOptionsForm()`'s own platform call resolves; awaiting
  that call directly (as the code did) meant a stuck/never-dismissed form hung
  the whole call with no way out — bypassing an already-added completer
  timeout that could never be reached. Fixed by not awaiting
  `showPrivacyOptionsForm()` directly (matching the existing fire-and-forget
  shape already used for `requestUmpConsentFlow()`'s form show/dismiss) and
  applying the 20s timeout to the dismiss `Completer` that its callback feeds.
  Test: `test/ump_consent_test.dart`.

### Added — CCPA "Do Not Sell or Share My Info" toggle on `VipRedeemScreen`
- New optional `doNotSellValue`/`onDoNotSellChanged` params render a switch in
  the privacy footer (next to Privacy Policy/Privacy Options), letting a host
  app wire it straight to `AdManager().setConsent(AdConsent(doNotSell: ...))`.
  Opt-in only — omitting `onDoNotSellChanged` (the default) renders the same
  footer as before.

### Docs
- Added a "Known limitations — read before adopting" section to the README
  (ad-policy risk sits with AppLovin/Google, not this package; the real
  ad show/dismiss lifecycle is only partially automatable — 3/15
  integration_test scenarios are manual-only; limited real-world production
  history beyond this repo's own host app; single maintainer, no SLA).
  Written for anyone evaluating this SDK for a new app/partner before a
  wholesale integration.

### Fixed — auto-reload paths bypassed VIP/consent/cap/connectivity gates
- App-Open, Interstitial, and Rewarded adapters (`applovin_adapter.dart`) all
  refill ads directly from their own `onAdHidden`/`onAdDisplayFailed` native
  callbacks, bypassing `AdManager.loadX()` and therefore its gates entirely.
  A user who just redeemed VIP, went offline, or revoked consent could still
  trigger an outbound ad request from a stale in-flight callback. Fixed by
  adding a `canReload()` check (`AdManager` wires it to
  `!_isVipMember && !AdSafetyConfig.dailyCapReached() && _canRequestAds && isConnected`)
  immediately before every such reload call site.

### Fixed — consent silently overwritten by stale data on every `initialize()`
- `AdManager.setConsent()` called before `initialize()` (the real app startup
  order: `requestUmpConsent()` → `initialize()`) used to only mutate an
  in-memory field and return early, because `ConsentManager` wasn't bootstrapped
  yet. `initialize()`'s subsequent `ConsentManager.bootstrap()` then
  unconditionally reloaded the previous session's **stale** persisted consent
  and overwrote it — silently discarding the fresh UMP result on every app
  launch. Fixed by buffering the pending `ConsentSettings` in a new
  `_pendingConsentSettings` field and re-applying it right after bootstrap, so
  it wins over the just-loaded stale data; the buffer is cleared on
  `destroy()` so it never leaks into an unrelated future `initialize()`. Test:
  `test/consent_persistence_on_init_test.dart`.

### Fixed — ATT/UMP consent native awaits could hang `initialize()` forever (T43)
- `requestAttIfNeeded()` and `requestUmpConsentFlow()` each awaited a native
  modal-dismiss (or network) callback with **no timeout**. If the OS/native
  side never resolved it (ATT prompt throttled by rapid repeated launches;
  a UMP form served but never tapped through; a dead network on
  `requestConsentInfoUpdate`), the whole `initialize()` chain never ran —
  the ad SDK stayed silently uninitialized for that app session. All three
  awaits are now wrapped in `Future.timeout(Duration(seconds: 20), onTimeout:
  () => <safe fallback>)`, mirroring the existing App-Open watchdog pattern.
  `requestPrivacyOptionsFlow()`'s dismiss await is deliberately not part of
  this fix — it's a user-initiated re-consent action outside the app-boot
  gating chain. Tests: `test/att_consent_test.dart`, `test/ump_consent_test.dart`
  (`fakeAsync` + never-completing `Completer`, mocking the real
  `google_mobile_ads` UMP method channel with its custom
  `StandardMethodCodec(UserMessagingCodec())`).

### Added — `ssvUserId`/`ssvCustomData` on `AdScreenState.showRewardedAd()`
- `AdManager.showRewardedAd()` already accepted `ssvUserId`/`ssvCustomData` for
  server-side reward verification, but the `AdScreenState.showRewardedAd()`
  convenience wrapper (`lib/src/core/ad_screen.dart`) that most host screens
  actually call did not expose or forward them — any caller passing those
  named args failed to compile. Added both as optional parameters, forwarded
  as-is to the underlying `AdManager` call; no change to the wrapper's
  existing safety-check/disclosure-dialog behaviour.

### Added — durable redeemed-key ledger for signed VIP keys on iOS
- New `RedeemedKeyLedger` (`lib/src/vip/_redeemed_key_ledger.dart`) backs
  `VipManager.redeemSignedKey`'s one-time-use check with an iOS Keychain
  entry, alongside the existing `AdPreferences` (SharedPreferences) check.
  `AdPreferences` alone is wiped on uninstall, so a user could
  uninstall/reinstall to redeem the same signed key repeatedly; the Keychain
  entry survives that. Android intentionally has no durable backstop here,
  same reasoning as the existing `FirstInstallGuard` (no local primitive
  survives uninstall without an install-referrer plugin for a narrow
  benefit) — `AdPreferences` remains the sole check there. Fails open: any
  Keychain read/write error is swallowed and treated as "not redeemed" so a
  storage hiccup never locks out a legitimate key. Test:
  `test/redeemed_key_ledger_test.dart`.

### Added — VIP grace-period expiry nudge
- `VipManager` exposes `graceNudgeThreshold` (default 24h),
  `graceNudgeDueListenable`, and `acknowledgeGraceNudge()`. Once a VIP
  entry's `expiresAt` comes within the threshold, the nudge notifier flips
  true so the host UI can prompt the user to redeem/extend before ads
  resume; acknowledging persists the current `expiresAt` so the same expiry
  doesn't re-nudge, but stacking a new expiry (redeem/watch-ad-to-extend)
  makes it due again. Inactive/no-VIP state is never due. Test:
  `test/vip_manager_grace_nudge_test.dart`.

### Added — VIP entries integrity checksum
- `AdPreferences.getVipEntriesRaw()`/`setVipEntriesRaw()` now store an
  FNV-1a checksum alongside the VIP entries JSON, as a single combined
  `SharedPreferences` value (`'<checksum>|<json>'` written via one
  `setString` call). A mismatched checksum is logged and treated as absent
  data, deterring casual on-device editing of the plaintext VIP entries to
  self-grant free ad-free time — this is a tamper *deterrent*, not
  root/jailbreak-proof protection (a rooted device can still recompute the
  checksum). Pre-upgrade data with no checksum is trusted once and
  backfilled into the new format. FNV-1a was chosen over `String.hashCode`
  (not stable across Dart/Flutter versions) and over the existing async
  `cryptography`-package HMAC (would force every VIP-entries caller async).
  Note: an earlier two-separate-keys design was replaced with the single
  combined key above after it surfaced a real race — a concurrent
  fire-and-forget `VipManager._save()` write could be observed mid-flight
  with one key updated and the other still stale, causing a false
  "tampered" read. Test: `test/ad_preferences_test.dart`.

### Changed — native ad SDK dependency pins retested, still blocked upstream
- Retested bumping `applovin_max`/`gma_mediation_applovin` to the latest
  upstream versions (`4.6.4`/`2.6.1`) to see whether the CocoaPods
  version-pin conflict documented in the host `pubspec.yaml`
  `dependency_overrides` had been resolved. It has not: `2.6.1` now
  requires `meta ^1.17.0`, while `flutter_test` from the CI-pinned Flutter
  SDK (3.35.1) forces `meta 1.16.0` — a Dart-level version-solve conflict,
  never even reaching the CocoaPods layer. No SDK code change; the pins
  stay at `applovin_max 4.6.0` / `google_mobile_ads 6.0.0` /
  `gma_mediation_applovin 2.5.1` in the host app. See
  `doc/audit/audit_partner_lead_20260710.md` findings #2/#3.

### Added — Privacy Options footer button on VipRedeemScreen (T28)
- `VipRedeemScreen` gained `onPrivacyOptionsTap` (`VoidCallback?`) and
  `VipRedeemStrings.privacyOptions`, mirroring the existing
  `onPrivacyPolicyTap`/`privacyPolicy` pair. The footer now renders whichever
  of the two buttons has a non-null callback (previously only the privacy
  policy button existed). Closes the gap where `AdManager().showPrivacyOptions()`
  (T06) had no host call site — GDPR requires a durable re-consent entry
  point, not just a one-time policy link. Test: `test/vip_redeem_screen_test.dart`
  (footer hidden/shown/tap cases for `onPrivacyOptionsTap`).

### Added — rewarded disclosure hook on `AdScreenState.showRewardedAd` (T22)
- `showRewardedAd` gained optional `disclosureTitle`/`disclosureSubtitle`/
  `disclosureButtonLabel`/`disclosureCancelLabel` params. When
  `disclosureTitle` is set, a confirm dialog naming the reward is shown right
  before the ad plays; declining calls `onEarnedReward(false)` and never
  reaches the ad. Omitted (default): behaviour is unchanged — return type
  changed `void` → `Future<void>`, non-breaking via Dart's void-return
  covariance. Test: `test/ad_screen_test.dart` (`rewarded disclosure hook`
  group — confirm/cancel paths).

### Added — load-time daily safety cap gate (T21)
- `AdSafetyConfig.dailyCapReached()` is a new pure read-only check (no
  CTR-anomaly side effects, unlike `canShowFullscreenAd()`). `loadAppOpenAd`/
  `loadInterstitial`/`loadRewardedAd` and the periodic `_retryRefillAds` scan
  now skip preloading once the daily fullscreen-ad cap is hit — previously
  the cap was only enforced at *show* time, so a capped-out user kept
  burning ad-network load requests that could never convert. VIP members are
  unaffected (the existing VIP guard already returns before this check runs
  in every call site). Test: `test/daily_cap_load_gate_test.dart`,
  `test/ad_safety_config_test.dart` (`dailyCapReached` group).

### Fixed — trial hardening: anti clock-rollback + grace-disabled footgun (T17)
- `VipEntry.isActive`/`remaining` now also check `now.isBefore(grantedAt)` —
  previously only `now.isBefore(expiresAt)` was checked, so rolling the
  device clock backwards past a grant's `expiresAt` made an
  already-expired-by-real-time entry "come back to life". A rolled-back
  clock is now treated as the entry having already been consumed
  (fail-safe), not as extra time granted. `VipManager`'s purge/active/
  stacking logic needed no change — everything already routes through
  `VipEntry.isActive`. Test: `test/vip_entry_test.dart` (`anti
  clock-rollback (T17)` group).
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment) when
  `AdConfig.firstInstallVipGrace` is `.disabled` — previously a partner
  could silently ship with no ad-free first-install trial. Test:
  `test/ad_manager_core_test.dart` (`firstInstallVipGrace` cases in the
  `releaseFootgunWarnings` group).

### Added — ad-unit-id validation in release footguns (T16)
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment as the existing dryRun/
  Google-test-id guards) when: any resolved `bannerId`/`interstitialId`/
  `appOpenId`/`rewardedId` is empty, or (AdMob provider only) an id doesn't
  match AdMob's `ca-app-pub-<16 digits>/<ad-unit id>` format — the classic
  "pasted an AppLovin id into the AdMob config" mistake. Test:
  `test/ad_manager_core_test.dart` (`releaseFootgunWarnings` group).

### Added — per-platform ad-unit ids (T15)
- `AdMobConfig`/`AppLovinConfig` gained optional `android*Id`/`ios*Id`
  overrides for `bannerId`/`interstitialId`/`appOpenId`/`rewardedId` (e.g.
  `androidBannerId`, `iosBannerId`). Resolved via `Platform.isAndroid`/
  `Platform.isIOS` at read time, falling back to the existing single id when
  no override is set — fully backward compatible. Test:
  `test/ad_config_platform_test.dart`.

### Added — Privacy Options entry point + re-consent (T06)
- `AdManager().isPrivacyOptionsRequired()` and `AdManager().showPrivacyOptions()`
  (wrapping `ConsentInformation.getPrivacyOptionsRequirementStatus` +
  `ConsentForm.showPrivacyOptionsForm`) are now documented in the README as the
  **required durable re-consent entry point** Google's UMP policy mandates
  (a permanent "Privacy Settings" button). `showPrivacyOptions()` safely no-ops
  (no native UI) when Google doesn't require it for the current user, and
  re-applies the resulting consent to the active ad provider (npa/RDP) when it
  does. Test: `test/privacy_options_test.dart` — required→opens form,
  notRequired→no-op, re-consent re-applies to the active adapter.

### Added — shared `VipRedeemScreen` widget
- Extracted the full VIP redeem screen (hero status, key input, watch-ad-extend,
  active-entries list, buy placeholder, confetti) into the SDK as a reusable
  `VipRedeemScreen` + `VipRedeemStrings` (localizable, mirrors the
  `ConsentDialogStrings` pattern). The host and the SDK example now render the
  **identical** screen — host injects Vietnamese strings, the example uses the
  English defaults. Privacy-policy opening is a callback (`onPrivacyPolicyTap`)
  so the SDK needs no `url_launcher` dependency; `confetti` is added.
- Widget tests: renders inactive state + privacy-footer visibility. Verified on
  a Samsung S24 Ultra.

### Fixed — code-review follow-ups
- VIP: `redeemSignedKey` now claims the key id **atomically** (synchronous
  check + in-flight set) so a concurrent double-tap of the same signed key can't
  slip past the one-time-use check and grant twice. Enforced in the SDK, not
  just the host UI. Test: concurrent double-redeem grants exactly once.
- Consent: `initialize()` logs a **loud runtime warning** when AppLovin's CMP is
  disabled AND `autoRequestUmpConsent` is false AND `requestUmpConsent()` was
  never called before init — the "no consent form anywhere" footgun. Runtime,
  not config-static, so it never false-alarms hosts that gather consent in
  their splash.

### Improved — offline/network UX (T09 + T10)
- T09: verified the banner **collapses** to a zero-size box when offline (no
  shimmer / battery drain) and **reloads automatically on reconnect** (via the
  T08 connectivity watch bumping `initRevision`). Added a widget test.
- T10: `isConnected` now falls back to the **last-known** connectivity state
  (from the T08 watch) with a warning log instead of a silent `true` when the
  detector is unavailable. Kept optimistic on purpose — a broken detector must
  not permanently block ads; genuine offline loads just fail and back off, and
  the watch refills on reconnect (network-error fast-retry is subsumed by T08).

### Hardened — lifecycle & memory (T11 + T12 + T13)
- T13: `AdLoadingDialog.resetState()` (called by `AdManager.destroy()`) now pops
  a still-showing dialog before clearing its flags, so a mid-dialog destroy /
  re-init can't strand a non-dismissable loading dialog on the navigator.
  (`_eventStream` is intentionally left open — it's a process-lifetime singleton
  broadcast exposed publicly; closing it would break host subscribers and it is
  bounded to one instance, so it is not a leak.)
- T11: added regression tests proving the fullscreen single-use guard — a
  second show while one is showing is rejected by the slot state machine
  (`isReady` + atomic `beginShow` + null-on-dismiss), a disposed ad is never
  re-shown, and dispose happens exactly once. (No code change needed; the guard
  already existed — the tests lock it down.)
- T12: `BannerAdWidget` now guards against stacking multiple post-frame
  `_initBanner` callbacks (`_initScheduled`) when `build` runs repeatedly, so a
  banner loads exactly once across rebuilds. (`loadBannerIfNeeded` already
  bailed on a cached ad; this removes the wasteful callback pile-up.)
  (dispose-before-recreate was already handled by that early-return.)

### Added — consent gate + UMP as single CMP (T01 + T03)
- **`AdManager.canRequestAds`** consent gate: every load path (app-open,
  interstitial, rewarded, banner) AND every show path now skips when consent
  hasn't been granted, mirroring Google UMP's `ConsentInformation
  .canRequestAds()`. `requestUmpConsent` stores the result and, when the gate
  opens (blocked→allowed), refills the held slots. Google policy: never request
  or show an ad while `canRequestAds` is false. Defaults `true` so non-UMP /
  non-EEA hosts are unaffected.
- **`AdConfig.autoRequestUmpConsent`** (default false): when true,
  `initialize()` runs UMP before the first ad request and gates on the result —
  the SDK owns the whole consent flow. `umpTagForUnderAgeOfConsent` forwards the
  under-age flag.
- **`AdConfig.disableAppLovinCmpFlow`** (default true): the AppLovin adapter
  disables AppLovin's own Terms & Privacy (CMP) flow so UMP is the single
  consent prompt — no double prompt. UMP's result is still forwarded to AppLovin
  via `setHasUserConsent`.
- **T03**: the splash App Open ad (even `bypassSafety: true`) no longer shows an
  impression before consent is resolved; the show gate also prevents a
  previously-loaded ad from showing after consent is revoked.

### Added — offline signed VIP keys (T18)
- New `verifySignedVipKey` + `VipManager.redeemSignedKey` verify Ed25519-signed
  keys **offline** against an embedded public key. Only the public key ships, so
  a decompiler cannot forge new keys (the old local base64 map could be extracted
  and reused infinitely). VIP duration is encoded in the key.
- Per-device one-time-use: a redeemed key id can't be redeemed again on the same
  device (`AdPreferences` redeemed-id store). Global one-time-use still needs a
  server — documented as a known offline limitation.
- New deps: `cryptography` (pure-Dart Ed25519). Tooling: `tool/vip_keygen.dart`
  (generate a key pair) and `tool/vip_mint.dart` (mint signed keys with the
  private key — never shipped). See README → "Signed VIP keys".
- Host `vip_keys.dart` now holds only the public key + demo keys; `vip_screen`
  redeems via `redeemSignedKey`.

### Added — connectivity auto-refill on reconnect (T08)
- The SDK now initialises `ConnectionNotifierTools` (nobody did before, so
  `isConnected` silently always returned `true` and the offline guards never
  fired) and subscribes to `onStatusChange`.
- On an offline→online transition the SDK refills idle/cooldown ad slots,
  nudges the banner preload, and bumps `initRevision` so banner widgets re-init
  — within ~1s (debounced) instead of waiting up to 5 min for the poll timer.
  Suppressed for VIP members and while uninitialised. Subscription cancelled on
  `destroy`. Test seams: `debugConnectivityChanged`, `debugReconnectDebounce`.

### Fixed — AdMob non-personalized ads (`npa`) now actually applied (T02)
- Previously `applyConsentToProviders` only set AdMob's global
  `RequestConfiguration` (COPPA/age tags) and never attached the per-request
  non-personalized flag, so a user who declined consent could still be served
  **personalized** AdMob ads. The doc comment claimed an `npa` extra was
  forwarded, but no code did so.
- `AdProviderAdapter` gains `applyConsent(AdConsent)`. `AdMobAdapter` maps
  `!hasUserConsent` → `AdRequest(nonPersonalizedAds: true)` on **every** load
  (banner, interstitial, rewarded, app open); it defaults to non-personalized
  until consent is applied and resets to that on `dispose`. `AppLovinAdapter`'s
  implementation is a no-op (it forwards consent via static `AppLovinMAX` APIs).
- `AdManager` calls `applyConsent` on the adapter at init, from `setConsent`,
  and on any `ConsentManager` change (auto dialog / set / reset / privacy
  screen), so personalization tracks consent across every path.
- Tests: adapter-level npa propagation + AdManager wiring (integration) +
  UI-driven consent (widget). Example app shows a live "personalized vs
  non-personalized" indicator on the Consent page.

## [1.0.23] - 2026-06-15

### Changed — App Open ad never stacks on top of a modal
- `AdScreenRouteLogger` now tracks how many `PopupRoute`s (dialogs, bottom
  sheets, Cupertino popups) are on the navigation stack and exposes
  `AdScreenRouteLogger.isDialogOnTop`. `showAppOpenAdOnResume` consults it (plus
  `AdLoadingDialog.isShowing`) and **skips the App Open ad while any dialog is
  presented** — e.g. the consent dialog or a VIP redeem confirmation. Showing a
  fullscreen ad over a modal is bad UX and an AdMob policy risk. The counter is
  reset by `AdManager.destroy()` so a mid-dialog teardown can't wedge it.

### Fixed — retry-refill scan bails early for VIP members
- `_retryRefillAds` now returns immediately when the user is a VIP member.
  Each `load*()` already guarded on VIP, so behaviour is unchanged, but this is
  a defense-in-depth backstop and avoids a pointless periodic scan/log.

## [1.0.22] - 2026-06-15

### Added — VIP time stacking + rewarded-while-VIP
- `VipManager.addVip` and `redeemVip` gained a `stack` flag (default `false`,
  fully backward compatible). With `stack: true`, the grant **accumulates onto
  the latest expiry across ALL active entries** (global stacking) — so VIP time
  from every source (redeem code, watch-ad) adds to one growing window (e.g. ~6
  active days + a 30-day code ⇒ ~36 days). The granted key's entry becomes the
  new latest (created if new, updated if it existed) and `grantedAt` resets to
  now. Without `stack`, the default latest-expiry-wins replacement is unchanged.
- `AdManager.showRewardedAd` gained a `bypassVipGuard` flag (default `false`).
  When `true`, a VIP member can voluntarily watch a **real** rewarded ad (e.g. to
  extend their own VIP window). Since the rewarded slot is not preloaded while
  VIP, the SDK loads it on demand and waits before showing. No auto-grant — the
  reward is still only earned by completing the ad. Policy-compliant (a real ad
  is shown).
  - On-demand load observes the slot's **public** `AdSlot.state` notifier (not
    the internal `pendingCallback`), with a caller-tunable `onDemandLoadTimeout`
    (default 15 s) param on `showRewardedAd`.
  - A blocking `AdLoadingDialog` covers the on-demand wait (new
    `AdLoadingDialog.show()` / `dismiss()` non-timed pair).
  - `showRewardedAd` is now **re-entrancy-safe**: a second call while a first is
    mid load/show is rejected (`onEarnedReward(false)`), independent of any
    caller-side lock.
- `AdConfig.maxVipStackDuration` (default `null` = uncapped) — optional cap on
  the **total** window produced by stacking. When set, a stacked grant is clamped
  to `now + maxVipStackDuration`. Plumbed to `VipManager` at init.

### Tests
- +24 tests (222 total). `vip_manager_stacking_test.dart` (13 — global stacking
  incl. cross-key + order-independence, cap clamp, persistence, notifier,
  watch-ad fixed-key); `rewarded VIP-bypass` group in `ad_manager_core_test.dart`
  (6 — default vs. bypass, on-demand success/failure, non-VIP, re-entrancy guard);
  `rewarded_ondemand_dialog_test.dart` (2 widget — cold-VIP loading dialog during
  async on-demand load + timeout dismissal).

## [1.0.21] - 2026-06-15

### Changed — dependency refresh
- `google_mobile_ads` `^6.0.0` → `^7.0.0`, `flutter_secure_storage` `^9.2.4` →
  `^10.0.0`, `applovin_max` `^4.6.3` → `^4.6.4`. No public-API change; all 132
  tests pass. (Bumping `google_mobile_ads` to 8/9 requires Dart ≥3.10 / a newer
  Flutter, so 7.x is the current ceiling; `connection_notifier` is kept at
  `^2.0.1` because `^4` pulls `connectivity_plus 7`, which conflicts with hosts
  on `connectivity_plus 6`.)
- Dropped the deprecated `encryptedSharedPreferences` AndroidOptions flag
  (flutter_secure_storage 10 auto-migrates).

### Example
- Interstitial demo now passes `placement: AdPlacement.levelComplete` to show
  per-placement revenue tagging; VIP demo documents the `AdConfig.vipDeviceGaids`
  allow-list + `isVIPMember()`.

## [1.0.20] - 2026-06-14

### Example only
- The bundled example (`example/lib/main.dart`) now demonstrates the recommended
  consent ordering in its splash: `AdManager().requestAtt()` →
  `AdManager().requestUmpConsent()` → `AdManager().initialize()`. No library /
  public-API change vs 1.0.19 — upgrading requires nothing.

## [1.0.19] - 2026-06-14

### Added — iOS App Tracking Transparency
- **`AdManager().requestAtt()`** / **`requestAttIfNeeded()`** — show the iOS ATT
  prompt when needed and return a structured `AttResult { status, idfa,
  allowsTracking }` (`AttStatus` enum). No-op on Android; never throws (degrades
  to `denied`). Call it in the splash **before** `requestUmpConsent`. Requires
  `NSUserTrackingUsageDescription` in `Info.plist`. Decoupled from the GDPR
  consent flag — the native SDKs read ATT directly for IDFA.

### Fixed
- **iOS App Open watchdog false-positive** — the lifecycle-aware show timeout no
  longer force-dismisses on iOS, where the ad shows while the app stays
  `resumed`. The "foreground = hung" heuristic is now Android-only; iOS relies on
  the native hidden/displayFailed callbacks plus the 90 s hard cap.
- **AppLovin reload-after-display-fail** — a slot is no longer stranded by the
  backoff window after a *show* failure; it refills immediately via the new
  `AdSlot.beginReload()` (genuine load failures still back off).
- **AdMob parity** — App Open now has a 90 s show watchdog; interstitial/rewarded
  honour a 1 h freshness expiry; the banner slot transitions to `loading` before
  the native `BannerAd` is created (fixes a synchronous-fill race).

### Internal
- Both adapters now load through an injectable bridge (`AppLovinBridge` /
  `GmaBridge`) for full behavioural unit-test coverage. No public-API change.

### Compliance / docs
- Removed the rewarded→interstitial reward fallback (rewarded-policy compliance);
  removed the interstitial on "Start" actions in the example host.

Upgrading from 1.0.18 requires no code changes for existing integrations. To use
ATT, add `NSUserTrackingUsageDescription` and call `AdManager().requestAtt()`.

## [1.0.18] - 2026-04-27

### No code changes
- Version bump only. Runtime behaviour, public API surface, and bundled
  assets are identical to 1.0.17. Upgrading from 1.0.17 to 1.0.18
  requires no code changes — only a `pubspec.yaml` version bump and
  `flutter pub get`.

## [1.0.17] - 2026-04-27

### Added — Anti-uninstall-bypass for first-install VIP grace (iOS-side)
- **`FirstInstallGuard`** (internal, `lib/src/vip/_first_install_guard.dart`) —
  protects the `firstInstallVipGrace` feature against the trivial bypass
  of "uninstall + reinstall to claim a fresh 24-hour grace window."
  Wired automatically inside `AdManager.initialize`; host apps need no
  code changes.
- **iOS defence** — writes a single boolean flag to the iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no
  `kSecAttrAccessGroup`). Keychain entries persist across app uninstall
  by default on iOS, so a reinstall on the same device finds the flag
  and the guard skips re-granting. Deliberately uses a constant flag
  rather than `identifierForVendor` (IDFV) — Apple resets IDFV when the
  user deletes all of a vendor's apps and reinstalls, which would let
  a standalone-app reinstall silently bypass the guard.
- **Android defence (host-app responsibility)** — there is no reliable
  local-only Play Install Referrer signal that distinguishes a fresh
  install from a reinstall (per Google's docs, referrer info is reset
  when the application is reinstalled). Real Android anti-bypass relies
  on the host app's **Auto Backup** configuration restoring
  `FlutterSharedPreferences.xml` (which contains the
  `prefs.isFirstInstallGraceApplied()` flag) on Play Store reinstall,
  short-circuiting the outer grace block before the guard runs. The
  guard itself returns `false` (allow grace) on Android — anti-bypass
  is performed entirely by the host's `AndroidManifest.xml` /
  `<data-extraction-rules>` + Google Cloud Backup.
- **Call-order guarantee (iOS)** — `AdManager` writes the Keychain
  anti-bypass flag *before* the `prefs.markFirstInstallGraceApplied()`
  flag, so a process kill between the two writes leaves the persistent
  marker set and the next install on the same device is still blocked.
- **Debug bypass** — `kDebugMode` builds skip both `hasAlreadyGranted`
  and `markGranted`, so QA can iterate on `flutter run` without the
  Keychain signal locking them out of the grace UX. Anti-bypass
  validation must happen on signed release builds (TestFlight / Play
  Store internal track).
- **Fail-open philosophy** — every storage error is caught and logged;
  the guard returns `false` (allow grace) so a transient Keychain
  hiccup never denies grace to a legitimate first-time user.
- **15 new unit tests** covering debug bypass, Keychain present/absent/
  tampered/error, Android always-grant behaviour, `markGranted`
  no-op on Android, idempotency, and fail-open error swallowing.

### Changed
- New required dependency for the iOS guard:
  - `flutter_secure_storage: ^9.2.4` — iOS Keychain wrapper.
- Approximate binary size delta: +400 KB (Keychain wrapper native code).

### Host-app integration notes
- **Android (required for anti-bypass)** — add Auto Backup configuration
  to `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <application
      android:allowBackup="true"
      android:dataExtractionRules="@xml/data_extraction_rules"
      android:fullBackupContent="@xml/full_backup_content">
  ```
  Create `android/app/src/main/res/xml/data_extraction_rules.xml`
  (Android 12+) and `full_backup_content.xml` (Android 6-11) including
  `FlutterSharedPreferences.xml` so Google Auto Backup restores the
  grace flag on Play Store reinstall.
  Without these, **Android anti-bypass does not work** — uninstall +
  reinstall always re-grants the grace window. (Acceptable for many
  apps; configure Auto Backup only if you want to block this bypass.)
- **iOS** — no host-side configuration required.

### Removed
- **`play_install_referrer` dependency** — initially included for an
  Android conservative-skip path, removed after research confirmed
  Install Referrer cannot detect Play Store reinstall (timestamps
  reset per Google's documented behaviour). Real Android anti-bypass
  comes from Auto Backup, not Install Referrer.

### Limitations (documented, not fixed)
- **iOS factory reset** ("Erase All Content and Settings") wipes
  Keychain → bypass succeeds. Acceptable; factory resets are rare.
- **Android Play Store reinstall without Auto Backup or within Auto
  Backup's ~24 h cache window** still bypasses the guard. This is a
  fundamental local-only limitation — closing it requires a backend
  (Firebase Anonymous Auth + Firestore, or a custom server).
- **iOS encrypted backup restore to a new device** could carry the
  Keychain flag onto the new device, denying that device's first
  install grace. Edge case; acceptable trade-off vs. weakening
  anti-bypass on the primary device.

## [1.0.16] - 2026-04-26

### Documentation
- **Full English rewrite of `README.md`** — restructured into 13 sections
  with table of contents. Quick start expanded into 6 copy-paste steps
  any Flutter developer can follow without prior AdMob/AppLovin knowledge.
  Added complete public API reference, FAQ, and dedicated Pitfalls section
  covering the `android:taskAffinity=""` issue (the most common cause of
  perceived crashes during background → foreground ad cycles).
- **Full English rewrite of `MIGRATION.md`** — clear 1.0.14 → 1.0.15
  upgrade path (no breaking changes), plus legacy 1.x → 2.x path with
  auto-migration details. Added Common issues and FAQ sections.
- **Full English rewrite of `doc/architecture.md`** — deep-dive for
  contributors and advanced integrators. Added detailed sections on the
  Smart App-Open timeout, Slot-state dismiss watcher, Consent flow
  sequence, Memory management contract, and Manifest pitfalls.

### No code changes
- This is a documentation-only release. The runtime behaviour, public
  API surface, and bundled assets are identical to 1.0.15. Upgrading
  from 1.0.15 to 1.0.16 requires no code changes — only a `pubspec.yaml`
  version bump and `flutter pub get`.

## [1.0.15] - 2026-04-26

### Fixed
- **AppLovin App-Open timeout false-positive** — old fixed 10 s timeout fired
  while user was still interacting with the ad (click → browser → return),
  marking dismiss with `false` and arming the resume guard prematurely.
  Replaced with lifecycle-aware polling: re-arms every 5 s while app is
  paused (= ad still showing), force-dismisses only when app is foreground
  for 2 consecutive ticks without `onAdHiddenCallback` (hard cap 90 s).
- **Banner paid-event not wired** — `BannerAd` extends `AdWithView` which
  has no `onPaidEvent` setter; previous dynamic dispatch silently failed.
  Banner revenue is now correctly emitted via `BannerAdListener.onPaidEvent`
  constructor parameter.
- **App-open shown immediately after rewarded dismiss** — `_lastFullscreenDismissAt`
  was recorded inside the rewarded `onDone` callback which fires on
  reward-earned (mid-video), not on actual dismiss. Replaced with slot-state
  watchers that fire on `showing → !showing` transition for all 3 fullscreen
  slots — authoritative dismiss timestamp regardless of adapter quirks.
- **VIP grace not auto-expiring mid-session** — added `Timer` in `VipManager`
  scheduled for the soonest `expiresAt`. Fires `_purgeExpired` + `_refreshActive`
  when an entry expires, so the SDK reflects VIP loss without requiring a
  full re-init. Especially relevant for short debug grace windows.
- **Inter/rewarded/app-open not preloaded after VIP expires mid-session** —
  added listener on `VipManager.activeListenable`; on `true → false` flip,
  triggers `loadAppOpenAd + loadInterstitial + loadRewardedAd + preloadBanner`
  so the user doesn't see "ad not ready" on first show after losing VIP.
- **`canShowFullscreenAd` / `canShowAppOpenOnResume` reported "wait 0s"** —
  sub-second waits truncated to 0. New `_fmtWait(ms)` helper renders ms when
  < 1 s ("wait 645ms") and 1 decimal seconds otherwise ("wait 1.5s").
- **Splash budget warning fired while splash app-open ad still showing** —
  `_armSplashBudget` now detects `appOpenSlot.isShowing` on first elapse
  and re-arms a 30 s hard cap instead of force-firing `markSplashInactive`.
- **`canShowAppOpenOnResume` returned `bool`** — refactored to return
  `AdSafetyResult` (canShow + reason), aligning with `canShowFullscreenAd`.
  Callers can log the specific block reason + remaining wait time.

### Added — Consent flow
- **`ConsentManager`** — standalone helper class owning the Cupertino consent
  dialog UI, persistence (`SharedPreferences`), and provider apply pipeline.
  Accessible via `AdManager().consentManager` or `ConsentManager.instance`.
- `ConsentSettings` — persistent user-choice record with `hasBeenAsked`,
  `askedAt`, JSON serialisation.
- `ConsentDialogStrings` — localisation, includes `ConsentDialogStrings.vi`
  for Vietnamese.
- Custom binary Cupertino dialog (Allow / Reject) with hero icon, gradient
  Allow button, accent colours, scale-in animation, haptic feedback.
- `AdConfig.autoShowConsentDialog` (default `true`) — SDK auto-presents the
  dialog ~1 s **after** `markSplashInactive` (post-splash, on home), not
  during splash flow. Skipped for VIP users.
- `AdConfig.consentDialogPostSplashDelay` (default 1 s) — tunable.
- `AdConfig.consentBarrierDismissible` (default `false`).

### Added — UMP (User Messaging Platform) wrapper
- `requestUmpConsentFlow(testMode, debugGeography, testIdentifiers, …)` —
  wraps Google's built-in `ConsentInformation` + `ConsentForm` (no extra
  dependency, available since `google_mobile_ads` 6.x).
- `AdManager().requestUmpConsent(…)` — auto-applies UMP result to providers.
- Re-exports `ConsentStatus` and `DebugGeography` from `google_mobile_ads`
  so callers don't need a direct import.

### Added — First-install VIP grace
- `AdConfig.firstInstallVipGrace: FirstInstallVipGrace` (default `auto` =
  30 s in debug, 24 h in release) — auto-grants a one-time VIP entry on the
  very first SDK init for this install. Improves D1 retention by giving
  the freshly-installed user an ad-free first session.
- `FirstInstallVipGrace` class with `auto` / `disabled` / `day` /
  `debugShort` presets and custom `Duration` constructor.
- `AdConfig.firstInstallVipKey` (default `__FIRST_INSTALL__`) — VIP entry
  key for analytics discrimination.
- `AdPreferences` — new keys `_keyFirstInstallApplied` (one-shot guard)
  and `_keyFirstInstallAt` (epoch-ms install timestamp for analytics).

### Added — Diagnostic logging
- `🚀 AdManager singleton CREATED` marker fires once per process on cold
  start. Two markers in the same logcat session = Android killed and
  restarted the process.
- `🚨 lifecycle DETACHED` warning when Flutter engine tears down.
- Lifecycle observer logs full state (prev → current, slot states, VIP
  flag, splash flag, backgrounded duration) — wrapped in `_safeLifecycleLog`
  so a closure-evaluation throw cannot abort the observer.
- All ad-load/show paths emit explicit `⏭️ skipped — <reason>` logs for
  every gate (adapter null, VIP, no network, slot showing, safety reason)
  instead of returning silently.
- AppLovin `onAdDisplayedCallback` extended with `network`, `creativeId`,
  `placement`, `latencyMillis` for revenue diagnosis.
- Memory-pressure log throttled to 60 s/event so fast bg/fg cycles
  don't flood the buffer; payload includes banner state and VIP flag.
- `DebugAdOverlay` — new `enabled` constructor flag plus static
  `globallyVisible` `ValueNotifier` for runtime toggle (e.g., from a
  shake-menu or dev console).

### Added — Misc
- `AdConfig.autoShowConsentDialog` skip path also covers the case where
  the user redeems a VIP key during the 1 s post-splash schedule window
  (re-checked at fire time).
- `AdManager.processStartedAtMs` getter.

### Changed
- `loadInterstitial` / `loadRewardedAd` / `loadAppOpenAd` / `showInterstitial`
  / `showRewardedAd` / `showAppOpenAd` skip-path logs now name the specific
  reason (adapter null vs VIP vs no network vs already showing vs safety).
- Banner preload during VIP active is now skipped at AdManager level —
  saves a network request and avoids inflating internal impression counter.

### Notes for integrators
- **Activity manifest**: do **not** set `android:taskAffinity=""` on your
  `MainActivity` when using AppLovin. With empty affinity, AppLovin's
  `AppLovinFullscreenActivity` lands in a different Android task; after
  user backgrounds + foregrounds and dismisses the ad, the task may be
  empty and the user is dropped to launcher. Default affinity (= package
  name, by simply omitting the attribute) is safe.

## [1.0.14]

### Bug Fixes
- **Fix #48** — `_assertInitialized` no longer throws; returns `bool` with warning log. All call sites now gracefully early-return when the SDK is not yet initialized.
- 47 prior numbered fixes (Fix #1 through Fix #47) — see git history for individual entries. Production-hardened single-file `AdManager` baseline with 12-layer safety.
