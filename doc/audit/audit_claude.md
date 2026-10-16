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
| SDK full test suite (sau bổ sung) | **2,708 PASS**, exit 0 (`All tests passed!`) | Unit/widget tests; không phải mọi trạng thái Android/native |
| `flutter analyze lib test` | `No issues found!` sau các thay đổi kiểm thử | Phân tích tĩnh, không đo runtime |
| Example widget tests (lượt này) | **67 PASS**, exit 0 | Widget tests không gọi đầy đủ native ad SDK |
| Visual golden | Pixel golden `test/goldens/ad_loading_dialog.png` tạo và xác minh bằng `test/ad_widget_layout_test.dart` | Chỉ bao phủ loading dialog; chưa có golden cho mọi widget/ad state |
| Interruption integration — S24 Ultra | `android_interruption_test.dart` PASS trên bản example cô lập | Phát lifecycle `paused/resumed` tổng hợp; không mô phỏng cuộc gọi điện, xoay màn hình, OS process kill khi fullscreen ad |
| Network conditioning integration — S24 Ultra | `android_network_conditioning_test.dart` PASS với `debugConnectivityChanged` + `debugConnectivityReady` | Dùng seam, không ngắt Wi-Fi/mobile data thật; chưa kiểm tra latency/jitter/captive portal/mất mạng giữa native request |
| Frame/jank test | `frame_jank_bench_test.dart` PASS trong Flutter test; 20 vòng route mount/unmount với `FrameTiming` callback được đăng ký | Callback test không tạo kết quả performance đáng tin cậy như frame timing trên thiết bị; hiện không assert ngưỡng fps/jank. Chưa chứng minh 60fps |
| Memory / jank profiling — S24 Ultra | Sau 10 vòng mở/đóng Banner: Java Heap 11.3→12.6 MB, Native Heap 38.7→47.4 MB, Total PSS 313.4→317.5 MB (tăng ~4.1 MB PSS trong lượt đo). | Chỉ baseline và một mốc sau 10 chu kỳ, không có lặp độc lập/đợi GC; không kết luận memory leak hoặc ổn định dài hạn. `dumpsys gfxinfo` trả 0 frame cho app, vì vậy jank/FPS chưa đo được. Trước đó script 45 chu kỳ bị treo và đã dừng |
| IAP và mediation | IAP không có trong SDK/example; `gma_mediation_applovin` thuộc consuming app. Pinning-wall đã pass trước đó | Không có IAP cần test trong package; chưa kiểm tra behavior của mediation trên host app thật |
| Release readiness gate | `./tool/release_readiness_gate.sh all`: `release gate: all passed` | Gate release hygiene, không phải production approval |
| Dependency pinning wall | `./tool/check_pinning_wall.sh`: exit 0; resolver chọn `google_mobile_ads 9.0.0`, `gma_mediation_applovin 2.6.2`, `wakelock_plus 1.4.0` | Chưa chạy `--with-builds`; không chứng minh Android/iOS app build |
| Android/AdMob native test — S24 Ultra (`R5CX613VZBR`) | Bản sao example dùng package ID riêng `com.roy.admob.audit.throwaway`; UMP `notRequired`, AdMob init thành công (17 test devices). Sau khi trial 30s kết thúc, cả 2 banner test (320x50 và 468x60) đều load và hiển thị thật (có ảnh chụp `/tmp/s24_banner_loaded.png`). Rewarded video ad phát fullscreen thật (ảnh `/tmp/s24_rewarded_ad_live.png`), callback `onUserEarnedReward` trả về `result=true`, coin tăng 0 → 10 (ảnh `/tmp/s24_rewarded_after_completion.png`). Giả lập force-stop tiến trình rồi mở lại: app khởi động lại bình thường, tự dọn VIP hết hạn, không có FATAL EXCEPTION. Gỡ bỏ app test sạch sẽ sau khi xong | Đã chứng minh Banner và Rewarded ad hiển thị và trả callback thật trên phần cứng Android S24 Ultra. VẪN CHƯA CHỨNG MINH: (1) memory profile lâu dài (chưa đo heap RAM), (2) iOS native runtime, (3) AppLovin inventory thật, (4) form UMP ở vùng EEA thật, (5) tính pháp lý theo từng cấu hình app cụ thể |
| Lifecycle/policy independent review | Không phát hiện lỗi production-blocking đã xác minh trong phạm vi reviewer đọc; focused widget/route 174 tests và adapter/safety 233 tests pass | Đây là review một phần, không thay full audit native/heap; không coi absence of finding là proof không có bug |
| Consent/VIP independent review | Không phát hiện lỗi cụ thể trong consent/provider apply, offline behavior, VIP signed-code/trial security hoặc persistence; focused consent/VIP/API golden tests pass | Review source/test, không thay kiểm thử native trên ma trận thiết bị |
| Android native — S24 Ultra | Smoke test AdMob khởi động, Banner 320x50/468x60 hiển thị, Rewarded test ad phát và `onUserEarnedReward=true`, process force-stop/relaunch, cùng integration `paused/resumed` và seam network test đã chạy | Chỉ một thiết bị Android, AdMob test IDs/example app; network test giả lập bằng seam; không bao phủ app host, iOS, AppLovin, cuộc gọi/rotation/kill giữa fullscreen hoặc captive portal |
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
