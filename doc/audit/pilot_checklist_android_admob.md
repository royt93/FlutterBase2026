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
| Wi‑Fi tắt/bật thật; UMP EEA accept / decline / Privacy Options | TECNO KJ7 | Test geography EEA; `evidence/round79_tecno/` |
| Consent đã lưu thì form không hiện lại | TECNO KJ7 | Gọi trực tiếp luồng UMP, không qua UI đầy đủ |

Chưa có bằng chứng: host app thật, ad unit production, consent trên thiết bị người dùng thật, native memory, FPS/presentation (T267 mở), iOS, AppLovin.

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
- [ ] Mất mạng thật (tắt Wi‑Fi): không request mới; mạng về thì tải lại. Example đã được kiểm trên TECNO.
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
- T267 (frame/presentation) chưa đạt: acceptance cần Pixel 7 Pro; kết quả S24U/TECNO chỉ là engine timing.
- iPhone thật (ATT + UMP + AdMob) và AppLovin chưa được kiểm tra.
- Bốn kết luận trên không thay thế review pháp lý/consent của publisher.
