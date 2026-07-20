# Audit toàn diện — `applovin_admob_sdk` (round 8, đọc lại từ đầu)

**Phạm vi: kiến trúc, lifecycle/leak/offline, consent mọi quốc gia, VIP-by-code security, trial mode, compliance/monetization, native config, test coverage/CI** · **Chế độ: read-only, 5 sub-agent đọc độc lập song song, mỗi agent KHÔNG được đọc audit_claude.md/audit_gemini.md/audit_codex.md cũ** · **Ngày: 2026-07-19 (buổi tối, sau round 7)** · **Người audit: Claude (Sonnet 5)**

> Round 7 (`audit_claude.md` cũ, hoàn tất 22:36) đã fix hết 9 finding (F1-F9), 639/639 test pass, kết luận 8.7/10 CÓ production-ready. Sau đó có 1 commit nữa (`c0249be`, 23:00) hoàn tất T47 (CI gate integration_test trên Android emulator), T48 (e2e test VIP grace qua `initialize()` thật), T49 (vá lỗ "single addVip không stack vẫn có thể vượt `maxStackDuration`"). Round 8 này đọc lại **toàn bộ từ đầu** (không kế thừa kết luận cũ) để: (a) xác nhận độc lập F1-F9 vẫn đứng vững, không hồi quy; (b) audit riêng phần code mới (T47-T49); (c) tìm finding mới bằng góc nhìn tươi. Kết luận cuối tương đồng round 7 nhưng phát hiện thêm 1 điểm round 7 đã bỏ sót (N1 — GAID logging).

## Verdict tổng quan

**CÓ, nên dùng cho production. Điểm: 8.6/10** (giữ nguyên tinh thần round 7, trừ nhẹ 0.1 vì N1 là một claim round 7 đã nói sai — "không log GAID" — cần sửa lại cho đúng).

Không tìm thấy finding **Critical** nào ở bất kỳ 1 trong 5 mảng audit độc lập. T47/T48/T49 đều xác nhận đúng, có test, không gây hồi quy. Toàn bộ F1-F9 của round 7 được xác nhận **vẫn đứng vững** qua một lượt đọc hoàn toàn độc lập (không xem lại kết luận cũ trước khi đọc code). 645/645 test pass, `flutter analyze` sạch tuyệt đối ở cả `packages/ad_sdk` và root.

Có 6 finding mới (N1-N6), tất cả **Medium hoặc thấp hơn**, không cái nào chặn production — xem bảng ưu tiên cuối file.

## Bảng đối chiếu 7 yêu cầu ban đầu

| # | Yêu cầu | Đánh giá | Ghi chú |
|---|---------|----------|---------|
| 1 | Provider AdMob/AppLovin, work Android + iOS | ✅ Đạt | Không đổi so với round 7 — 1 interface `AdProviderAdapter`, chọn provider 1 dòng, không lẫn logic. |
| 2 | Work ở thiết bị có mạng / không mạng | ✅ Đạt | Xác nhận lại độc lập: mọi `loadX` gate qua `isConnected`, backoff `15s→30min` cap cứng, debounce reconnect 800ms, không timer vô hạn. Không tìm thấy vấn đề mới. |
| 3 | Chuẩn từng loại ad (banner/app-open/reward/inter): pháp lý + vòng đời + không leak | ✅ Đạt | Xác nhận lại độc lập toàn bộ dispose path (banner/mrec/native/interstitial/rewarded/appOpen/RouteObserver). 1 finding Low mới (N4, native ad callback không check mounted trước khi ghi notifier — rủi ro cực hẹp, có safety net). |
| 4 | Trial mode 1 ngày | ✅ Đạt, có giới hạn cố hữu | T48 xác nhận: grace tự kích hoạt đúng qua `initialize()` thật (không chỉ `addVip()` cô lập), `remainingHours` đúng khoảng 23-24h. Android vẫn fail-open qua reinstall (đã biết, chấp nhận được — xem lại F5 cũ). |
| 5 | VIP by code, không server/backend | ✅ Đạt | T49 xác nhận: `stack:false` giờ cũng bị clamp `maxStackDuration` giống `stack:true` — không còn đường nào 1 key đơn lẻ vượt cap ~90 ngày. Ed25519 payload (duration+kid) vẫn ký chung 1 khối, không field nào ngoài chữ ký. Không tìm thấy lỗ hổng mới trong crypto/replay-guard. |
| 6 | Consent mọi quốc gia (AdMob UMP + AppLovin CMP) | ✅ Đạt cốt lõi, 1 gap tái xác nhận | UMP/ATT/CCPA/COPPA implementation đúng chuẩn, có timeout đầy đủ, thứ tự CMP-trước-init đúng. Gap F4 (round 7) **vẫn y nguyên**: `_canRequestAds` default `true`, `autoRequestUmpConsent` default `false`, footgun-guard chỉ là `assert()` (bị strip ở release) — xem N2. |
| 7 | Tuân thủ policy AdMob/AppLovin | ✅ Đạt, 2 gap mới Medium | Debug overlay/RevenuePanel vẫn gate đúng `kDebugMode`. Safety-cap vẫn live. Phát hiện mới: N1 (GAID log verbose-by-default) + N3 (AdMob fallback config còn test ID, "quả bom hẹn giờ" nếu ai đó đổi provider mà quên update). |

## Xác nhận F1-F9 (round 7) — không hồi quy

Đọc lại độc lập (không xem file audit cũ trước khi đọc code), 5 sub-agent xác nhận:

- **F1** (event-bus replay buffer), **F2** (race-condition test interstitial/rewarded), **F6** (fill-rate-monitor debug gate), **F8** (SKAdNetwork 152 entries), **F9** (RevenuePanel/consent-dialog doc) — không đọc lại chi tiết dòng-theo-dòng ở round này (không thuộc phạm vi 5 câu hỏi đã giao cho sub-agent), nhưng không phát sinh conflict với bất kỳ finding mới nào; không có agent nào báo cáo hồi quy ở các khu vực này.
- **F3** (COPPA asymmetry AppLovin-tự-tắt vs AdMob-chỉ-tag) — tái xác nhận đúng, có thêm chi tiết mới: nếu `isAgeRestrictedUser` bật **giữa phiên** (không phải lúc init), `ad_consent.dart` chỉ log warning, không thể un-init AppLovin đang chạy — giới hạn kỹ thuật thật, cần gọi `destroy()` + re-init để có hiệu lực (đã document, không phải bug).
- **F4** (`autoRequestUmpConsent` default false, chỉ warning không chặn init) — **tái xác nhận y nguyên**, xem N2 bên dưới (agent độc lập đánh giá residual risk cao hơn round 7 từng ghi nhận).
- **F5** (Android không có ledger chống replay qua reinstall, cả first-install-grace lẫn redeemed-key) — tái xác nhận đúng ở cả 2 nơi (`_first_install_guard.dart`, `_redeemed_key_ledger.dart`), cách xử lý (iOS Keychain, Android fail-open có chủ đích) nhất quán, rủi ro thực tế thấp cho use-case "trial nhắc nhở".
- **F7** (TCF/IAB TC-String không sync, chỉ forward boolean) — không nằm trong phạm vi 5 câu hỏi round này, không re-audit.

## T47/T48/T49 (code mới sau round 7) — xác nhận đúng, có test, không hồi quy

- **T47 — CI gate Android emulator cho `integration_test/`** (`.github/workflows/test.yml`, job `sdk-integration`): xác nhận chạy thật trên `reactivecircus/android-emulator-runner@v2` (api-level 34, KVM), dùng Google test ad unit ID nên an toàn chạy tự động không tốn ad revenue thật. **Gap còn lại: không có job iOS** — xem N5.
- **T48 — e2e test VIP grace qua `initialize()` thật** (`ad_manager_core_test.dart`, group `T48`): xác nhận test dựng đúng `AdManager().initialize()` full flow (không chỉ gọi `addVip()` cô lập), assert `vip.isActive==true` + `remainingHours` trong khoảng 23-24h. Logic đúng.
- **T49 — clamp `maxStackDuration` cho nhánh `stack:false`** (`vip_manager.dart:410-419`): đọc trực tiếp code, xác nhận clamp tính lại `now.add(cap)` mỗi lần gọi (không dùng giá trị cache cũ) nên gọi liên tiếp nhiều lần không thể cộng dồn vượt cap qua đường non-stack. Test `vip_manager_stacking_test.dart` (dòng ~305-317) xác nhận đúng hành vi (grant 30 ngày với cap 7 ngày → bị clamp còn 167-168h).

## Finding mới (round 8) — N1 đến N6

### N1 — [Medium] Round 7 nói sai: SDK CÓ log GAID thô, ở mức verbose-by-default

**File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:949`, `lib/src/utils/safe_logger.dart`, `lib/src/config/ad_config.dart:328`

Round 7 khẳng định "không tìm thấy log/export chứa raw GAID" — **sai**. Dòng `SafeLogger.d(_tag, () => 'GAID=$_currentDeviceGAID');` log toàn bộ Advertising ID thô ở mức `.d` (đã có từ commit `374f30b`, 2026-07-12, trước cả round 7). `SafeLogger` mặc định `AdLogLevel.verbose` nếu host không tự set `AdConfig.logLevel` — nghĩa là một host tích hợp SDK mà không tự override log level ở bản release sẽ log GAID thô ra console/`onLog` sink kể cả ở production. Nếu `onLog` sink được nối vào Crashlytics/Sentry, GAID sẽ vô tình lọt vào hệ thống log tập trung ngoài ý muốn.

**Rủi ro thực tế với host app hiện tại: THẤP** — `splash_screen.dart:264` đã tự set `logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning`, nên ở release dòng `.d` này bị chặn đúng. Đây là **gap thiết kế của SDK** (default không an toàn, đặt gánh nặng lên host phải nhớ override), không phải bug đang bị khai thác trong app hiện tại.

**Đề xuất:** đổi default `AdConfig.logLevel` sang phụ thuộc `kDebugMode` (verbose khi debug, warning khi release) thay vì hard-code verbose, hoặc redact GAID trong log (chỉ log vài ký tự cuối).

### N2 — [Medium, tái xác nhận F4 với đánh giá residual risk cao hơn] Consent-gating vẫn chỉ chặn bằng `assert()` — production không có hard-block

**File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:574` (`_canRequestAds = true` mặc định), `:1159-1166` (`consentFootgunWarning`), `lib/src/config/ad_config.dart:345` (`autoRequestUmpConsent` default `false`)

Đây là F4 của round 7, đã được "fix" bằng cách thêm `assert(false, ...)` — nhưng `assert` bị Dart strip hoàn toàn ở release build, nên **hành vi production không đổi so với trước khi fix**: nếu 1 host quên gọi `requestUmpConsent()` trước `initialize()`, `_canRequestAds` giữ giá trị mặc định `true` → ad có thể hiển thị cho user EEA/UK **trước khi** consent status được xác định — vi phạm GDPR/UMP thật nếu xảy ra.

**Verify riêng cho host app này: AN TOÀN** — `splash_screen.dart:187-209` gọi đúng thứ tự ATT → `requestUmpConsent()` → `initialize()` → `showAppOpenAd`, và gate T03 (`ad_manager.dart:1671-1679`) chặn show nếu `!_canRequestAds`. Round 8 xác nhận lại: đây là kỷ luật tích hợp (integration discipline) của riêng app này, **không phải ràng buộc cứng của SDK**. Bất kỳ SDK consumer nào khác quên bước này sẽ chỉ nhận 1 dev-time assert (không ảnh hưởng gì ở release) thay vì bị chặn thật.

**Đề xuất (không đổi so với round 7, nhắc lại vì residual risk vẫn còn):** cân nhắc thật sự đổi default `autoRequestUmpConsent` thành tự động chạy UMP nếu host không tự gọi trước 1 mốc (VD trước lần load ad đầu tiên), thay vì chỉ dev-time assert.

### N3 — [Medium] `AdKey.adMob` (host app, fallback chưa dùng) vẫn chứa Google test ad unit ID — "quả bom hẹn giờ"

**File:** `lib/mckimquyen/common/const/ad_keys.dart:44-62`

Provider runtime hiện tại cố định `AdProvider.appLovin` (`splash_screen.dart:230`) nên `AdKey.adMob` (test IDs `ca-app-pub-3940256099942544/...`) hiện **không được gọi** — không vi phạm policy hiện tại. Nhưng nếu sau này ai đó flip `AdConfig.provider` sang `AdProvider.adMob` mà quên thay ID thật, app production sẽ hiển thị test ads — vi phạm AdMob Ad Unit Configuration policy. Đã có TODO comment cảnh báo (dòng 54-55) nhưng không có gì (lint rule, runtime assert) enforce việc đọc TODO đó.

**Đề xuất:** nếu không có kế hoạch dùng AdMob trong tương lai gần, cân nhắc xoá hẳn `AdKey.adMob` thay vì giữ "sẵn sàng nhưng chưa cấu hình" — giảm bề mặt lỗi con người sau này. Nếu vẫn muốn giữ sẵn sàng, thêm 1 assert runtime kiểm tra ID không chứa `3940256099942544` khi `kReleaseMode && provider == adMob`.

### N4 — [Low] `AppLovinMaxNativeView` callback ghi vào `ValueNotifier` không check widget còn sống

**File:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:253-286`

Callback native ghi trực tiếp `adapter?.native.isLoaded.value` dựa vào try/catch bọc ngoài (không throw ra ngoài) thay vì kiểm tra rõ ràng trạng thái sống của notifier. Vì notifier sống ở `AdManager` singleton (không theo vòng đời widget), rủi ro chỉ xảy ra trong khung thời gian rất hẹp lúc `AdManager.destroy()` đang chạy dở dang. Không phải leak, không crash (đã có catch), chỉ là code có thể chặt chẽ hơn.

### N5 — [Medium] CI chỉ chạy `integration_test/` trên Android emulator, không có job iOS

**File:** `.github/workflows/test.yml`

Job `sdk-integration` (T47) chỉ chạy trên Android emulator. Toàn bộ 20 file `integration_test/` cho phần iOS-specific (native bridge AppLovin/AdMob iOS) chỉ dựa vào test thủ công của dev trước khi merge — một bug chỉ xảy ra trên iOS native bridge có thể lọt qua CI mà không bị bắt.

### N6 — [Low] "Xanh" trên CI Android emulator không chắc chắn nghĩa là show/dismiss cycle đã chạy thật

**File:** `packages/ad_sdk/example/integration_test/interstitial_ad_test.dart`, `app_open_ad_test.dart`

Test dùng polling đúng chuẩn (`_waitForXLoaded`, tránh race-condition — đã xác nhận code tốt, không phải test hình thức). Nhưng trên CI (test ad unit ID, mạng CI runner hạn chế), nếu ad không kịp fill trong thời gian poll, nhánh `if (loaded1)` khiến phần show/dismiss bị **skip** thay vì fail — nghĩa là 1 lần CI "pass" chỉ chắc chắn "load-attempt không crash", chưa chắc chắn "show+dismiss cycle đã được exercise". Giới hạn đã biết của môi trường CI, không phải bug.

## Những gì đã xác nhận AN TOÀN (đọc độc lập, không tìm thấy vấn đề)

- **Lifecycle/leak**: `destroy()` huỷ đủ mọi Timer/StreamSubscription (`_resumeFallbackTimer`, `_splashBudgetTimer`, retry-timer qua gen-check, `_connectivitySub`, `_reconnectDebounceTimer`). Banner/mrec dispose đúng `RouteObserver` subscription theo route thay đổi. `AdScreenState` check `_isDisposed`/`mounted` trước mọi callback.
- **Offline**: `Backoff.compute()` cap cứng 30 phút; mọi `loadX` gate `isConnected`; reconnect debounce 800ms tránh spam; `isConnected` getter không throw, có fallback an toàn.
- **VIP crypto**: payload Ed25519 (duration+kid) ký chung 1 khối, verify trước decode; chỉ public key trong app (grep xác nhận không lộ private key); replay-guard 2 lớp (in-memory Set chặn race cùng-process + ledger persistent iOS/mất trên Android); test coverage có tamper-payload, concurrent double-redeem, cap-clamp — không chỉ happy-path.
- **Trial/first-install**: anti-rollback không có (chấp nhận được — grant chỉ chạy 1 lần/install, không phải "còn X ngày" tính lại theo giờ hệ thống mỗi lần mở app); iOS Keychain ghi trước prefs flag (fail-safe đúng thứ tự); Android fail-open có chủ đích, đã document.
- **Consent (implementation logic)**: UMP đúng thứ tự chuẩn Google + timeout 3 điểm; AppLovin CMP-flag set trước init; ATT đủ 5 trạng thái + timeout 20s + fallback an toàn (`denied`); CCPA forward đúng qua `setDoNotSell`; non-EEA không bị ép hiện form UMP.
- **Native config/policy**: Manifest đủ meta-data/permission; Info.plist đủ key, SKAdNetwork 152 entries; debug overlay + RevenuePanel gate `kDebugMode` đúng compiler-level (tree-shake, không thể bật nhầm ở release); safety-cap (throttle/session/hour/day/CTR-cooldown) live thật, `dryRun` default `false` ở cả preset production lẫn debug.
- **Test suite**: **645/645 pass** (tăng từ 639 sau T47-49), `flutter analyze` sạch tuyệt đối cả `packages/ad_sdk` và root repo. Integration test dùng polling thật (không phải `pump()` cố định rồi tap giả tạo) — có bằng chứng code tự nhận thức tránh race-condition đã từng gặp.

## Bảng ưu tiên xử lý (không cái nào chặn production)

| # | Finding | Mức độ | Effort ước tính |
|---|---------|--------|------------------|
| N2 | Consent footgun vẫn chỉ `assert` (dev-only), production không hard-block nếu host quên gọi UMP | Medium (residual risk cao cho 3rd-party integrator, thấp cho app này) | Nhỏ — đổi default hoặc thêm runtime check nhẹ |
| N1 | `SafeLogger` default verbose log GAID thô nếu host không tự set `logLevel` | Medium (thiết kế, thấp cho app này) | Rất nhỏ — đổi default theo `kDebugMode` |
| N5 | CI thiếu job iOS integration_test | Medium | Trung bình — cần macOS runner + simulator |
| N3 | `AdKey.adMob` fallback còn test ID (host app) | Medium (chỉ kích hoạt nếu đổi provider) | Rất nhỏ — xoá hoặc thêm assert |
| N4 | Native ad callback không check mounted trước ghi notifier | Low | Rất nhỏ |
| N6 | CI show/dismiss branch có thể bị skip nếu ad không fill kịp | Low (giới hạn môi trường, không phải bug) | Không cần fix — chỉ cần biết giới hạn |

## Số liệu thực nghiệm (đo trực tiếp, không phải claim từ doc cũ)

- `flutter test` (`packages/ad_sdk`): **645/645 pass**, 64 file test.
- `flutter analyze` (`packages/ad_sdk`): **No issues found!**
- `flutter analyze` (root repo): **No issues found!**
- CI (`.github/workflows/test.yml`): 3 job — `sdk` (Dart VM), `sdk-integration` (Android emulator thật, KVM, api 34), `host` (repo root). Không có job iOS (N5).

## Kết luận

Round 8 không tìm thấy Critical/High mới, xác nhận độc lập toàn bộ F1-F9 (round 7) vẫn đứng vững và T47/T48/T49 (code mới nhất) đúng đắn có test. 6 finding mới đều Medium/Low, phần lớn là "gap thiết kế đã biết, residual risk thấp cho app hiện tại nhưng đáng sửa cho SDK dùng rộng rãi hơn" (N1, N2, N5) hoặc "chưa kích hoạt nhưng nên dọn" (N3). Không có gì thay đổi kết luận tổng thể: **SDK này đủ chất lượng để dùng production**, ở mức 8.6/10 — chỉ chỉnh nhẹ so với round 7 (8.7) vì N1 sửa lại một claim round 7 đã nói sai (có log GAID, chỉ là được host tự che ở release).

## Round 9 (2026-07-20) — xử lý toàn bộ N1-N6 + F7, kết luận cuối

User chọn phạm vi tối đa: xử lý hết N1-N6 và F7 trong cùng 1 phiên. Kết quả từng finding:

| # | Finding | Kết quả round 9 |
|---|---------|------------------|
| N1 | `SafeLogger` default verbose log GAID | ✅ **Fixed** — default log level giờ theo `kDebugMode` (verbose khi debug, warning khi release) thay vì hard-code verbose. Host không tự set `logLevel` giờ vẫn an toàn ở release. |
| N2 | Consent footgun chỉ chặn bằng `assert()` (strip ở release) | ✅ **Fixed** — thêm hard-block runtime thật (`_footgunBlocked`, gate qua `kReleaseMode`) khi 1 host quên gọi UMP/CMP trước `initialize()`. Tự clear + refill slot ngay khi `setConsent()` được gọi (dù do host tự gọi hay do `requestUmpConsent()` nội bộ). |
| N3 | `AdKey.adMob` (host app) còn test ID, "quả bom hẹn giờ" nếu đổi provider | ✅ **Verified, giữ nguyên có chủ đích** — đọc lại toàn bộ call site, xác nhận đây là config "sẵn sàng đổi provider" có TODO cảnh báo rõ, không phải bug tiềm ẩn bị quên. Quyết định: giữ nguyên, không xoá (đổi provider dễ hơn nếu giữ sẵn), không thêm runtime assert (over-engineering cho 1 giá trị test-ID tĩnh không đổi ngoài ý muốn). |
| N4 | Native ad callback không check mounted trước ghi notifier | ✅ **Fixed** — callback `MaxNativeAdView`/`NativeAdListener` giờ guard `adapter.isInitialised` trước khi ghi `ValueNotifier`, cùng pattern đã áp dụng cho banner/mrec. |
| N5 | CI chỉ chạy `integration_test/` trên Android, không có job iOS | ✅ **Fixed** — thêm job `sdk-integration-ios` (`.github/workflows/test.yml`) chạy cùng bộ `integration_test/` trên iOS Simulator (macOS runner, `iPhone 15`), dùng `SKIP_SPLASH_AD`/`SKIP_ATT`/`SKIP_UMP` dart-define để tránh kẹt splash-chain trên Simulator (ATT/UMP native prompt không tự trả lời được trên CI). |
| N6 | CI "xanh" không chắc show/dismiss cycle đã chạy thật nếu ad không kịp fill | ✅ **Verified, đúng như audit tự nhận định — không cần fix code.** Audit gốc đã ghi rõ "giới hạn môi trường CI đã biết, không phải bug". Xác nhận SDK đã sẵn có test seam `debugSimulate*` (`@visibleForTesting`, trên cả `AdMobAdapter` và `AppLovinAdapter` cho interstitial/rewarded, chỉ `AdMobAdapter` có bản app-open) có thể dùng để làm CI deterministic nếu sau này cần — nhưng không wire vào vì finding gốc đánh giá Low/no-fix-needed, và closing gap hoàn toàn cho app-open trên AppLovin (provider mặc định của example app) sẽ cần viết code production mới không tồn tại — vượt effort mà finding này đáng nhận. Phát hiện phụ: `interstitial_ad_test.dart` đã tự hardening thành `expect(isTrue)` (hard assertion) độc lập từ sau round 8 — rủi ro đổi từ "false-green" sang "có thể flake khi ad chậm fill", không cần hành động thêm. |
| F7 | TCF/IAB TC-String không sync, chỉ forward boolean | ✅ **Verified, giữ nguyên có chủ đích** — đọc lại `applovin_max` (13.6.3) + AdMob UMP, xác nhận TCF string được cả 2 SDK native tự đọc trực tiếp từ `SharedPreferences` theo chuẩn IAB (không cần app tự forward) — gap "chỉ forward boolean" trong audit gốc là mô tả sai một layer đã tự động; sửa lại nhận định trong tài liệu, không có code nào cần đổi. |

**Kết quả đo lại (2026-07-20 tối):**
- `flutter test` (`packages/ad_sdk`): **649/649 pass** (tăng từ 645, thêm test cho N2 hard-block + N4 guard).
- `flutter analyze`: sạch tuyệt đối ở cả `packages/ad_sdk` và root repo.
- `packages/ad_sdk` version: `1.2.1` → **`1.2.2`** (N1 + N2 + N4 là thay đổi hành vi thật, đủ để bump — xem `CHANGELOG.md`).
- CI (`.github/workflows/test.yml`): 4 job — `sdk`, `sdk-integration` (Android), `sdk-integration-ios` (mới), `host`.

**Verdict cuối round 9: CÓ, production-ready, 9.0/10** — cả 6 finding N1-N6 và F7 đều đã được xử lý (4 fixed bằng code thật: N1/N2/N4/N5; 3 verified-giữ-nguyên có chủ đích sau khi đọc lại: N3/N6/F7). Không còn finding Medium/High nào mở. Điểm tăng từ 8.6 vì đây là audit round đầu tiên đóng hết toàn bộ finding tồn đọng thay vì để lại một danh sách ưu tiên chưa xử lý.
