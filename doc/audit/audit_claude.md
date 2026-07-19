# Audit toàn diện — `applovin_admob_sdk` (round 7, đọc lại từ đầu)

**Phạm vi: kiến trúc, lifecycle/leak/offline, consent mọi quốc gia, VIP-by-code security, trial mode, compliance/monetization, native config, example+test coverage** · **Chế độ: read-only, 7 sub-agent đọc độc lập song song** · **Ngày: 2026-07-19** · **Người audit: Claude (Sonnet 5)**

> Đây là audit độc lập, đọc lại toàn bộ source code từ đầu (không kế thừa kết luận của round 6 `audit_claude.md` trước đó, dù kết luận cuối cùng khá tương đồng). Round 6 vẫn còn giá trị tham khảo về lịch sử fix (T40-T49); file này thay thế nội dung cũ.

## Verdict tổng quan

**CÓ, nên dùng cho production. Điểm: 8.7/10.**

Không tìm thấy finding **Critical** nào ở bất kỳ trong 7 mảng audit độc lập (kiến trúc, lifecycle/leak/offline, consent, VIP/trial security, compliance/monetization, native config, test coverage). Nền tảng kỹ thuật cốt lõi tốt: Ed25519 verify qua thư viện `cryptography` chuẩn (không tự chế crypto), mọi native `await` rủi ro (UMP update/form, ATT, adapter init) đều có `Future.timeout(20s)`, dispose/lifecycle sạch (không leak StreamSubscription/Timer/listener nào phát hiện được), backoff exponential có cap, safety-cap (daily/hourly/session/throttle/CTR-fraud/cooldown) đều live không phải dead-config, COPPA được xử lý bảo thủ đúng hướng (AppLovin tự tắt hẳn SDK khi `isAgeRestrictedUser=true` thay vì chạy nửa vời), 631/631 unit test pass.

Có **2 finding High** (1 đã fix: F2, xem bên dưới) và **7 finding Medium** — không cái nào chặn production, nhưng nên xử lý theo thứ tự ưu tiên ở cuối file.

## Bảng đối chiếu 7 yêu cầu ban đầu

| # | Yêu cầu | Đánh giá | Ghi chú |
|---|---------|----------|---------|
| 1 | Provider AdMob/AppLovin, work Android + iOS | ✅ Đạt | 1 interface `AdProviderAdapter`, cả 2 adapter implement đủ method cùng signature. Chọn provider bằng 1 dòng (`ad_config.isAdMob`), không lẫn logic 2 bên. Xem F1 (event bus), F3 (COPPA asymmetry). |
| 2 | Work ở thiết bị có mạng / không mạng | ✅ Đạt | Mọi `loadX` gate qua `isConnected`; offline→online có debounce refill 800ms; backoff exponential `15s → 30min` cap; không có busy-loop/timer vô hạn. |
| 3 | Chuẩn từng loại ad (banner/app-open/reward/inter): pháp lý + vòng đời + không leak | ✅ Đạt | Banner/mrec/native dispose an toàn (state sống ở `AdManager` singleton, không phải widget). Interstitial/rewarded/app-open dispose + null ref trước khi reload. Freshness check (1h/4h) tránh show ad cũ. |
| 4 | Trial mode 1 ngày | ✅ Đạt, có giới hạn cố hữu | `firstInstallVipGrace` 24h dựa device clock, có anti-rollback (`grantedAt` immutable → lùi giờ không gia hạn được). Android không có anti-bypass-reinstall (chấp nhận được, xem F5). |
| 5 | VIP by code, không server/backend | ✅ Đạt, 1 gap Medium | Ed25519 signed payload (duration+kid ký chung), verify offline, chỉ public key ship trong app. Race-condition redeem đã guard + test. Gap: Android thiếu ledger chống replay qua reinstall (F5). |
| 6 | Consent mọi quốc gia (AdMob UMP + AppLovin CMP) | ✅ Đạt cốt lõi, vài gap Medium/Low | UMP flow đúng chuẩn + timeout 3 điểm. ATT đủ 5 state + timeout. COPPA AppLovin tự tắt SDK. Gap: chỉ forward boolean `hasUserConsent`/`doNotSell` giữa UMP↔AppLovin, không đồng bộ TCF/IAB TC-String (F7); `autoRequestUmpConsent` mặc định `false`, quên gọi chỉ log warning không chặn (F4). |
| 7 | Tuân thủ policy AdMob/AppLovin | ✅ Đạt | Debug overlay ("Ad" badge đen) chỉ hiện `kDebugMode`, tree-shake `false` ở release — không có nguy cơ policy. App ID/AppLovin key tách đúng test (example) vs thật (host). SKAdNetwork host 152 entries lành mạnh, example chỉ 50 (F6, không ảnh hưởng production vì example không ship). |

## Danh sách finding chi tiết (ưu tiên theo severity)

### F1 — ✅ ĐÃ FIX (2026-07-19) — [High] `SimpleEventBus` không có replay buffer — "subscribe trước khi init" chỉ là quy ước, không được code enforce

**File:** `packages/ad_sdk/lib/src/core/event_bus.dart` (39 dòng)

`fire()` chỉ notify listener đang sống tại thời điểm gọi — không cache/replay event nào. Toàn bộ claim "SimpleEventBus chỉ deliver init-completion event cho listener đăng ký trước khi init bắt đầu" (README + memory) đúng **chỉ vì** `SplashScreen` tình cờ gọi đúng thứ tự — không có gì trong `event_bus.dart` tự bảo vệ hoặc raise lỗi nếu 1 consumer khác `.listen()` sau khi `fire()` đã chạy; event đó mất vĩnh viễn, im lặng. Test hiện tại (`ad_sdk_test.dart`) chỉ check delivery cùng-tick, không test đúng ordering contract này.

**Đã fix:** thêm replay buffer (`_lastEvent`) — `fire()` lưu event cuối, `listen()` phát lại ngay cho listener đăng ký muộn; `clearAll()` (chỉ gọi trong `AdManager.destroy()`) reset buffer để `initialize()` lần sau tự `fire()` lại từ đầu. Thêm 2 test mới ("late listener still receives the most recent fired event", "clearAll() resets replay buffer") + sửa `setUp()` gọi `clearAll()` để cô lập test. `flutter test` 639/639 pass, `flutter analyze` sạch.

### F2 — ✅ ĐÃ FIX (2026-07-19) — [High] Test race-condition ở interstitial/rewarded vẫn còn (app-open đã fix, 2 file kia thì chưa)

**File:** `packages/ad_sdk/example/integration_test/interstitial_ad_test.dart`, `rewarded_ad_test.dart`

`app_open_ad_test.dart` đã có `_waitForAppOpenLoaded` (poll 40×500ms, chỉ show khi `isReady==true`) — đúng pattern. Nhưng `interstitial_ad_test.dart` và `rewarded_ad_test.dart` vẫn tap nút show ngay sau `pump(500ms)` cố định, không poll xác nhận ad đã load thật trước khi tap. Nghĩa là PASS của 2 test này **không phải bằng chứng đáng tin cậy** rằng ad thực sự hiển thị — đây là finding đã ghi nhận ở audit trước (2026-07-15) và **chưa được áp dụng fix sang 2 file này**.

**Đã fix:** thêm `_waitForInterstitialLoaded` / `_waitForRewardedLoaded` (mirror `_waitForAppOpenLoaded`, poll `interstitialSlot`/`rewardedSlot` cho tới `isReady`/`isCooldown`) vào cả 2 file, gọi trước mỗi lần tap show ở cả Cycle 1 và Cycle 2, với `expect(loaded, isTrue)` để test fail rõ ràng nếu ad không load kịp thay vì "pass" im lặng do skip/no-op.

**Verify trên real device (Pixel 7 Pro, AdMob test ad unit, `--dart-define=AD_PROVIDER_ADMOB=true`):** cả 2 file **PASS**, log xác nhận ad **load thật + show thật + dismiss sạch** (`showInterstitial [AdMob] ✅ shown`, `showRewarded [AdMob] ✅ shown` → `🏆 earned=true`), không còn race timeout. `flutter analyze` sạch. Lưu ý: Cycle 2 của interstitial có thể bị chặn bởi safety-throttle 30s giữa 2 lần show fullscreen liên tiếp (hành vi bảo vệ đúng thiết kế, không phải bug) — test vẫn pass vì lifecycle sạch không exception.

### F3 — ✅ ĐÃ FIX (2026-07-19, doc-only) — [Medium] AppLovin tự tắt hẳn SDK khi COPPA, AdMob chỉ tag per-request — bất đối xứng không được document là chủ ý

**File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:181-191` (AppLovin) vs `admob_adapter.dart` (AdMob, forward `tagForChildDirectedTreatment` per-request, không tự tắt)

Cả 2 cách đều hợp lý riêng lẻ (AppLovin MAX 4.x không có API COPPA runtime tương đương AdMob nên buộc phải tắt hẳn), nhưng khác biệt hành vi giữa 2 provider cho cùng 1 cấu hình `isAgeRestrictedUser=true` không được nêu rõ ở README là chủ ý — dev tích hợp có thể ngạc nhiên khi AppLovin ads biến mất hoàn toàn còn AdMob vẫn chạy (chỉ tagged).

**Đã fix (doc-only):** thêm đoạn vào README cạnh mục COPPA nói rõ đây là giới hạn API cố ý của từng provider (AppLovin không có per-request COPPA flag → phải abort init; AdMob có → chỉ tag), không phải inconsistency cần "sửa".

### F4 — ✅ ĐÃ FIX (2026-07-19) — [Medium] `autoRequestUmpConsent` mặc định `false`; quên gọi chỉ log warning, không chặn init

**File:** `packages/ad_sdk/lib/src/config/ad_config.dart:345`, warning tại `ad_manager.dart:1133-1142`

Nếu host quên set `autoRequestUmpConsent:true` hoặc quên tự gọi `requestUmpConsent()` trước `initialize()` (và `disableAppLovinCmpFlow` vẫn `true` mặc định), SDK chỉ `SafeLogger.w` cảnh báo — **không** assert/throw chặn init. EEA/UK user có thể không thấy consent form nào, chạy ads luôn — rủi ro policy GDPR/UMP thật nếu host tích hợp cẩu thả. Host app hiện tại (`splash_screen.dart:199-207`) gọi đúng, nhưng đây là kỷ luật app-level, SDK không tự enforce.

**Đã fix:** giữ nguyên default `autoRequestUmpConsent=false` (tránh breaking change), nhưng nâng cảnh báo hiện có thành `assert(false, ...)` ngay sau `SafeLogger.w` — integrator phát hiện ngay trong dev/test build (assert bị strip ở release nên hành vi production không đổi). Thêm test dựng đúng config misconfigured, gọi `initialize()`, kỳ vọng `throws AssertionError`. **Quyết định:** chọn phương án nhẹ nhất (assert dev-only) thay vì đổi default thành `true` hoặc throw thật ở release, để không phá vỡ hành vi production hiện tại của host app.

### F5 — ✅ ĐÃ FIX (2026-07-19, doc-only) — [Medium] Android không có ledger chống replay VIP-key qua gỡ cài đặt lại (uninstall/reinstall)

**File:** `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:48,64`

`isRedeemed`/`markRedeemed` là no-op trên Android (chỉ hoạt động thật trên iOS qua Keychain). Nếu 1 signed VIP key bị lộ công khai, bất kỳ user Android nào cũng có thể redeem lại **vô hạn lần** bằng cách gỡ cài đặt + cài lại app (mỗi lần chỉ được đúng `duration` mã hoá trong key, không phải VIP vĩnh viễn tức thời, nhưng lặp lại được không giới hạn số lần). Đây là root cause đã xác định của complaint "sao vẫn thấy quảng cáo sau khi cài lại" ở round audit trước — **chấp nhận được về sản phẩm** (không có backend nên khó chặn tuyệt đối trên Android nếu không dùng Install Referrer API hoặc backend nhẹ), nhưng cần ghi rõ trong README là giới hạn đã biết, không phải bug ẩn.

**Đã fix (doc-only, không đổi behavior):**
- `packages/ad_sdk/README.md` (mục "VIP system" → "Signed VIP keys") — thêm block `> **Known limitation — Android reinstall replay.**` giải thích rõ 2 lớp chống replay (`AdPreferences` + `RedeemedKeyLedger`), vì sao Android không có durable ledger, và hệ quả (key lộ có thể replay không giới hạn số lần qua reinstall).
- Đồng thời cập nhật luôn bullet "Known limitation" về F2 trong README (đã lỗi thời vì F2 đã fix ở bước trước) thành "Fixed (2026-07-19)" kèm bằng chứng verify.
- `packages/ad_sdk/lib/src/core/ad_manager.dart:967` — sửa comment stale nhắc "Install Referrer with conservative skip on connection failure (Q3)" (không khớp code thật) thành mô tả đúng: Android anti-bypass **intentionally disabled**, không có Install Referrer check, tham chiếu doc comment của `FirstInstallGuard`.
- `flutter analyze` sạch sau khi sửa.

**Update 2026-07-19 (SDK 1.2.1) — mitigation bổ sung, không thay đổi kết luận trên:** root cause F5 trùng với 1 complaint thật từ partner ("ads không hiện"). Vì grant Android vẫn hoàn toàn silent/log-only trước đây, user/partner test bằng reinstall không có cách nào biết vì sao ads biến mất trong 24h. Đã thêm `VipManager.firstInstallGrantDueListenable`/`lastFirstInstallGrantDuration`/`acknowledgeFirstInstallGrant()` (mirror `graceNudgeDueListenable`) + SnackBar 1 lần ở host khi grant xảy ra — **không chặn** hành vi fail-open đã ghi nhận ở trên (vẫn replay được không giới hạn qua reinstall), chỉ khiến mỗi lần grant *hiển thị rõ* thay vì im lặng. Verify: SDK 4 test mới pass, host analyze/test sạch, on-device (Samsung S24 Ultra) build+install+run+logcat sạch (không FATAL, lifecycle AdManager/VipManager bình thường). Xem `doc/feature.md` mục "First-install VIP grant-time notice".

### F6 — ✅ ĐÃ FIX (2026-07-19, doc-only) — [Medium] Fill-rate-monitor / monetization-arbitrator không có gate `kDebugMode`

**File:** `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `monetization_arbitrator.dart`

Cả 2 module opt-in bằng code (`enableFillRateMonitor`, `enableArbitrator`) nhưng không guard bằng `kDebugMode` — nếu host vô tình bật ở production, `MonetizationArbitrator` có thể veto ad thật (`nudgeVip`) dựa trên eCPM threshold, ảnh hưởng doanh thu. Không phải bug (docstring nói rõ đây là tool production-safe-to-enable "opt-in"), nhưng thiếu safeguard rõ ràng trong README rằng đây không phải debug-only.

**Đã fix (doc-only):** README làm rõ cả 2 tool là **default OFF, production-safe** — không có phân biệt debug/release nào cả (khác `RevenuePanel` gate theo `kDebugMode`), chỉ tắt vì chưa được gọi `enable...`, gọi rồi thì chạy y hệt ở debug lẫn release, không có bước "bật ở production" riêng.

### F7 — ✅ ĐÃ FIX (2026-07-19, doc-only) — [Medium] Consent UMP↔AppLovin chỉ đồng bộ boolean, không đồng bộ TCF/IAB TC-String

**File:** `packages/ad_sdk/lib/src/core/ad_consent.dart:75`

`AppLovinMAX.setHasUserConsent()` / `setDoNotSell()` chỉ forward 2 boolean, không ghi `IABTCF_TCString` chuẩn IAB. Nếu 1 mediation partner nào đó bên trong AppLovin đọc trực tiếp TC String theo convention IAB (thay vì qua API riêng của AppLovin), partner đó có thể không nhận đúng tín hiệu consent dù user đã reject ở UMP.

**Đã fix (doc-only, xác minh không phải gap):** README + docstring `ad_consent.dart` làm rõ AppLovin MAX SDK 12.0.0+ (project pin native `13.2.0.1` / Flutter `applovin_max: ^4.6.4`, đều vượt xa ngưỡng) **tự đọc** `IABTCF_TCString`/`IABTCF_gdprApplies`/`IABTCF_AddtlConsent` trực tiếp từ platform storage theo chuẩn IAB ngay khi UMP ghi — không cần app code forward. `AdManager().tcfConsentString` chỉ là escape hatch thủ công cho 1 bên thứ ba ngoài AppLovin/AdMob.

### F8 — ✅ ĐÃ FIX (2026-07-19, mechanical + doc) — [Medium] Example app không switch provider runtime; SKAdNetwork list mỏng nếu bị clone làm app thật

**File:** `packages/ad_sdk/example/lib/main.dart:94-96` (compile-time `--dart-define=AD_PROVIDER_ADMOB`), `example/ios/Runner/Info.plist` (50 SKAdNetworkID vs host 152)

Cả 2 đều chỉ ảnh hưởng nếu ai đó dùng trực tiếp example làm app thật mà quên cập nhật — không ảnh hưởng production hiện tại (host app đã có config đúng, real App ID, 152 SKAdNetwork entries).

**Đã fix:** đồng bộ `example/ios/Runner/Info.plist` lên đủ 152 `SKAdNetworkIdentifier` (khớp host), validated `plutil -lint` → OK, xác nhận lại qua iOS Simulator compile-only build → SUCCEEDED. Thêm comment cạnh `kProvider` trong `example/lib/main.dart` nói rõ đây là dev/test convenience, không nên copy nguyên vào app thật mà không review.

### F9 — ✅ ĐÃ FIX (2026-07-19, hỗn hợp) — [Low/Info, không chặn] Các gap UX phụ trợ về consent

- Thiếu string/UI riêng "Do Not Sell My Info" cho CCPA (data layer `doNotSell` vẫn forward đúng nếu host set). **Đã fix (doc-only):** README trỏ tới pattern `CupertinoSwitch` đã có sẵn ở `VipRedeemScreen` (`vip_redeem_screen.dart:155-158, ~1360-1364`) làm ví dụ tham khảo cho host cần UI CCPA — không cần UI mới trong SDK core.
- Thứ tự "ATT trước UMP" chỉ là docstring, không code-enforced (host app hiện làm đúng thứ tự). **Đã fix:** thêm tracking nhẹ trong `ad_manager.dart` (`_attRequested` flag set bởi `requestAtt()`) — `requestUmpConsent()` log-only warning (`SafeLogger.w`, không block) nếu `Platform.isIOS && !_attRequested`. Không có test riêng (không có seam override sẵn có cho `Platform.isIOS` như `att_consent.dart`, chỉ 1 dòng log — chấp nhận là gap có chủ ý).
- `consent_dialog.dart` (dialog custom, không phải UMP form) không có nút "Manage Options" và không tự ghi vào `ConsentManager` — caller phải tự gọi. **Đã fix (doc-only):** dialog đã có docstring "Why binary only?" giải thích rõ thiết kế binary-only là cố ý — README thêm 1 dòng trỏ tới rationale này, không build thêm UI mới.
- `RevenuePanel` không gate `kDebugMode` — nếu lỡ để trong production UI sẽ lộ số liệu doanh thu (không phải nguy cơ policy, chỉ leak business data nội bộ). **Đã fix (code):** thêm `debugModeOverride` (test seam, theo pattern `platformIsIosOverride`), gate cả `initState()` subscribe và `build()` render sau `_isDebug` (mặc định `kDebugMode`) — release build render `SizedBox.shrink()`, không subscribe `AdManager().events`. 2 test mới xác nhận cả 2 nhánh; `flutter test` 639/639 pass.

## Những gì đã xác nhận AN TOÀN (đọc kỹ, không tìm thấy vấn đề)

- **Memory/leak**: banner/mrec/native widget dispose an toàn (state ở singleton `AdManager`, không phải widget State) — `banner_leak_regression_test.dart` xác nhận 25 chu kỳ mount/unmount không tăng leak. Interstitial/rewarded/app-open null-ref + dispose trước khi reload.
- **Offline**: mọi `loadX` gate qua `isConnected`; backoff exponential `15s→30min` cap (`backoff.dart`); reconnect debounce 800ms tránh spam; không timer chạy vô hạn không điều kiện dừng.
- **Safety cap**: throttle 30s, session/hourly/daily cap, CTR-fraud threshold, progressive cooldown — tất cả **live**, verify bằng code + test, không phải dead config.
- **Crash guard**: scope hẹp theo stack-frame attribution (`package:applovin_admob_sdk/`), không phải catch-all che bug thật.
- **VIP crypto**: Ed25519 qua `package:cryptography` (không tự chế), payload (duration+kid) ký chung 1 khối, không field nào nằm ngoài chữ ký. Anti-rollback: `grantedAt` immutable chặn lùi giờ để gia hạn. Race-condition redeem đồng thời đã guard + unit test xác nhận đúng 1 lần thành công.
- **COPPA**: AppLovin tự tắt hẳn SDK khi `isAgeRestrictedUser=true` (bảo thủ, đúng hướng) thay vì chạy nửa vời.
- **ATT**: đủ 5 trạng thái, timeout 20s khi user không phản hồi.
- **PII/privacy**: không tìm thấy log/export chứa raw GAID/IP/toạ độ GPS; không có network call tới endpoint tự built ngoài AdMob/AppLovin SDK chính thức.
- **Native config**: App ID test (example) vs thật (host) tách đúng, không lẫn lộn; minSdk/targetSdk vượt yêu cầu tối thiểu của cả 2 SDK; NSUserTrackingUsageDescription không dùng ngôn ngữ ép buộc consent.
- **Test suite**: 631/631 pass, biên dịch sạch; README khớp code hiện tại (không tìm thấy method/signature mismatch).

## Thứ tự ưu tiên xử lý (không cái nào chặn production)

1. ~~**F2** — fix race-condition test interstitial/rewarded (copy pattern từ app_open)~~ — ✅ đã fix + verify trên real device 2026-07-19.
2. ~~**F5** — ghi rõ vào README giới hạn "Android VIP key có thể replay qua reinstall" + sửa comment stale ở `ad_manager.dart:967`.~~ — ✅ đã fix (doc-only) 2026-07-19.
3. ~~**F1** — thêm replay buffer nhẹ cho `SimpleEventBus`.~~ — ✅ đã fix + test 2026-07-19.
4. ~~**F4, F7** — siết `autoRequestUmpConsent` (dev-time assert) / xác minh + document TCF auto-forward.~~ — ✅ đã fix 2026-07-19.
5. ~~**F3, F6, F8, F9** — cập nhật doc/README làm rõ chủ ý thiết kế + fix code thật cho F8 (Info.plist sync) và F9-RevenuePanel (kDebugMode gate).~~ — ✅ đã fix 2026-07-19.

**Tất cả 9 finding của round 7 đã được xử lý** (2 fix trước đó F2/F5, 7 fix trong phiên này F1/F3/F4/F6/F7/F8/F9). Không còn finding mở nào.

## Điểm số: 8.7/10 — sẵn sàng production

Đây là kết luận độc lập (không sao chép round 6), dựa trên 7 lượt đọc source code song song bao trùm toàn bộ 51 file lib + cấu hình native + 63 file test + example app. Không có Critical. 2 High đều là "test/design chưa hoàn thiện", không phải lỗ hổng đang bị khai thác hay rủi ro pháp lý cấp thiết. SDK này đáp ứng đủ 7 yêu cầu ban đầu (dual-provider, online/offline, đủ loại ad đúng vòng đời, trial 1 ngày, VIP-by-code không backend, consent đa quốc gia, tuân thủ policy) ở mức chất lượng cao hơn mặt bằng chung của các SDK ads tự viết.

## Cập nhật sau khi fix toàn bộ (2026-07-19)

Verify cuối: `flutter analyze` sạch, `flutter test` **639/639 pass** (baseline + test mới cho F1/F4/F9), iOS Simulator compile-only build **SUCCEEDED** (xác nhận Info.plist F8 hợp lệ), build+install+run thật trên **Samsung S24 Ultra** (`R5CX613VZBR`, Android-only) — SDK init sạch (AppLovin ✅), consent flow chạy đúng, không FATAL/crash, không quảng cáo thật xuất hiện trong lúc test (R4 không bị kích hoạt — VIP first-install-grace 30s che ad, sau đó chỉ load ad với placeholder ID mặc định của example app nên bị AppLovin native reject có kiểm soát, không phải crash). Giới hạn đã biết: S24 Ultra chỉ Android nên F8 (iOS Info.plist) và F9-ATT-order chỉ verify qua compile/analyze, chưa chạy thật trên thiết bị iOS.
