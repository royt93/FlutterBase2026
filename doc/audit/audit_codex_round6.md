# Audit độc lập `applovin_admob_sdk` — Codex, Round 6

**Ngày:** 2026-08-23  
**Phạm vi:** `packages/ad_sdk`, version `2.3.2`, HEAD `20f5e21`  
**Kết luận ngắn:** **CHƯA nên dùng SDK này cho production app.** Không còn Blocker làm hỏng toàn bộ SDK như vòng trước, nhưng 5 Major dưới đây còn tạo rủi ro policy, mất crash telemetry và không thu hồi được VIP đã cấp.

## Phương pháp và gate

- Đọc `CLAUDE.md`, toàn bộ `doc/audit/audit_claude.md`, source Dart, adapter, widget, VIP/consent/safety, example và cấu hình Android/iOS; đối chiếu test cho từng đường chính và đường lỗi.
- Không mở lại ba quyết định có chủ ý: network gate của `redeemSignedKey`, QA test-device hashes always-on, MJ9; cũng không mở lại m25.
- `flutter analyze`: **sạch**.
- `flutter test`: **952/952 pass**.
- Thử nghiệm revert-để-thấy-đỏ cho M4: thêm test “CRL mới thu hồi grant đang active” và minimum fix tạm thời → test file xanh 16/16; bỏ riêng fix → đỏ `Expected: false, Actual: true`; sau đó phục hồi cả source/test. Không commit, không push.
- Các test hiện tại rất mạnh ở state machine và callback giả, nhưng vẫn không thay thế runtime thật cho platform channel, native overlay và process/lifecycle trên thiết bị iOS/Android.

# BLOCKER

**Không phát hiện Blocker mới.** Các lỗi UMP lockout, consent trước init, adapter orphan, callback muộn, load/show watchdog, reward callback ordering và dispose-during-await đã được sửa trong code hiện tại và có regression test.

# MAJOR

## M1 — Crash guard mặc định nuốt lỗi của host nếu stack đi qua SDK, đồng thời tự bọc lặp sau mỗi re-init

**Bằng chứng:** `lib/src/config/ad_config.dart:409`, `lib/src/core/ad_manager.dart:1840-1842`, `lib/src/core/ad_crash_guard.dart:18-19,58-83`.

Attribution chỉ là `stack.toString().contains('package:applovin_admob_sdk/')`. Callback của host (ví dụ logic trong `onEarnedReward`) được SDK gọi nên một exception của chính host vẫn có frame SDK; guard trả về ở `ad_crash_guard.dart:65` hoặc `true` ở `:79`, không chain tới Crashlytics/Sentry. `installAdCrashGuard()` cũng không có `_installed`/uninstall; mỗi `destroy → initialize` tạo thêm closure giữ handler cũ.

**Hậu quả người dùng/production:** app có thể tiếp tục chạy trong trạng thái sai nhưng đội vận hành mất crash report gốc; chuỗi handler tăng theo số re-init và giữ object cũ trong process.

**Minimum fix:** default `enableCrashGuard=false`; làm install idempotent và có uninstall; trong release luôn recover slot **rồi chain** tới handler trước (không swallow). Nếu vẫn muốn swallow, chỉ làm với exception được SDK tự bắt tại boundary cụ thể, không suy từ chuỗi stack.

## M2 — Resume App Open không biết lần background vừa rồi do người dùng click quảng cáo

**Bằng chứng:** click chỉ cập nhật CTR tại `lib/src/core/ad_safety_config.dart:621-642`; lifecycle ghi background ở `:644-650`; resume gọi `showAppOpenAdOnResume()` tại `lib/src/core/ad_manager.dart:4333-4343`; gate resume ở `:3386-3455` không có `lastAdClick`.

Banner/MREC/native và fullscreen đều gọi `recordAdClick` (ví dụ `lib/src/widget/banner_ad_widget.dart:535`, `mrec_ad_widget.dart:475`, `native_ad_widget.dart:396`). Click mở browser/store, app pause; quay lại sau cửa sổ timing hiện có thì App Open có thể hiện ngay trên lần trở về từ quảng cáo.

**Hậu quả:** UX “ad nối ad”, tăng nguy cơ placement/accidental-click bị AdMob hoặc AppLovin đánh giá xấu; xảy ra trên thiết bị thật vì phụ thuộc external activity và lifecycle.

**Minimum fix:** lưu `lastAdClickAt` và cờ background có nguồn từ click; chặn App Open cho lần resume tương ứng (tối thiểu 30 giây hoặc tới resume kế tiếp), rồi clear cờ.

## M3 — `bypassSafety=true` bỏ cả lớp chống invalid traffic, không chỉ bỏ frequency cap

**Bằng chứng:** `lib/src/core/ad_manager.dart:3345-3364` bọc toàn bộ `AdSafetyConfig.canShowFullscreenAd()` trong `if (!bypassSafety)`; suspicious pause được kiểm đầu tiên tại `lib/src/core/ad_safety_config.dart:418-427`. Example dùng bypass cho splash tại `example/lib/main.dart:517`.

**Hậu quả:** splash App Open vẫn có thể show khi CTR/click-spam đã kích hoạt pause 30 phút–24 giờ. Đây chính là lúc phải giảm traffic, nhưng API public cho phép bỏ toàn bộ guard.

**Minimum fix:** tách `canServeAdsUnderFraudGuard()` khỏi throttle/cap; luôn chạy fraud/suspicious-pause và consent/VIP/mutex, chỉ cho `bypassSafety` bỏ cold-start/frequency caps.

## M4 — CRL không thu hồi VIP signed đã active

**Bằng chứng:** `lib/src/vip/vip_manager.dart:757-764` chỉ kiểm CRL khi redeem; `refreshRevocationList` chỉ thay `_revokedKeyIds`, cache và log tại `:869-875`, không xoá entry `SIGNED_<kid>` trong `_entries`.

**Hậu quả:** code bị lộ và đã redeem trên nhiều máy vẫn tắt toàn bộ quảng cáo tới hết cửa sổ (có thể 90 ngày), dù chủ sản phẩm đã phát hành CRL hợp lệ. Tính năng “revocation” hiện chỉ ngăn thiết bị mới.

**Minimum fix:** sau khi verify/apply CRL mới, normalize `kid`, purge mọi entry `SIGNED_<kid>` tương ứng, `await _save()`, `_refreshActive()`, `_scheduleNextExpiry()`. Đây là finding đã được kiểm chứng xanh/đỏ bằng production path như phần phương pháp.

## M5 — API public `resetSession()` xoá luôn fraud history đã persist; example phát hành nút gọi trực tiếp

**Bằng chứng:** `lib/src/core/ad_safety_config.dart:667-690` xoá click window, violation count, active pause và gọi `setSuspiciousCount(0)`; `example/lib/main.dart:1980-1985` có nút “Reset session counters”. Class này được export công khai.

**Hậu quả:** host copy example hoặc để màn hình diagnostics trong release có thể vô hiệu progressive cooldown ngay trên máy đang tạo traffic bất thường; tên nút nói chỉ reset counter nhưng thực tế xoá anti-fraud state.

**Minimum fix:** `resetSession()` chỉ reset session/hour counters; chuyển reset fraud sang API test-only/debug-only và chặn bằng `isActuallyRelease`; bỏ/gate nút example.

# MINOR

## m1 — AVP2 bundle binding fail-open khi platform channel lỗi

**Bằng chứng:** `lib/src/vip/vip_manager.dart:720-738`; đọc bundle id lỗi thì truyền `null` vào verify ở `:740-748`.

**Hậu quả:** đúng lúc `PackageInfo` lỗi/late registration, key AVP2 rò từ app khác được chấp nhận. Không cần forge chữ ký.

**Minimum fix:** AVP2 phải fail-closed với lỗi “cannot verify app binding”; thêm timeout hữu hạn và retry UX.

## m2 — CRL fetch không có timeout

**Bằng chứng:** `lib/src/vip/vip_manager.dart:838-850`, đặc biệt `await revocationProvider.fetchSignedCrl()` tại `:846`; tài liệu khuyên host gọi định kỳ tại `:830-831`.

**Hậu quả:** provider HTTP không timeout tạo future treo và các lần periodic có thể chồng lên nhau.

**Minimum fix:** timeout 10–20 giây và mutex join/skip một refresh đang chạy; giữ semantics fail-open hiện tại.

## m3 — Fraud/cap dùng wall clock và reset được bằng chỉnh giờ

**Bằng chứng:** `lib/src/core/ad_safety_config.dart:420-427,621-625,646-650,667-689,818-820` dùng trực tiếp `DateTime.now()` cho pause, click window và session.

**Hậu quả:** lùi đồng hồ có thể làm pause hết hiệu lực hoặc làm duration âm; tiến đồng hồ có thể làm cửa sổ click/hour bị purge. Đây không phải MJ9 và không đụng entitlement VIP.

**Minimum fix:** dùng `Stopwatch` cho state chỉ sống trong process/session; wall clock chỉ dùng persistence/telemetry và clamp khi load.

## m4 — GPP chỉ được expose raw, không tự apply opt-out US states

**Bằng chứng:** `lib/src/core/iab_storage.dart:51-52,127-143` chỉ parse legacy `IABUSPrivacy_String`; comment `:134-137` chủ ý không decode GPP. `lib/src/core/ad_manager.dart:745-760` chỉ expose raw GPP/USP, còn `AdConsent.doNotSell` phải do host set.

**Hậu quả:** claim “consent mọi quốc gia” phụ thuộc host tự decode/map US-state signal; SDK không thể tự chứng minh `doNotSell` đúng cho mọi bang/quốc gia chỉ từ UMP/CMP.

**Minimum fix:** đổi claim/document rõ host responsibility, hoặc dùng parser GPP chuẩn và map signal hợp lệ vào cả AppLovin `setDoNotSell` lẫn AdMob RDP trước request.

## m5 — Release package vẫn mang dependency UI `confetti`

**Bằng chứng:** `pubspec.yaml:101`; chỉ phục vụ `lib/src/vip/vip_redeem_screen.dart`.

**Hậu quả:** mọi consumer SDK quảng cáo đều kéo thêm runtime package dù không dùng màn hình redeem mẫu.

**Minimum fix:** tách redeem UI/example thành package phụ hoặc thay hiệu ứng bằng implementation nhỏ không thêm runtime dependency.

# ĐÁNH GIÁ 7 TÍNH NĂNG

## 1. Chọn AdMob/AppLovin, Android + iOS — **ĐẠT CÓ ĐIỀU KIỆN**

- Provider được chọn tại `lib/src/core/ad_manager.dart:2162-2168`; adapter cũ được dispose trước re-init và init adapter có timeout/dispose khi fail (`:2182-2229`).
- Package là pure Dart wrapper; platform implementation nằm ở `google_mobile_ads`, `applovin_max`, ATT, storage. Example có Android App ID/permissions tại `example/android/app/src/main/AndroidManifest.xml:1-47`, iOS GAD/AppLovin/ATT/SKAdNetwork tại `example/ios/Runner/Info.plist:48-66+`.
- Smoke 2.3.2 đã build APK và iOS simulator theo audit history. Tuy nhiên cần chạy lại ma trận runtime trên **thiết bị thật** cho cả hai provider trước release; compile/simulator không chứng minh callback/overlay/lifecycle.

## 2. Có mạng / không mạng — **ĐẠT**

- Mọi adapter internal reload dùng shared gate gồm VIP, cap, consent và connectivity tại `lib/src/core/ad_manager.dart:2169-2176`.
- Load entry point chặn offline và reconnect refill; widget collapse/retry đã có test. Offline không crash và không cố show cache khi gate đóng; online lại có self-heal UMP/refill.
- VIP signed vẫn cố ý yêu cầu connectivity khi redeem (`lib/src/vip/vip_manager.dart:692-716`); đây là product decision, không tính là lỗi của tính năng offline-ad.

## 3. Banner / App Open / Rewarded / Interstitial: pháp lý, lifecycle, leak — **KHÔNG ĐẠT**

- Lifecycle core hiện tốt: fullscreen mutex, freshness AdMob, load/show watchdog, late-callback identity, listener disposal, consent-withdrawal cache discard và reward ordering đều có test.
- Không đạt do M1 (global handler/observability), M2 (App Open sau click), M3/M5 (fraud guard bypass/reset). Các lỗi này không phải memory leak native phổ biến nữa, nhưng đủ tạo rủi ro production/policy.

## 4. Trial mode 1 ngày — **ĐẠT CÓ GIỚI HẠN ĐÃ CHẤP NHẬN**

- Release `FirstInstallVipGrace.auto` là 1 ngày; grant một lần theo prefs và Keychain iOS, thứ tự durable marker trước prefs đúng tại `lib/src/core/ad_manager.dart:1947-2006`.
- Android reinstall/clear-data và MJ9 vẫn là giới hạn local-only đã document/chấp nhận. Không có cách Dart thuần, offline, bảo toàn VIP cũ mà đóng tuyệt đối MJ9; phương án an toàn còn lại chỉ là clamp high-water mark tương lai để giảm mất VIP oan, không phải chống cheat hoàn chỉnh.

## 5. VIP bằng code, không backend — **KHÔNG ĐẠT HOÀN TOÀN**

- Ed25519 verification, key rotation, AVP2 expiry/bundle binding, per-device ledger và 90-day cap là thiết kế tốt; private key không nằm trong SDK.
- Không đạt hoàn toàn vì M4 (CRL không revoke grant active) và m1 (AVP2 binding fail-open). Network gate khi redeem là chủ ý và không bị mở lại.

## 6. Consent mọi quốc gia, apply cả AppLovin + AdMob — **ĐẠT CÓ ĐIỀU KIỆN / CLAIM QUÁ RỘNG**

- UMP chạy trước adapter init; AppLovin nhận `setHasUserConsent`/`setDoNotSell` trước init tại `lib/src/adapters/applovin_adapter.dart:463-495`; AdMob nhận COPPA/TFUA tại `lib/src/core/ad_consent.dart:107-135` và NPA/RDP per request tại `lib/src/adapters/admob_adapter.dart:619-634`.
- Consent withdrawal discard cache và rebuild inline ads. TCF/USP native storage được đọc đúng store.
- “Mọi quốc gia” chỉ đúng nếu host cấu hình UMP messages và tự xử lý các regime ngoài boolean model. GPP không được decode/apply tự động (m4), nên SDK không thể tự claim global completeness.

## 7. Policy AdMob/AppLovin — **KHÔNG ĐẠT**

- Điểm tốt: test-device handling là chủ ý; no auto-click; ad labels; consent gate; frequency/daily/session caps; reward chỉ grant từ callback; splash/resume mutex và dialog guard.
- Không đạt vì M2, M3, M5. Ngoài ra disclosure rewarded vẫn là opt-in (`lib/src/core/ad_screen.dart:141-156,205-222`), nên host phải luôn mô tả reward/điều kiện trước show.

# Điều kiện tối thiểu để đổi verdict sang production

1. Sửa và thêm regression test cho M1–M5; ưu tiên M2/M3/M5 trước vì liên quan traffic/policy.
2. Với M4, giữ test production-path đã mô tả; test cả case-insensitive `kid`, persistence sau restart và CRL không revoke entry không-signed.
3. Chạy runtime matrix thiết bị thật: Android+iOS × AdMob+AppLovin × online/offline/reconnect × consent accept/reject/withdraw × background từ click ad × callback tới muộn/force-close overlay.
4. Đổi tài liệu từ “consent mọi quốc gia” thành contract cụ thể, hoặc implement GPP/regional mapping có test native-store thật.

# VERDICT

**Không nên dùng bản hiện tại cho production app.** Có thể dùng cho staging/QA. Nền state machine và test coverage đã tiến bộ rõ rệt, không còn Blocker mới, nhưng các Major còn lại nằm đúng vùng production khó quan sát bằng unit test: external activity/lifecycle, global error handler, invalid-traffic safety và entitlement revocation.

## ĐIỂM 7.4/10
