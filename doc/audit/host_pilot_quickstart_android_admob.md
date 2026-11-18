# Host pilot — hướng dẫn một trang (Android + AdMob)

Dành cho team host chạy pilot trên **app của chính họ**. Checklist đầy đủ và bằng chứng nằm ở `pilot_checklist_android_admob.md`; file này chỉ nói việc cần làm. Bằng chứng hiện có chỉ từ example app với Google test ads, không thay thế pilot này.

## 1. Chốt bản SDK

- Dùng bản đã publish mà release owner duyệt. Ghi **version và `source: hosted`** từ `pubspec.lock` của host, không suy ra từ repo.
- Làm theo `doc/AD_PROMPT_FLUTTER.MD` của đúng version đang pin. Kotlin Gradle Plugin `>= 2.3.0`, `minSdk >= 24`.
- Dùng build riêng cho pilot (khác `applicationId` production) cho tới khi pilot xong.

## 2. Chạy theo thứ tự (mỗi bước ghi PASS / FAIL / NOT RUN)

1. **Test ads + test device:** mỗi format host dùng load → show → dismiss, không crash; reward chỉ cấp khi `earned=true`. (Checklist mục C)
2. **Consent (UMP):** với EEA `DebugGeography`, thử Consent, Do not consent và Privacy Options; ghi trạng thái UMP và `nonPersonalizedAds`. (Mục B)
3. **Nền → mở lại:** lần mở lại đầu tiên sau khởi động **cố ý không hiện App Open** (cold-start guard); lần sau mới hiện. App Open không chồng lên dialog, không hiện khi VIP/trial đang bật. (Mục C)
4. **Mạng:** tắt/bật Wi‑Fi và thử mạng di động; mất mạng thì không request mới, có mạng lại thì tải lại. (Mục C)
5. **Xóa dữ liệu:** `await AdManager().clearSdkData()` trên dữ liệu giả; key riêng của host còn nguyên. Bắt `TimeoutException` (30 giây): hiển thị **chưa xác nhận xóa**, không báo thành công. (Mục C2)
6. **Build release:** test ad ID của Google không nằm trong cấu hình release; ad unit ID, `app-ads.txt`, UMP message đúng app/publisher; R8/ProGuard và signing kiểm bằng bản release. (Mục A)

## 3. Ghi kết quả (mẫu điền)

| Mục | Kết quả | Thiết bị / Android | Ghi chú, link log |
|---|---|---|---|
| SDK version + source | | | |
| 1 Test ads | | | |
| 2 Consent | | | |
| 3 Nền → mở lại | | | |
| 4 Mạng | | | |
| 5 Xóa dữ liệu | | | |
| 6 Build release | | | |

Việc **không chạy được** ghi `NOT RUN` kèm lý do; không để trống rồi coi là đạt. Không đưa consent string, GAID, token hay dữ liệu người dùng thật vào log gửi lại.

## 4. Dừng ngay nếu

- Crash/ANR tăng rõ so với bản không có ad.
- Ad hiện khi VIP/trial đang hoạt động, hoặc request ad khi chưa có consent hợp lệ ở thị trường cần UMP.
- Cảnh báo policy hoặc invalid traffic từ AdMob; click nhầm do vị trí ad.
- Reward cấp khi `earned=false`.

Ngưỡng số người/số ngày do chủ sản phẩm chọn. Gặp lỗi: giữ log, **không** vá bằng cách tắt safety gate hoặc `bypassSafety`.

## 5. Chưa được chứng minh (đừng suy ra đã ổn)

Host app thật, ad unit production, consent trên thiết bị người dùng thật, iOS, AppLovin, FPS/bộ nhớ native, và đường `clearSdkData()` timeout với storage treo thật (chỉ kiểm bằng backend giả trong test của SDK). Nếu storage treo mãi, Flight Recorder dừng ghi cho tới khi app khởi động lại và retry xếp sau thao tác đang kẹt.
