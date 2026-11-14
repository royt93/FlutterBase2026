# Checklist closed pilot — Android + AdMob (host app)

- **Ngày:** 2026-11-10
- **Áp dụng cho:** `applovin_admob_sdk` 3.7.1 (docs-only so với 3.7.0, đã publish trên pub.dev).
- **Thay thế:** mục 7 của `audit_round78_android_admob.md` (ghi pub.dev 3.6.8 và 3.7.0 draft, đã lỗi thời).
- **Phạm vi:** Android + AdMob. iOS và AppLovin MAX **không** nằm trong checklist này.
- **Trạng thái:** chưa có host app nào được kiểm tra; không có ad unit production nào được dùng. Checklist là điều kiện cần trước khi chạy pilot, **không** phải kết quả pilot.

## Giới hạn của bằng chứng hiện có (đọc trước)

Round 79 chỉ kiểm tra **example app** với Google test ads:

| Đã có bằng chứng | Thiết bị | Ghi chú |
|---|---|---|
| Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial, App Open hiển thị | Pixel 7 Pro | Test ads; ảnh + log trong `evidence/round79_pixel/` |
| UMP EEA: form hiện, Consent và Do not consent đều ghi trạng thái và cờ NPA đúng | TECNO KJ7 | Test geography EEA; ảnh + 2 log trong `evidence/round79_tecno/` |
| Wi‑Fi tắt/bật thật, SDK nối lại mạng | TECNO KJ7 | Offline: không request mới (`no network`, `_initMrec offline`); bật lại: `network back online -> refilling ad slots` và MREC tải lại ~4 giây. Một lần chạy, chỉ Wi‑Fi (không thử mạng di động/captive portal); ảnh + log trong `evidence/round79_tecno_manual/screens7/` |
| Quảng cáo trong vòng đời VIP: xem rewarded -> VIP 3 ngày, ad bị chặn khi VIP, gỡ VIP thì ad lại tải | TECNO KJ7 | Test ads, log liên tục; `evidence/round79_tecno_manual/screens4/` |
| Adaptive surface nhánh MREC (>=600pt) | TECNO KJ7 | Chạy bằng `wm density 240` (giả lập, đã khôi phục), không phải màn rộng thật; `screens6/` |
| Key VIP ký (AVP1 demo, AVP2: hết hạn/sai bundle/đúng bundle/dùng lại/không ràng bundle) và CRL thu hồi | TECNO KJ7 + S24U | Dùng cặp khóa tạm và gói tạm (đã gỡ), không phải key của owner; CRL chỉ được nạp từ provider giả lập trong example, chưa qua mạng thật; `screens5/`, `screens8/`, `screens9/` |
| Privacy Options đổi consent sau khi đã từ chối | TECNO KJ7 | Lần 2 (adb bấm nút, không phải người): từ chối -> Privacy Options -> Consent hoàn tất trong ~19 giây, `nonPersonalizedAds` true -> false, không timeout. Lần 1 không ai bấm: timeout 180 giây rồi nhả chặn sau 15 phút. Một máy, một lần chạy thành công; `evidence/round79_tecno_manual/t278/` |
| Consent đã lưu thì form không hiện lại | TECNO KJ7 | Gọi trực tiếp luồng UMP, không qua UI đầy đủ |

Chưa có bằng chứng: host app thật, ad unit production, consent trên thiết bị người dùng thật, native memory, FPS/presentation (T267 đóng: không đo được bằng các cách đã thử), iOS, AppLovin. Chưa thử thêm: CRL qua CA công khai thật/mạng di động, phản hồi chậm hoặc cụt, đổi đồng hồ khi app đang chạy, key AVP2 ký bằng khóa thật của owner. (CRL qua HTTPS với CA tạm ghim chứng chỉ trên TECNO: chứng chỉ giả mạo bị từ chối, SDK giữ CRL cũ, xem `screens13/`. CRL tải qua HTTP trong mạng LAN từ server tạm đã thử trên S24U: áp dụng được, cập nhật được, và lỗi mạng thì SDK giữ CRL cũ; xem `screens12/`.) (Đã thử trên S24U, đạt: CRL còn hiệu lực sau khi khởi động lại app, redeem bị từ chối khi offline, VIP vẫn chặn quảng cáo khi offline, đồng hồ lệch -1 ngày/+2 ngày, xem `screens11/`.) (CRL cũ bị phát lại và CRL ký sai khóa đã được thử trên S24U, bị từ chối đúng, xem `screens10/`.)

## A. Trước khi cài bản pilot

- [ ] Dependency trỏ tới bản **đã publish** `applovin_admob_sdk 3.7.1` (pub.dev), không dùng git/path dependency chưa qua quy trình release.
- [ ] Làm theo `doc/AD_PROMPT_FLUTTER.MD` của đúng version đang pin (không copy cấu hình từ bản cũ).
- [ ] Kotlin Gradle Plugin `>= 2.3.0` (cần cho `google_mobile_ads 9.2.x`); `kotlinOptions { jvmTarget }` đã chuyển sang `kotlin { compilerOptions { ... } }`.
- [ ] `minSdk >= 24`; AdMob `APPLICATION_ID` trong manifest đúng app/publisher.
- [ ] **Test ad unit IDs của Google không nằm trong cấu hình release** (SDK sẽ chặn request ở release; vẫn phải kiểm tra bằng build release thật).
- [ ] Ad unit ID, `app-ads.txt` và UMP message thuộc đúng app/publisher; do owner xác nhận, SDK không tự kiểm được.
- [ ] Quyết định có bật trial 24h hay không: mặc định release là `FirstInstallVipGrace.auto`; nếu chưa được duyệt, đặt `FirstInstallVipGrace.disabled`.
- [ ] R8/ProGuard và signing do host kiểm tra bằng bản release.

## B. Consent (UMP)

- [ ] UMP là consent owner duy nhất; chạy mỗi lần mở app trước khi request ad.
- [ ] Có mục **Privacy Options** dễ tìm khi UMP yêu cầu (example đã có mẫu).
- [ ] Thử form EEA bằng test device + `DebugGeography` trên một thiết bị: Consent và Do not consent đều cho gate/ad hoạt động đúng; đổi ý qua Privacy Options.
- [ ] Ghi nhận: `canRequestAds=true` sau khi từ chối nghĩa là ad **không cá nhân hoá** (`nonPersonalizedAds=true`), không phải không có ad.
- [ ] Chính sách quyền riêng tư mở được từ app. Trách nhiệm pháp lý theo từng thị trường thuộc publisher, không thuộc SDK.

## C. Hành vi quảng cáo (dùng test ads / test device trước)

- [ ] Mỗi format host dùng: load → show → dismiss → không crash. Với reward: chỉ cấp khi callback `earned=true`.
- [ ] Giữ safety gate mặc định; `bypassSafety` chỉ cho App Open ở splash như tài liệu.
- [ ] Mất mạng thật (tắt Wi‑Fi): không request mới; mạng về thì tải lại. Example đã được thử một lần trên TECNO (log trong repo, xem bảng trên); host phải tự kiểm lại trên app và thiết bị của mình, kể cả mạng di động.
- [ ] Đưa app xuống nền rồi mở lại: App Open không chồng lên dialog; không hiện ad khi VIP/trial đang hoạt động.
- [ ] Banner/MREC trong `IndexedStack` dùng `active:` hoặc `Visibility(maintainState: true)` (xem README).

## D. Tiêu chí dừng ngay (no‑go)

Dừng pilot nếu gặp bất kỳ điều nào:

- Crash/ANR tăng rõ so với bản không có ad.
- Ad hiện khi VIP/trial đang hoạt động.
- Ad request khi chưa có consent hợp lệ ở thị trường cần UMP.
- Cảnh báo policy hoặc invalid traffic từ AdMob; click nhầm do vị trí đặt ad.
- Reward được cấp khi `earned=false`.

Ngưỡng cụ thể (số người, số ngày) do chủ sản phẩm chọn; đây không phải tiêu chuẩn của Google.

## E. Theo dõi trong pilot

- Tỉ lệ fill, lỗi tải, impression, doanh thu; crash/ANR; rút consent qua Privacy Options.
- Chỉ thu telemetry tối thiểu; không log GAID, ad unit hoặc consent string thô ngoài quy trình QA được duyệt.
- Cohort nhỏ, vài ngày. Có đường lùi: pin về version trước và tắt ad serving từ host/console (pub.dev không rút được bản đã publish).

## F. Giới hạn đã được chủ sản phẩm chấp nhận (không phải lỗi)

- Mã VIP khuyến mãi không phải giấy phép single-use toàn cầu; kích hoạt cần mạng, sau đó dùng offline.
- Trial Android chỉ chống cài lại theo kiểu best-effort (qua Auto Backup); xoá dữ liệu entitlement có thể cấp lại trial.
- Khôi phục backup Android có thể giữ dấu "đã dùng mã" nhưng mất grant VIP.

## G. Khoảng trống còn mở

- Pilot trên host app thật chưa chạy.
- T267 (frame/presentation) đã đóng ở mức "không đo được" (Macrobenchmark, Perfetto/SurfaceFlinger và JankData đều không cho frame hiển thị của Flutter SurfaceView trên Pixel 7 Pro, TECNO, S24U): không có số FPS hiển thị, chỉ có thời gian engine. T257 (60 fps toàn app) vẫn chưa đạt.
- iPhone thật (ATT + UMP + AdMob) và AppLovin chưa được kiểm tra.
- Bốn kết luận trên không thay thế review pháp lý/consent của publisher.
