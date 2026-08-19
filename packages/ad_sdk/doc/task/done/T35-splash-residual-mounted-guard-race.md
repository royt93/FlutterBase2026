# T35 — Splash: cửa sổ race còn sót sau T29 (mounted guard tầng ngoài)

- **REQ:** 3 (vòng đời) — liên quan REQ 6 (consent phải chạy trước impression)
- **Priority:** P2 · **Severity:** LOW (cửa sổ hẹp hơn nhiều so với T29 gốc) · **Status:** ✅ done (2026-07-13)
- **Files:** `lib/mckimquyen/widget/splash/splash_screen.dart` (dòng ~160)

## Vấn đề (Why)
T29 đã bỏ guard giữa ATT→UMP→`initialize()` (đúng ý đồ fix ban đầu), nhưng vẫn còn 1 `mounted` check ở tầng ngoài cùng bọc cả block init. Nếu hard-cap timer (8s) bắn đúng lúc widget vừa unmount trước khi block này kịp chạy, cùng loại lỗi gốc (init/consent bị skip, app-open có thể fire sai thứ tự) vẫn có thể xảy ra — chỉ ở xác suất/cửa sổ thời gian nhỏ hơn nhiều so với trước T29.

## Giải pháp đề xuất
Xem lại có cần tách riêng "phần phải chạy dù widget đã unmount" (init SDK, không phụ thuộc UI) ra khỏi phần chỉ chạy khi còn mounted (navigate, show dialog) — dùng 2 guard riêng thay vì 1 guard chung bọc cả khối.

## Acceptance criteria
- [ ] Có test mô phỏng widget unmount ngay trước khi block init chạy, assert `initialize()`/consent flow vẫn hoàn tất đúng thứ tự (không bị skip).

## Test
Test mới trong `test/` (host) hoặc widget test cho `SplashScreen`: force unmount tại thời điểm sát ranh giới, assert không có async gap nào khiến consent/init bị bỏ qua.

## Kết quả
Tách guard `mounted` cục bộ chỉ quanh phần UI-only (`_containerColorNotifier.value = Colors.transparent` + log) trong callback `DurationUtils.delay(300, ...)`, thay vì early-return chặn toàn bộ khối. Nhánh ATT→UMP→`initialize()` phía dưới giữ nguyên 100%, giờ luôn chạy dù widget đã unmount — khớp đúng ý đồ T29. `flutter analyze` sạch ở repo root.

## Giới hạn đã biết
Không thêm test tự động (race timing phụ thuộc native ATT/UMP + thời gian thực, khó mô phỏng đáng tin cậy) — verify bằng đọc lại luồng đã tách đúng 2 nhánh + chạy thử splash trên simulator xác nhận animation/init vẫn hoạt động bình thường. Cửa sổ race lý thuyết vẫn có thể tồn tại ở lớp sâu hơn (native plugin), nằm ngoài phạm vi Dart code này.
