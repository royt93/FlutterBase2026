# T241 — Flight Recorder: unmount khi đang visible để lại entry "visible" không đóng

- **Loại:** Bug
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** 🔲 todo

## Vấn đề (Why)

Phát hiện khi audit độc lập T236 (round code-review, 2026-10-02): `BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget` đều dùng chung pattern `_recordFlightRecorderVisibility` + `_lastFlightRecorderVisible` dedup, gọi qua `VisibilityDetector.onVisibilityChanged`. Khi widget unmount (pop route, route replacement, list row bị xoá khỏi `ListView`) trong lúc đang ở trạng thái visible:

- `VisibilityDetector` KHÔNG tự tổng hợp một callback `visibleFraction = 0` lúc `RenderObject` bị detach/dispose — nó chỉ bắn callback khi còn gắn trong cây render và có thay đổi thực tế.
- Callback trễ nào đó (nếu có) bị chặn bởi guard `if (mounted) ...` trong `onVisibilityChanged`.
- Kết quả: `AdFlightRecorder` giữ lại entry cuối cùng là `*Visible` không bao giờ có `*Hidden` khép lại — chuỗi bằng chứng export ra ngoài (`.adproof`) có một "phiên hiển thị" treo vô thời hạn về mặt dữ liệu, dù UI thực tế đã biến mất từ lâu.

Hành vi này có từ T231 (khi `BannerAdWidget`/`MrecAdWidget` được thêm `_recordFlightRecorderVisibility`), không phải lỗi mới của T236 — T236 chỉ khiến `NativeAdWidget` kế thừa đúng pattern (và đúng gap) này.

## Đề xuất giải pháp

Trong `dispose()` của cả 3 widget (`BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget`), nếu `_lastFlightRecorderVisible == true` lúc dispose:
1. Ghi một entry `*Hidden` cuối cùng TRƯỚC khi gọi `super.dispose()`, dùng toạ độ/kích thước cuối cùng đã biết (không cần `context.findRenderObject()` nữa vì render object sắp bị huỷ — có thể cache `Offset`/`Size` cuối cùng từ lần `_recordFlightRecorderVisibility` gần nhất, tương tự cách T236 thêm `_lastVisibilityInfo` cho Native).
2. Đặt `_lastFlightRecorderVisible = false` ngay sau đó để tránh double-close nếu có code path dispose gọi hai lần.

### Acceptance Criteria

- [ ] Unmount một Banner/MREC/Native đang hiển thị (pop route, hoặc `ListView` xoá item) với flight recorder bật → entry `*Hidden` cuối cùng được ghi, hash chain vẫn hợp lệ.
- [ ] Widget unmount khi CHƯA từng visible (`_lastFlightRecorderVisible == null` hoặc `false`) → không ghi entry thừa.
- [ ] Không đổi hành vi khi flight recorder tắt (default OFF) — vẫn early-return như hiện tại.
- [ ] Không tạo lớp trừu tượng mới; tái dùng đúng helper `_recordFlightRecorderVisibility`/field hiện có ở từng widget.
- [ ] `flutter analyze` sạch; test liên quan pass.

## Kế hoạch kiểm thử

- Widget test cho cả 3 widget: mount → trigger visible → pop route (hoặc remove khỏi `ListView`) → assert `*Hidden` entry cuối cùng tồn tại và `verifyFlightRecorderChain` vẫn `true`.
- Widget test: mount nhưng chưa từng visible → unmount ngay → assert KHÔNG có entry `*Hidden` thừa (mảng `entries` rỗng hoặc không chứa `*Hidden` không khớp `*Visible` nào).
- Integration/device: pop một màn hình có Banner/Native đang hiển thị, xuất `.adproof`, xác nhận chain đóng đúng.
