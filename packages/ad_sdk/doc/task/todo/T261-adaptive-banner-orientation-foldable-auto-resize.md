# T261 — Adaptive Banner Tự Động Co Giãn Kích Thước Khi Xoay Màn Hình Hoặc Thiết Bị Gập

- **Loại:** Enhancement / UX
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Quảng cáo Adaptive Banner của Google AdMob phụ thuộc vào chiều rộng màn hình (`AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)`):
- Hiện tại, kích thước banner được tính toán cố định một lần khi widget mount (`initState`).
- Khi người dùng xoay điện thoại từ dọc sang ngang (Portrait sang Landscape), hoặc trên các thiết bị gập (Galaxy Z Fold, Pixel Fold) khi mở ra/gập lại: chiều rộng màn hình thay đổi đột ngột từ 400px lên 800px+.
- Banner cũ vẫn giữ kích thước cũ, tạo ra khoảng trống đen xấu xí hai bên hoặc bị tràn viền (overflow error), làm giảm tỷ lệ click và trải nghiệm thẩm mỹ.

## Đề xuất giải pháp

1. Trong `BannerAdWidget`, lắng nghe thay đổi kích thước thông qua `OrientationBuilder` hoặc `MediaQuery.sizeOf(context).width`.
2. Áp dụng cơ chế **Debounce (300ms)** khi xoay màn hình để tránh tải lại quảng cáo liên tục trong lúc animation xoay đang chạy.
3. Khi chiều rộng thay đổi vượt ngưỡng 20px so với kích thước banner hiện tại, tự động hủy banner cũ và nạp banner adaptive mới với kích thước khớp hoàn hảo với chiều rộng mới.

## Acceptance Criteria

- [ ] Banner tự động tính lại kích thước và hiển thị vừa vặn khi xoay ngang/dọc.
- [ ] Có debounce 300ms chống giật lag khi xoay màn hình liên tục.
- [ ] Không rò rỉ banner instance cũ khi tải lại kích thước mới.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Widget test:** Bọc `BannerAdWidget` trong `MediaQuery`, thay đổi `size.width` từ 400 lên 800 và xác nhận banner được tái tạo với size mới.
- **Interruption test:** Xoay màn hình nhiều lần liên tiếp, kiểm tra không bị lỗi layout overflow.
- **Frame rate/Jank test:** Đo animation xoay màn hình giữ vững 60fps trên thiết bị thật.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T261 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/banner_ad_widget.dart, lib/src/adapters/admob_adapter.dart.
2. Viết test trước để kiểm tra hành vi xoay màn hình (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
