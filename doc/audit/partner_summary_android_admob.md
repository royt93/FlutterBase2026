# Tóm tắt cho partner — `applovin_admob_sdk` 3.7.1 (Android + AdMob)

- **Ngày:** 2026-11-11
- **Dùng kèm:** `packages/ad_sdk/doc/AD_PROMPT_FLUTTER.MD` (hướng dẫn tích hợp) và `doc/audit/pilot_checklist_android_admob.md` (checklist pilot).
- **Tình trạng tài liệu này:** bản nháp để chủ sản phẩm duyệt. Chưa gửi cho ai.

## Kết luận ngắn

SDK **đủ cơ sở để chạy một closed pilot nhỏ** trên Android với AdMob, nếu app của bạn làm đúng checklist. Đây **chưa phải** xác nhận đưa lên production rộng.

## Cách lấy SDK

- Cài từ pub.dev: `applovin_admob_sdk` phiên bản **3.7.1**. Không dùng git/path dependency.
- 3.7.1 chỉ đổi tài liệu so với 3.7.0 (không đổi code hay API).
- Yêu cầu chính: Flutter ≥ 3.38.1, Dart ≥ 3.10, Kotlin Gradle Plugin ≥ 2.3.0, `minSdk` ≥ 24, `google_mobile_ads` 9.2.x.
- Dùng **test ad unit của Google** khi thử. SDK chặn request ở bản release nếu còn test ID, nên bản release phải dùng ad unit thật của chính bạn.

## Đã được kiểm tra gì

Toàn bộ chỉ chạy trên **app mẫu của SDK** với quảng cáo thử nghiệm, không phải app của bạn:

- Bộ test tự động của SDK: 2852 test, đều pass; analyzer không báo lỗi.
- Pixel 7 Pro: Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial và App Open đều hiển thị; Rewarded chỉ cấp thưởng khi callback báo đã xem xong.
- TECNO KJ7: form đồng ý UMP (vùng EEA thử nghiệm) hiện ra; chọn "Consent" và "Do not consent" đều được ghi nhận, và từ chối chuyển sang quảng cáo không cá nhân hoá.

## Chưa được kiểm tra, hoặc chỉ kiểm một phần

- **App của bạn:** chưa có app host nào được kiểm tra. Cấu hình AdMob, `app-ads.txt`, UMP message, ký bản release và R8 là việc của bạn.
- **Mất/có lại mạng thật** và **Privacy Options (đổi ý sau khi từ chối):** chỉ thử một lần, kết quả chỉ nằm trong log cục bộ. Privacy Options vượt thời hạn chờ 180 giây của SDK; lựa chọn đến muộn và SDK vẫn áp dụng lại. Hãy tự kiểm lại trên app của bạn.
- **Hiệu năng khung hình (T267):** chưa có kết luận. Chưa đo được khung hình thực sự hiển thị; số liệu có chỉ là thời gian xử lý trong Flutter.
- **Rò rỉ bộ nhớ native:** chưa chứng minh được là không rò rỉ.
- **iOS và AppLovin MAX:** không nằm trong phạm vi này, chưa kiểm.
- **Pháp lý/đồng ý:** SDK không thay thế trách nhiệm của publisher về UMP, chính sách quyền riêng tư và từng thị trường.

## Điều bạn cần quyết định

- **Trial 24 giờ:** mặc định ở bản release là bật. Nếu chưa được duyệt, đặt `FirstInstallVipGrace.disabled`.
- **Mã VIP khuyến mãi:** không phải giấy phép dùng một lần trên toàn hệ thống, vì không có backend. Không bán như giấy phép trả phí.

## Dừng pilot ngay nếu

- Crash/ANR tăng rõ so với bản không có quảng cáo.
- Quảng cáo hiện khi người dùng đang VIP/trial.
- Có request quảng cáo khi chưa có đồng ý hợp lệ ở nơi cần UMP.
- AdMob cảnh báo chính sách hoặc lưu lượng không hợp lệ; người dùng bấm nhầm do vị trí quảng cáo.

## Đường lùi

Có cách quay về version trước và tắt quảng cáo từ app/console. Lưu ý pub.dev không rút lại được bản đã publish.
