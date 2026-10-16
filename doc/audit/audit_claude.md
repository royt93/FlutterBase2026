# Audit SDK và example — applovin_admob_sdk 3.5.0

Ngày: 2026-10-16  
Baseline: `2c8971c51bad0525a660b0fdf6cc310d84ae64eb` (`main`)  
Latest pub.dev: `3.5.0`, xuất bản 2026-10-15.  
Phạm vi: source SDK + example; Android/iOS; AdMob/AppLovin; online/offline; ad formats/lifecycle; trial/VIP; consent/policy; kiểm tra tĩnh và automated tests.

## Kết luận

**CHƯA ĐỦ BẰNG CHỨNG ĐỂ DUYỆT SDK VÀO PRODUCTION CỦA ỨNG DỤNG NÀY.** Source và automated tests cho thấy nền tảng kỹ thuật có mức bảo vệ tốt; lượt kiểm tra này không xác minh được một lỗi blocking mới trong lifecycle/policy, và các test hiện có đều xanh. Nhưng test xanh không chứng minh hành vi native trên cả hai OS/provider, không chứng nhận tuân thủ pháp lý của app, và không chứng minh không memory leak. Quyết định phù hợp: dùng thử nghiệm có kiểm soát sau khi chủ app hoàn thành ma trận native và compliance bên dưới; chưa phát hành rộng chỉ dựa trên audit này.

Đây là báo cáo độc lập do Claude tạo. Không phải báo cáo của Gemini/Codex và không phải chứng nhận từ Google, AppLovin hoặc luật sư. Không thay đổi source, dependency, version hoặc git history trong lượt audit.

## Bằng chứng mới trong lượt audit

| Kiểm tra | Kết quả | Giới hạn |
|---|---|---|
| pub.dev metadata/changelog | Latest `3.5.0`, xuất bản `2026-10-15`; changelog nêu consent history pagination, giới hạn cohort history, validate metrics và test CLI exports | Chưa tải và so toàn bộ archive pub.dev với source tree; version trùng không chứng minh archive đồng nhất |
| `flutter analyze` trong `packages/ad_sdk/` | `No issues found!` | Phân tích tĩnh, không kiểm tra native runtime hoặc policy |
| SDK full test suite | **2,700 PASS**, exit 0 (`All tests passed!`) | Unit/widget tests; không phải integration/device test |
| Example widget tests | **21 suites, 131 tests PASS**, JSON reporter kết thúc `success: true`, exit 0 | Widget tests không gọi đầy đủ native ad SDK |
| Release readiness gate | `./tool/release_readiness_gate.sh all`: `release gate: all passed` | Gate release hygiene, không phải production approval |
| Dependency pinning wall | `./tool/check_pinning_wall.sh`: exit 0; resolver chọn `google_mobile_ads 9.0.0`, `gma_mediation_applovin 2.6.2`, `wakelock_plus 1.4.0` | Chưa chạy `--with-builds`; không chứng minh Android/iOS app build |
| Lifecycle/policy independent review | Không phát hiện lỗi production-blocking đã xác minh trong phạm vi reviewer đọc; focused widget/route 174 tests và adapter/safety 233 tests pass | Đây là review một phần, không thay full audit native/heap; không coi absence of finding là proof không có bug |
| Consent/VIP independent review | Không phát hiện lỗi cụ thể trong consent/provider apply, offline behavior, VIP signed-code/trial security hoặc persistence; focused consent/VIP/API golden tests pass | Review source/test, không thay kiểm thử native trên ma trận thiết bị |
| Android/iOS native, AppLovin inventory thật | Chưa chạy ma trận thiết bị/provider trong lượt này | Không có bằng chứng cho từng tổ hợp OS × provider hoặc production ad inventory |
| Memory/native allocation | Chưa profile heap/native memory qua lặp route, load/show/dismiss/reinit | Không thể kết luận “không leak” |

## Kết quả theo yêu cầu

### Android/iOS và hai provider

SDK tổ chức provider qua `AdProviderAdapter`, với adapter riêng cho AdMob và AppLovin. Dependency và platform constraints được khai báo trong `pubspec.yaml`; SDK yêu cầu Flutter `>=3.38.1`, Android/iOS. Source/test architecture là bằng chứng thiết kế, không chứng minh build và vận hành native cho mọi tổ hợp. Cần build release-shaped cho Android và iOS, từng provider, bằng đúng cấu hình ứng dụng và dependency pin đã chọn.

### Mạng và offline

Có quản lý connectivity, trạng thái consent và retry/reconcile; VIP đã kích hoạt tiếp tục dùng offline. VIP code redemption chủ ý yêu cầu kết nối mạng, dù chữ ký Ed25519 được xác minh local. Đây là product decision đã được chủ dự án chấp thuận, không phải finding mới. Chưa kiểm tra thực tế cold start offline, mất mạng khi native ad đang tải, reconnect, captive portal và resume cho cả provider/OS.

### Ad formats, lifecycle, fullscreen và memory

SDK có state machine `AdSlot`, inline ad state per widget instance, route/visibility lifecycle, fullscreen coordination và teardown. Reviewer độc lập đọc các đường chính và không xác minh được lỗi production-blocking trong phạm vi lifecycle/policy; cụ thể có dispose listeners/timers/controller và xử lý slot. Đây không phải heap/native leak test. Integration caveat phải giữ: host dùng `active` hoặc visibility phù hợp cho tab `IndexedStack`; custom overlay cần báo bằng `markCustomOverlayOnScreen`; nested Navigator cần đăng ký observer/helper tương ứng. Không tuyên bố các trường hợp host không khai báo tự được SDK phát hiện.

### Trial 1 ngày và VIP không backend

Trial release là 24 giờ; anti-reinstall không tuyệt đối. iOS dùng Keychain; Android dựa vào Auto Backup cho preference marker và có thể bị vượt qua khi backup tắt/khác account. Không có backend nên một VIP promotion key có thể dùng một lần trên mỗi thiết bị, không thể bảo đảm globally single-use; đồng hồ và entitlement local cũng không tương đương một dịch vụ license chống thiết bị bị kiểm soát. Những giới hạn này là chủ ý đã ghi trong dự án; không tái nêu như lỗi chưa được chấp thuận. Không dùng cơ chế này làm giấy phép trả tiền globally single-use nếu yêu cầu đó chưa thay đổi.

### Consent, luật và policy

Source có UMP/ATT, lưu IAB/TCF, tín hiệu CCPA/Do Not Sell, COPPA/TFUA cho AdMob và giới hạn AppLovin theo API khả dụng. AppLovin age restriction được gate ở init; API MAX 4.x không cung cấp setter COPPA runtime. Finding consent round 75 về `ConsentManager.set()` và cấu hình AdMob đã có commit fix `78046c2`; không đưa lại thành lỗi hiện hành nếu chưa tái hiện trên source mới.

Không thể khẳng định “đúng luật mọi quốc gia” hoặc “đảm bảo tuân thủ policy” chỉ từ SDK. Việc tuân thủ còn phụ thuộc audience/age rating, CMP và cấu hình dashboard, privacy notice, disclosures/reward conditions, ad placement, app-ads.txt và cách host dùng API. Google/AppLovin có thể thay đổi policy; chủ app cần rà soát tài liệu chính thức và cấu hình tài khoản trước khi phát hành.

## Finding

**Không xác minh được finding mới mức BLOCKER/MAJOR trong các kiểm tra tự chạy của lượt này.** Các giới hạn VIP/trial nêu trên là các giới hạn thiết kế đã được chấp thuận, không được tính là finding mới. Các phần native iOS/AppLovin, legal review và memory profiling là khoảng trống bằng chứng, không được đánh tráo thành lỗi source.

## Điều kiện tối thiểu trước production rộng

1. Chạy build Android/iOS release-shaped bằng dependency pin của app; lưu lệnh, Flutter/Xcode/Gradle versions và kết quả thật.
2. Chạy native smoke/integration theo ma trận Android + iOS × AdMob + AppLovin, gồm init, load/show/dismiss cho từng format được app dùng, consent required/reject/withdraw, offline startup, mất mạng/reconnect, app background/resume và teardown. Ghi rõ ad test IDs, thiết bị, test nào bị skip.
3. Trên thiết bị thật, lặp show/dismiss, điều hướng, ẩn/hiện tab, reinitialize và kiểm tra heap/native allocations; chỉ kết luận memory sau khi có profile và ngưỡng/so sánh cụ thể.
4. Chủ app rà soát audience, CMP, privacy notice, disclosures, ad placement, app-ads.txt và cấu hình AdMob/AppLovin theo policy hiện hành; ghi nhận khu vực phát hành và người chịu trách nhiệm compliance.
5. Nếu VIP code bán như license, chốt rõ chấp nhận được replay giữa thiết bị hay phải có backend claim. Với thiết kế offline hiện tại, không thể đảm bảo single-use toàn cục.

## Nguồn

- [pub.dev package](https://pub.dev/packages/applovin_admob_sdk)
- [pub.dev changelog](https://pub.dev/packages/applovin_admob_sdk/changelog)
- [Google AdMob privacy & consent](https://developers.google.com/admob/flutter/privacy)
- [Apple App Tracking Transparency](https://developer.apple.com/documentation/apptrackingtransparency)
- Source: `packages/ad_sdk/lib/src/consent/consent_manager.dart`, `lib/src/core/ad_consent.dart`, `lib/src/vip/signed_vip_key.dart`, `lib/src/vip/vip_manager.dart`, `lib/src/vip/_first_install_guard.dart`, `pubspec.yaml`; findings/coverage limits also cite `doc/audit/audit_claude_round75.md`.
