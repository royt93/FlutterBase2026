# Audit SDK và example — applovin_admob_sdk 3.5.0

Ngày: 2026-10-16  
Baseline: `2c8971c51bad0525a660b0fdf6cc310d84ae64eb` (`main`)  
Latest pub.dev: `3.5.0`, xuất bản 2026-10-15.  
Phạm vi: source SDK + example; Android/iOS; AdMob/AppLovin; online/offline; ad formats/lifecycle; trial/VIP; consent/policy; kiểm tra tĩnh và automated tests.

## Kết luận

**CHƯA ĐỦ BẰNG CHỨNG ĐỂ DUYỆT SDK VÀO PRODUCTION CỦA ỨNG DỤNG NÀY.** Source và automated tests cho thấy nền tảng kỹ thuật có mức bảo vệ tốt; lượt kiểm tra này không xác minh được một lỗi blocking mới trong lifecycle/policy, và các test hiện có đều xanh. Nhưng test xanh không chứng minh hành vi native trên cả hai OS/provider, không chứng nhận tuân thủ pháp lý của app, và không chứng minh không memory leak. Quyết định phù hợp: dùng thử nghiệm có kiểm soát sau khi chủ app hoàn thành ma trận native và compliance bên dưới; chưa phát hành rộng chỉ dựa trên audit này.

Đây là báo cáo độc lập do Claude tạo. Không phải báo cáo của Gemini/Codex và không phải chứng nhận từ Google, AppLovin hoặc luật sư.

> **Quy định thiết bị từ 2026-10-17:** Chỉ dùng Pixel 7 Pro cho kiểm thử native. Không dùng S24 Ultra nữa. Các hàng ghi S24 Ultra là kết quả lịch sử đã đo trước khi có quy định này; không lặp lại trên thiết bị đó.

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
| Memory profiling — Pixel 7 Pro (debug, 30 chu kỳ xác nhận) | Mỗi vòng mở/đóng Banner xác nhận bằng `BannerAdWidget.initState`/`loadBanner` và `POP`/`disposing banner`: **30/30**; `FATAL EXCEPTION`: 0. PSS sau trim-memory: baseline **576.3 MB**, sau 15 chu kỳ **692.0 MB**, sau 30 chu kỳ **689.1 MB** (giảm 2.9 MB từ mốc 15). Native Heap: **53.3 → 69.7 → 70.0 MB**; Java Heap: **15.1 → 39.5 → 34.0 MB**. | PSS/heap cao hơn baseline sau 30 vòng; giảm nhẹ từ vòng 15→30, nhưng không phải heap dump hay benchmark lặp, và `am send-trim-memory` không bảo đảm GC hoàn tất. Đây là một debug run trên Pixel 7 Pro, không phải S24/profile/release. **Không thể kết luận có hay không có memory leak** chỉ từ số này |
| Jank — S24 Ultra (debug, 10 vòng) | Android `dumpsys gfxinfo`: **459 frames rendered, 64 janky (13.94%)**, 30 Missed Vsync, 44 High input latency | Debug build + ad loading + animated route transitions; chỉ chỉ báo để điều tra, không phải profile/release benchmark và không đại diện mọi cảnh app |
| Mất mạng giữa chừng (mid-load cut) — Pixel 7 Pro | Mở màn Banner và ngắt Wi-Fi + dữ liệu ngay trong cửa sổ 200 ms: log `loadBanner [AdMob] 🔄` ngay lập tức nhận `loadBanner [AdMob] ❌ 0` (bắt lỗi an toàn, `FATAL: 0`). Sau khi bật lại Wi-Fi: log `network back online → refilling ad slots + banners`, 2 banner tự nạp lại `loadBanner [AdMob] ✅` và ghi nhận 2 impressions thành công | Một chu kỳ kiểm tra; chứng minh native SDK bắt lỗi ngắt kết nối giữa lúc request mà không crash, và tự nạp lại khi mạng phục hồi |
| Đo RAM & Jank — Pixel 7 Pro (debug, 20 chu kỳ xác nhận) | Mở/đóng Banner 20 lần đều xác nhận bằng log (`initState`/`loadBanner` và `POP`/`disposing banner`): **20/20**; `FATAL EXCEPTION`: 0. Ép GC (`am send-trim-memory`) tại mỗi mốc. PSS: baseline **619.4 MB**, sau 10 chu kỳ **639.0 MB** (+19.6 MB), sau 20 chu kỳ **671.1 MB** (+32.1 MB so với mốc 10; tổng tăng +51.7 MB PSS sau 20 chu kỳ). Native Heap tăng 57.4 → 73.1 → 72.0 MB (đi ngang ở mốc 20); Java Heap tăng 34.2 → 37.2 → 46.7 MB. Android `dumpsys gfxinfo`: **433 frames rendered, 129 janky (29.79%)**, 122 Missed Vsync, 17 High input latency | 29.79% jank và tăng ~51.7 MB PSS đo trên **debug build** với logcat và hoạt ảnh chuyển màn hình liên tục; bộ nhớ WebView/GMA tích lũy và cần đo sâu bằng heap dump trên bản profile/release thật để phân biệt giữa cache nội bộ của Google Mobile Ads và rò rỉ thực sự |
| Profile/release jank thử lại | Đã build `app-profile.apk` cô lập (ID riêng, 82 MB) và cài lên Pixel 7 Pro (S24 Ultra đã rút cáp). SDK khởi tạo thành công nhưng kích hoạt `_testIdFootgunBlocked` do phát hiện Google test ad unit IDs trong profile build (`canRequestAds` giữ cố định là `false` để ngăn phát test ads $0 vi phạm policy AdMob trong release). Vì vậy quảng cáo không được nạp ở profile mode khi dùng test IDs. Không có số liệu jank từ bản profile. Đã gỡ app thử | **Chưa có số liệu profile/release.** Con số jank 13,94% chỉ thuộc debug build. Để đo profile cần AdMob ad unit staging hợp lệ, hoặc cơ chế bypass có kiểm soát được chủ SDK chấp thuận |
| Consent EEA thật — Pixel 7 Pro | Bản example cô lập (`com.roy.admob.pixel.audit`, đã xác minh bằng `aapt`) chạy với `UMP_EEA_DEBUG=true` và test-device hash do Google in ra. Log `consent status: required`; form UMP "Publisher Test Ads" hiện thật với 3 nút Consent / Do not consent / Manage options (có ảnh chụp). Bấm Do not consent: log `status=obtained formShown=true`, `canRequestAds=true`, cảnh báo TCF không cho cá nhân hóa, và AdMob nhận `nonPersonalizedAds=true` | Chỉ nhánh "từ chối" trên một thiết bị với geography giả lập; chưa thử Consent, Manage options, rút lại consent, vùng EEA thật, và chưa kiểm tra bên AppLovin |
| Mất mạng thật — Pixel 7 Pro | Tắt Wi-Fi bằng `svc wifi disable` (ping 8.8.8.8: Network unreachable); mở màn Banner: log `_initBanner ⏭️ offline`, không crash. Bật Wi-Fi lại: log `network back online → refilling ad slots + banners`, 2 banner nạp `✅` sau khoảng 8 giây và ghi nhận 2 impressions (có ảnh chụp banner 468x60 và 320x50) | Một chu kỳ ngắt/bật, Wi-Fi duy nhất; không ngắt giữa lúc native đang tải, không thử mạng chậm/captive portal. Lượt này chỉ tắt Wi-Fi (cài đặt dữ liệu di động còn bật nhưng Pixel không có SIM sẵn sàng); `ping` chứng minh không có đường ra Internet. Đã lặp lại với cả hai tắt ở hàng "Mất mạng chặt" bên dưới |
| Consent cấp rồi rút lại — Pixel 7 Pro | Bản example cô lập `com.roy.admob.pixel.audit2` (đã xác minh bằng `aapt`), EEA debug. Form UMP hiện (`status: required`); bấm **Consent**: `status=obtained`, AdMob nhận `nonPersonalizedAds=false (hasUserConsent=true)`. Mở lại bằng nút **Privacy Options** (màn VIP / redeem) và bấm **Do not consent**: log `privacy options done`, `personalisation withdrawn — discarding cached fullscreen ads and rebuilding inline ads`, và AdMob nhận `nonPersonalizedAds=true (hasUserConsent=false)` | Một thiết bị, geography EEA giả lập; chưa thử nút Manage options, chưa thử trên AppLovin, và chưa kiểm tra ad đã nạp trước đó có thực sự bị loại khỏi màn hình |
| Mất mạng chặt (Wi-Fi + dữ liệu tắt) — Pixel 7 Pro (lặp lại, đã hoàn tất) | Bản `com.roy.admob.pixel.audit3` (xác minh `aapt`; lần build đầu thất bại nên đã build lại sạch). Script kiểm tra app đang focus trước mỗi thao tác. Sau khi tắt Wi-Fi và dữ liệu: `Active default network: none`, `ping: Network is unreachable`. Mở Banner: log `_initBanner ⏭️ offline` ×4, không crash (`FATAL EXCEPTION`: 0). Bật mạng lại (25 giây sau): `ping` 39,6 ms, `loadBanner 🔄` rồi `✅`, 2 impressions ghi nhận | Một thiết bị, một chu kỳ ngắt/bật. Pixel này `OUT_OF_SERVICE` (SIM chưa sẵn sàng) nên dữ liệu di động vốn không có đường ra: lượt trước (chỉ tắt Wi-Fi) thực chất cũng là offline hoàn toàn, nghĩa là hai lượt cùng một điều kiện. Chưa thử ngắt giữa lúc native đang tải, mạng chậm hay captive portal |
| IAP và mediation | IAP không có trong SDK/example; `gma_mediation_applovin` thuộc consuming app. Pinning-wall đã pass trước đó | Không có IAP cần test trong package; chưa kiểm tra behavior của mediation trên host app thật |
| Partner integration bundle & junior guide | Tạo script `tool/package_partner_example.sh` đóng gói standalone `example/` trỏ sang pub.dev `^3.5.0` kèm `AD_PROMPT_FLUTTER.MD` và `README_PARTNER.md`; verify giải nén độc lập và chạy `flutter pub get` + `flutter analyze` đạt 0 issue | Đã kiểm tra giải nén và phân tích tĩnh; chưa chạy build APK độc lập từ file zip trên thiết bị |
| Release readiness gate | `./tool/release_readiness_gate.sh all`: `release gate: all passed` | Gate release hygiene, không phải production approval |
| Dependency pinning wall | `./tool/check_pinning_wall.sh`: exit 0; resolver chọn `google_mobile_ads 9.0.0`, `gma_mediation_applovin 2.6.2`, `wakelock_plus 1.4.0` | Chưa chạy `--with-builds`; không chứng minh Android/iOS app build |
| Android/AdMob native test — S24 Ultra (`R5CX613VZBR`) | Bản sao example dùng package ID riêng; UMP `notRequired`, AdMob init thành công (17 test devices). Hai banner test (320x50, 468x60) load/hiển thị; Rewarded test ad phát, callback `onUserEarnedReward=true`, coin tăng 0→10. Force-stop/relaunch mở app lại. Bản benchmark riêng xác nhận bằng route/load/dispose logs đủ 10 chu kỳ Banner và thu thập meminfo/gfxinfo. Các app audit đã gỡ; app host vẫn nguyên | Chỉ một thiết bị, debug example và test IDs; UMP EEA thật, host app, iOS/AppLovin, cuộc gọi/rotation/kill giữa fullscreen và kiểm tra tuân thủ luật vẫn chưa chứng minh. Xem kết quả memory/jank cụ thể ở các hàng tương ứng; không suy rộng sang production |
| Lifecycle/policy independent review | Không phát hiện lỗi production-blocking đã xác minh trong phạm vi reviewer đọc; focused widget/route 174 tests và adapter/safety 233 tests pass | Đây là review một phần, không thay full audit native/heap; không coi absence of finding là proof không có bug |
| Consent/VIP independent review | Không phát hiện lỗi cụ thể trong consent/provider apply, offline behavior, VIP signed-code/trial security hoặc persistence; focused consent/VIP/API golden tests pass | Review source/test, không thay kiểm thử native trên ma trận thiết bị |
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
