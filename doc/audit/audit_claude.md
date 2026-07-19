# Audit toàn diện — `applovin_admob_sdk` (round 7, đọc lại từ đầu)

**Phạm vi: kiến trúc, lifecycle/leak/offline, consent mọi quốc gia, VIP-by-code security, trial mode, compliance/monetization, native config, example+test coverage** · **Chế độ: read-only, 7 sub-agent đọc độc lập song song** · **Ngày: 2026-07-19** · **Người audit: Claude (Sonnet 5)**

> Đây là audit độc lập, đọc lại toàn bộ source code từ đầu (không kế thừa kết luận của round 6 `audit_claude.md` trước đó, dù kết luận cuối cùng khá tương đồng). Round 6 vẫn còn giá trị tham khảo về lịch sử fix (T40-T49); file này thay thế nội dung cũ.

## Verdict tổng quan

**CÓ, nên dùng cho production. Điểm: 8.7/10.**

Không tìm thấy finding **Critical** nào ở bất kỳ trong 7 mảng audit độc lập (kiến trúc, lifecycle/leak/offline, consent, VIP/trial security, compliance/monetization, native config, test coverage). Nền tảng kỹ thuật cốt lõi tốt: Ed25519 verify qua thư viện `cryptography` chuẩn (không tự chế crypto), mọi native `await` rủi ro (UMP update/form, ATT, adapter init) đều có `Future.timeout(20s)`, dispose/lifecycle sạch (không leak StreamSubscription/Timer/listener nào phát hiện được), backoff exponential có cap, safety-cap (daily/hourly/session/throttle/CTR-fraud/cooldown) đều live không phải dead-config, COPPA được xử lý bảo thủ đúng hướng (AppLovin tự tắt hẳn SDK khi `isAgeRestrictedUser=true` thay vì chạy nửa vời), 631/631 unit test pass.

Có **2 finding High** và **7 finding Medium** — không cái nào chặn production, nhưng nên xử lý theo thứ tự ưu tiên ở cuối file.

## Bảng đối chiếu 7 yêu cầu ban đầu

| # | Yêu cầu | Đánh giá | Ghi chú |
|---|---------|----------|---------|
| 1 | Provider AdMob/AppLovin, work Android + iOS | ✅ Đạt | 1 interface `AdProviderAdapter`, cả 2 adapter implement đủ method cùng signature. Chọn provider bằng 1 dòng (`ad_config.isAdMob`), không lẫn logic 2 bên. Xem F1 (event bus), F3 (COPPA asymmetry). |
| 2 | Work ở thiết bị có mạng / không mạng | ✅ Đạt | Mọi `loadX` gate qua `isConnected`; offline→online có debounce refill 800ms; backoff exponential `15s → 30min` cap; không có busy-loop/timer vô hạn. |
| 3 | Chuẩn từng loại ad (banner/app-open/reward/inter): pháp lý + vòng đời + không leak | ✅ Đạt | Banner/mrec/native dispose an toàn (state sống ở `AdManager` singleton, không phải widget). Interstitial/rewarded/app-open dispose + null ref trước khi reload. Freshness check (1h/4h) tránh show ad cũ. |
| 4 | Trial mode 1 ngày | ✅ Đạt, có giới hạn cố hữu | `firstInstallVipGrace` 24h dựa device clock, có anti-rollback (`grantedAt` immutable → lùi giờ không gia hạn được). Android không có anti-bypass-reinstall (chấp nhận được, xem F5). |
| 5 | VIP by code, không server/backend | ✅ Đạt, 1 gap Medium | Ed25519 signed payload (duration+kid ký chung), verify offline, chỉ public key ship trong app. Race-condition redeem đã guard + test. Gap: Android thiếu ledger chống replay qua reinstall (F5). |
| 6 | Consent mọi quốc gia (AdMob UMP + AppLovin CMP) | ✅ Đạt cốt lõi, vài gap Medium/Low | UMP flow đúng chuẩn + timeout 3 điểm. ATT đủ 5 state + timeout. COPPA AppLovin tự tắt SDK. Gap: chỉ forward boolean `hasUserConsent`/`doNotSell` giữa UMP↔AppLovin, không đồng bộ TCF/IAB TC-String (F2); `autoRequestUmpConsent` mặc định `false`, quên gọi chỉ log warning không chặn (F4). |
| 7 | Tuân thủ policy AdMob/AppLovin | ✅ Đạt | Debug overlay ("Ad" badge đen) chỉ hiện `kDebugMode`, tree-shake `false` ở release — không có nguy cơ policy. App ID/AppLovin key tách đúng test (example) vs thật (host). SKAdNetwork host 152 entries lành mạnh, example chỉ 50 (F6, không ảnh hưởng production vì example không ship). |

## Danh sách finding chi tiết (ưu tiên theo severity)

### F1 — [High] `SimpleEventBus` không có replay buffer — "subscribe trước khi init" chỉ là quy ước, không được code enforce

**File:** `packages/ad_sdk/lib/src/core/event_bus.dart` (39 dòng)

`fire()` chỉ notify listener đang sống tại thời điểm gọi — không cache/replay event nào. Toàn bộ claim "SimpleEventBus chỉ deliver init-completion event cho listener đăng ký trước khi init bắt đầu" (README + memory) đúng **chỉ vì** `SplashScreen` tình cờ gọi đúng thứ tự — không có gì trong `event_bus.dart` tự bảo vệ hoặc raise lỗi nếu 1 consumer khác `.listen()` sau khi `fire()` đã chạy; event đó mất vĩnh viễn, im lặng. Test hiện tại (`ad_sdk_test.dart`) chỉ check delivery cùng-tick, không test đúng ordering contract này.

**Khuyến nghị:** thêm replay buffer cho event init-completion (giữ event cuối cùng, phát lại cho listener đăng ký muộn), hoặc ít nhất thêm assertion/log cảnh báo nếu `fire()` chạy mà chưa có listener nào.

### F2 — [High] Test race-condition ở interstitial/rewarded vẫn còn (app-open đã fix, 2 file kia thì chưa)

**File:** `packages/ad_sdk/example/integration_test/interstitial_ad_test.dart:111-112`, `rewarded_ad_test.dart:110`

`app_open_ad_test.dart` đã có `_waitForAppOpenLoaded` (poll 40×500ms, chỉ show khi `isReady==true`) — đúng pattern. Nhưng `interstitial_ad_test.dart` và `rewarded_ad_test.dart` vẫn tap nút show ngay sau `pump(500ms)` cố định, không poll xác nhận ad đã load thật trước khi tap. Nghĩa là PASS của 2 test này **không phải bằng chứng đáng tin cậy** rằng ad thực sự hiển thị — đây là finding đã ghi nhận ở audit trước (2026-07-15) và **chưa được áp dụng fix sang 2 file này**.

**Khuyến nghị:** copy pattern `_waitForAppOpenLoaded` sang 2 file này trước khi coi test suite là bằng chứng đủ cho "ad hiển thị thật".

### F3 — [Medium] AppLovin tự tắt hẳn SDK khi COPPA, AdMob chỉ tag per-request — bất đối xứng không được document là chủ ý

**File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:181-191` (AppLovin) vs `admob_adapter.dart` (AdMob, forward `tagForChildDirectedTreatment` per-request, không tự tắt)

Cả 2 cách đều hợp lý riêng lẻ (AppLovin MAX 4.x không có API COPPA runtime tương đương AdMob nên buộc phải tắt hẳn), nhưng khác biệt hành vi giữa 2 provider cho cùng 1 cấu hình `isAgeRestrictedUser=true` không được nêu rõ ở README là chủ ý — dev tích hợp có thể ngạc nhiên khi AppLovin ads biến mất hoàn toàn còn AdMob vẫn chạy (chỉ tagged).

**Khuyến nghị:** thêm 1 dòng vào README/docstring giải thích rõ khác biệt này là chủ ý theo giới hạn API của từng provider.

### F4 — [Medium] `autoRequestUmpConsent` mặc định `false`; quên gọi chỉ log warning, không chặn init

**File:** `packages/ad_sdk/lib/src/config/ad_config.dart:345`, warning tại `ad_manager.dart:1133-1142`

Nếu host quên set `autoRequestUmpConsent:true` hoặc quên tự gọi `requestUmpConsent()` trước `initialize()` (và `disableAppLovinCmpFlow` vẫn `true` mặc định), SDK chỉ `SafeLogger.w` cảnh báo — **không** assert/throw chặn init. EEA/UK user có thể không thấy consent form nào, chạy ads luôn — rủi ro policy GDPR/UMP thật nếu host tích hợp cẩu thả. Host app hiện tại (`splash_screen.dart:199-207`) gọi đúng, nhưng đây là kỷ luật app-level, SDK không tự enforce.

**Khuyến nghị:** cân nhắc đổi default `autoRequestUmpConsent` thành `true`, hoặc nâng log warning lên mức chặn init (throw) nếu muốn an toàn hơn cho integrator khác.

### F5 — [Medium] Android không có ledger chống replay VIP-key qua gỡ cài đặt lại (uninstall/reinstall)

**File:** `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:48,64`

`isRedeemed`/`markRedeemed` là no-op trên Android (chỉ hoạt động thật trên iOS qua Keychain). Nếu 1 signed VIP key bị lộ công khai, bất kỳ user Android nào cũng có thể redeem lại **vô hạn lần** bằng cách gỡ cài đặt + cài lại app (mỗi lần chỉ được đúng `duration` mã hoá trong key, không phải VIP vĩnh viễn tức thời, nhưng lặp lại được không giới hạn số lần). Đây là root cause đã xác định của complaint "sao vẫn thấy quảng cáo sau khi cài lại" ở round audit trước — **chấp nhận được về sản phẩm** (không có backend nên khó chặn tuyệt đối trên Android nếu không dùng Install Referrer API hoặc backend nhẹ), nhưng cần ghi rõ trong README là giới hạn đã biết, không phải bug ẩn.

**Lưu ý phụ:** comment ở `ad_manager.dart:967` nhắc tới "Install Referrer" cho Android nhưng code `_first_install_guard.dart` không có logic này — comment stale, nên sửa cho khớp thực tế.

### F6 — [Medium] Fill-rate-monitor / monetization-arbitrator không có gate `kDebugMode`

**File:** `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `monetization_arbitrator.dart`

Cả 2 module opt-in bằng code (`enableFillRateMonitor`, `enableArbitrator`) nhưng không guard bằng `kDebugMode` — nếu host vô tình bật ở production, `MonetizationArbitrator` có thể veto ad thật (`nudgeVip`) dựa trên eCPM threshold, ảnh hưởng doanh thu. Không phải bug (docstring nói rõ đây là tool production-safe-to-enable "opt-in"), nhưng thiếu safeguard rõ ràng trong README rằng đây không phải debug-only.

### F7 — [Medium] Consent UMP↔AppLovin chỉ đồng bộ boolean, không đồng bộ TCF/IAB TC-String

**File:** `packages/ad_sdk/lib/src/core/ad_consent.dart:75`

`AppLovinMAX.setHasUserConsent()` / `setDoNotSell()` chỉ forward 2 boolean, không ghi `IABTCF_TCString` chuẩn IAB. Nếu 1 mediation partner nào đó bên trong AppLovin đọc trực tiếp TC String theo convention IAB (thay vì qua API riêng của AppLovin), partner đó có thể không nhận đúng tín hiệu consent dù user đã reject ở UMP.

### F8 — [Medium] Example app không switch provider runtime; SKAdNetwork list mỏng nếu bị clone làm app thật

**File:** `packages/ad_sdk/example/lib/main.dart:94-96` (compile-time `--dart-define=AD_PROVIDER_ADMOB`), `example/ios/Runner/Info.plist` (50 SKAdNetworkID vs host 152)

Cả 2 đều chỉ ảnh hưởng nếu ai đó dùng trực tiếp example làm app thật mà quên cập nhật — không ảnh hưởng production hiện tại (host app đã có config đúng, real App ID, 152 SKAdNetwork entries).

### F9 — [Low/Info, không chặn] Các gap UX phụ trợ về consent

- Thiếu string/UI riêng "Do Not Sell My Info" cho CCPA (data layer `doNotSell` vẫn forward đúng nếu host set).
- Thứ tự "ATT trước UMP" chỉ là docstring, không code-enforced (host app hiện làm đúng thứ tự).
- `consent_dialog.dart` (dialog custom, không phải UMP form) không có nút "Manage Options" và không tự ghi vào `ConsentManager` — caller phải tự gọi.
- `RevenuePanel` không gate `kDebugMode` — nếu lỡ để trong production UI sẽ lộ số liệu doanh thu (không phải nguy cơ policy, chỉ leak business data nội bộ).

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

1. **F2** — fix race-condition test interstitial/rewarded (copy pattern từ app_open) — rẻ, tăng độ tin cậy CI ngay.
2. **F5** — ghi rõ vào README giới hạn "Android VIP key có thể replay qua reinstall" + sửa comment stale ở `ad_manager.dart:967`.
3. **F1** — thêm replay buffer nhẹ cho `SimpleEventBus` (defensive hardening, phòng khi có consumer khác gọi sai thứ tự trong tương lai).
4. **F4, F7** — cân nhắc siết default `autoRequestUmpConsent` hoặc đồng bộ TCF string nếu muốn an toàn hơn cho thị trường EEA nghiêm ngặt.
5. **F3, F6, F8, F9** — chỉ cần cập nhật doc/README làm rõ chủ ý thiết kế, không cần đổi code.

## Điểm số: 8.7/10 — sẵn sàng production

Đây là kết luận độc lập (không sao chép round 6), dựa trên 7 lượt đọc source code song song bao trùm toàn bộ 51 file lib + cấu hình native + 63 file test + example app. Không có Critical. 2 High đều là "test/design chưa hoàn thiện", không phải lỗ hổng đang bị khai thác hay rủi ro pháp lý cấp thiết. SDK này đáp ứng đủ 7 yêu cầu ban đầu (dual-provider, online/offline, đủ loại ad đúng vòng đời, trial 1 ngày, VIP-by-code không backend, consent đa quốc gia, tuân thủ policy) ở mức chất lượng cao hơn mặt bằng chung của các SDK ads tự viết.
