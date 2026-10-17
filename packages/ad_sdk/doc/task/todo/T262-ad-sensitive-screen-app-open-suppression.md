# T262 — Chặn App Open Ads Trên Các Màn Hình Nhạy Cảm (Thanh Toán, Đăng Nhập, Camera)

- **Loại:** Enhancement / UX & Policy
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

App Open Ad tự động hiển thị khi người dùng chuyển từ ứng dụng khác quay lại (app resume):
- Mặc dù SDK đã có cơ chế `isDialogOnTop` và `isCustomOverlayOnScreen` để tránh chèn ad lên popup, nhưng trên các màn hình đặc thù có tính chất nhạy cảm cao:
  - Màn hình thanh toán (VNPAY, Momo, Stripe, IAP checkout).
  - Màn hình quét QR / Camera đang hoạt động.
  - Màn hình nhập mã OTP / mật khẩu ngân hàng.
- Khi người dùng chuyển sang app ngân hàng để lấy mã OTP rồi quay lại, App Open Ad bất ngờ nhảy ra che khuất màn hình. Điều này vừa gây ức chế tột độ, vừa có nguy cơ vi phạm chính sách của Google về việc quảng cáo gây gián đoạn luồng tác vụ quan trọng của người dùng.

## Đề xuất giải pháp

1. Tạo một mixin công khai: `AdSensitiveScreen` (hoặc `AdSensitiveRouteMixin`).
2. Trong `AdScreenRouteLogger` / `AdManager`, khi route hiện tại implement `AdSensitiveScreen`, cờ `isSensitiveScreenActive` tự động chuyển sang `true`.
3. Hàm `showAppOpenAdOnResume` tự động kiểm tra cờ này và bỏ qua hiển thị quảng cáo App Open, ghi log an toàn: `⏭️ App Open skipped — active route is marked as sensitive`.

## Acceptance Criteria

- [ ] Các màn hình gắn `AdSensitiveScreen` được bảo vệ 100%, không bao giờ xuất hiện App Open Ad khi resume app.
- [ ] Khi chuyển sang màn hình thông thường khác, cơ chế App Open tự động kích hoạt lại bình thường.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra logic nhận diện route nhạy cảm trong `AdScreenRouteLogger`.
- **Widget test:** Tạo kịch bản resume app khi đang đứng ở màn hình nhạy cảm và màn hình bình thường, assert trạng thái hiển thị của App Open.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T262 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/ad_screen_route_logger.dart, lib/src/core/ad_manager.dart.
2. Viết test trước để kiểm tra chặn App Open trên màn nhạy cảm (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
