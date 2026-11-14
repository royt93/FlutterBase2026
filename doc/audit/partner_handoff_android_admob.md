# Gói bàn giao cho partner — `applovin_admob_sdk` 3.7.1 (Android + AdMob)

- **Ngày:** 2026-11-13
- **Tình trạng:** bản chuẩn bị sẵn để **chủ sản phẩm tự gửi**. Chưa gửi cho ai. Người gửi nên đọc lại lần cuối.
- **Phạm vi:** chỉ Android + AdMob. iOS và AppLovin MAX không nằm trong gói này.

## 1. Đầu mối duy nhất: `AD_PROMPT_FLUTTER.MD`

Partner chỉ cần **một file** để bắt đầu và làm đến hết: `packages/ad_sdk/doc/AD_PROMPT_FLUTTER.MD`. Mở mục **"Start here — numbered walkthrough"** ở đầu file: 12 giai đoạn từ thư mục trống đến báo cáo bàn giao, mỗi giai đoạn có việc cần làm, kết quả mong đợi và cách xử lý khi sai. File này cũng nằm trong gói pub.dev (`dart pub unpack applovin_admob_sdk:<version>`), nên bản partner nhận có thể đối chiếu với đúng version đã pin. Các tài liệu còn lại bên dưới là **bằng chứng và bối cảnh**, không phải hướng dẫn thao tác.

Thứ tự đọc:

| # | Tài liệu | Dùng để |
|---|---|---|
| 1 | `packages/ad_sdk/doc/AD_PROMPT_FLUTTER.MD` | **Đầu mối duy nhất.** Hướng dẫn từng bước đúng phiên bản 3.7.1; làm theo "Start here" |
| 2 | `doc/audit/partner_summary_android_admob.md` | Kết luận ngắn, đã kiểm gì, chưa kiểm gì, việc partner phải tự quyết |
| 3 | `doc/audit/pilot_checklist_android_admob.md` | Checklist trước và trong closed pilot, tiêu chí dừng ngay, bảng bằng chứng |
| 4 | `doc/audit/audit_round79_full_sdk.md` | Báo cáo kiểm tra đầy đủ (chi tiết kỹ thuật, tiếng Việt) |

## 2. Kết luận (nguyên văn từ bản tóm tắt)

SDK đủ cơ sở để chạy một **closed pilot nhỏ** trên Android với AdMob, nếu app của partner làm đúng checklist. Đây **chưa phải** xác nhận đưa lên production rộng.

## 3. Đã được kiểm tra, bằng chứng nằm ở đâu

Tất cả chạy trên **app mẫu của SDK**, quảng cáo thử nghiệm của Google, không phải app của partner.

| Nội dung | Thiết bị | Thư mục bằng chứng (trong repo) |
|---|---|---|
| Test tự động SDK: 2852 test pass, analyzer sạch | máy phát triển | kết quả terminal của lượt kiểm, không lưu file |
| Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial, App Open hiển thị | Pixel 7 Pro | `doc/audit/evidence/round79_pixel/` |
| Form UMP (vùng EEA thử nghiệm), Consent / Do not consent | TECNO KJ7 | `doc/audit/evidence/round79_tecno/` |
| Cùng các định dạng quảng cáo, CCPA, self-check, VIP, Wi-Fi tắt/bật thật | TECNO KJ7 | `doc/audit/evidence/round79_tecno_manual/` (`screens*`) |
| Khóa VIP, danh sách thu hồi (CRL), đồng hồ lệch, offline | TECNO KJ7, Samsung S24 Ultra | `.../round79_tecno_manual/screens5` đến `screens13` |
| Bản **release** của app mẫu | TECNO KJ7 | `.../round79_tecno_manual/t276/` |
| Privacy Options trong thời hạn 180 giây | TECNO KJ7 | `.../round79_tecno_manual/t278/` |
| Provider CRL của app mẫu chạy thật | TECNO KJ7 | `.../round79_tecno_manual/t273/` |

Mỗi thư mục có `README.txt` hoặc `NOTES.txt` nói rõ **đã thấy gì và không thấy gì**, và `SHA256SUMS.txt` (đường dẫn tương đối) để kiểm tra file không bị sửa.

## 4. Chưa kiểm tra, hoặc chỉ kiểm một phần (phải đọc)

- **App của partner:** chưa có host app nào được kiểm tra. Cấu hình AdMob, `app-ads.txt`, UMP message, ký bản release và R8 là việc của partner.
- **Bản release:** chỉ kiểm bản release của app mẫu với test ad unit (SDK chặn request, đúng thiết kế). Chưa chứng minh quảng cáo thật hiển thị ở release.
- **Privacy Options:** các nút form được bấm bằng adb, không phải người thật bấm.
- **VIP/CRL:** dùng khóa tạm và server tạm trong mạng nội bộ; chưa thử qua CA công khai, mạng di động, hay mã ký bằng khóa thật. Đoạn ghim chứng chỉ HTTPS là mã kiểm thử của chúng tôi, không phải tính năng SDK.
- **Hiệu năng khung hình (T267):** **không đo được** frame hiển thị của Flutter SurfaceView bằng các cách đã thử (Macrobenchmark, Perfetto/SurfaceFlinger, JankData) trên Pixel 7 Pro, TECNO và S24 Ultra; không có số FPS hiển thị. Số liệu duy nhất là thời gian xử lý của engine Flutter, không phải frame được hiển thị. Đừng dùng nó để khẳng định "60 fps".
- **Rò rỉ bộ nhớ native:** chưa chứng minh.
- **Pháp lý/đồng ý:** SDK không thay thế trách nhiệm của publisher về UMP, chính sách quyền riêng tư và từng thị trường.
- **Số lần chạy ít:** nhiều kiểm tra chỉ chạy một lần trên một máy; một lần pass không chứng minh ổn định.

## 5. Điều partner cần quyết định trước khi chạy pilot

- **Trial 24 giờ:** mặc định ở bản release là bật; nếu chưa được duyệt, đặt `FirstInstallVipGrace.disabled`.
- **Mã VIP khuyến mãi:** không phải giấy phép dùng một lần trên toàn hệ thống (không có backend); không bán như giấy phép trả phí.
- **Nối danh sách thu hồi (CRL):** nếu dùng mã VIP có thu hồi, partner phải tự nối `VipRevocationProvider`; example có `DemoCrlProvider` làm mẫu (`--dart-define=VIP_CRL_URL`).

## 6. Dừng pilot ngay nếu

- Crash/ANR tăng rõ so với bản không có quảng cáo.
- Quảng cáo hiện khi người dùng đang VIP/trial.
- Có request quảng cáo khi chưa có đồng ý hợp lệ ở nơi cần UMP.
- AdMob cảnh báo chính sách hoặc lưu lượng không hợp lệ; người dùng bấm nhầm do vị trí quảng cáo.

## 7. Cách lấy SDK

- Cài từ pub.dev: `applovin_admob_sdk` phiên bản **3.7.1**. Không dùng git/path dependency.
- Yêu cầu: Flutter ≥ 3.38.1, Dart ≥ 3.10, Kotlin Gradle Plugin ≥ 2.3.0, `minSdk` ≥ 24, `google_mobile_ads` 9.2.x.
- Dùng test ad unit của Google khi thử; bản release phải dùng ad unit thật của chính partner.

## 8. Cách người nhận kiểm lại bằng chứng

- Repo công khai: `github.com/royt93/FlutterBase2026`, nhánh `main`.
- Trong từng thư mục bằng chứng: `shasum -a 256 -c SHA256SUMS.txt` (chạy trong thư mục chứa file đó).
- Tổng dung lượng bằng chứng khoảng 70 MB (ảnh chụp màn hình và log lọc); **không nên đính kèm toàn bộ** — gửi link tới repo và chỉ các thư mục ở mục 3.

## 9. Việc người gửi (chủ sản phẩm) phải tự làm

- Đọc lại mục 4 và đảm bảo người nhận hiểu các giới hạn.
- Quyết định kênh gửi và có đính kèm file hay chỉ link.
- Không gửi kèm khóa riêng, ad unit production hay thông tin nội bộ; trong bằng chứng đã che địa chỉ IP mạng nội bộ và không có khóa VIP.
