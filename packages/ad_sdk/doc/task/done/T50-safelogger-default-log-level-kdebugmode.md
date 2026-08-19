# T50 — `SafeLogger` default log level luôn verbose, lộ GAID ở release

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N1
- **Priority:** P2 (Medium) · **Status:** ✅ done (2026-07-20)
- **Files:** `packages/ad_sdk/lib/src/util/safe_logger.dart` (+ test tương ứng)

## Vấn đề (Why)
Host không tự gọi `AdManager.setLogLevel()` thì `SafeLogger` mặc định verbose kể cả ở release build — log ra GAID và các chi tiết debug khác vào production log.

## Đề xuất
Default log level theo `kDebugMode`: verbose khi debug, warning-trở-lên khi release.

## Acceptance criteria
- [x] Default log level đổi theo `kDebugMode`, không còn hard-code verbose.
- [x] Test xác nhận default đúng ở cả 2 mode.
- [x] `flutter test`/`flutter analyze` pass, không regression.

## Đã verify (2026-07-20)
Sửa `safe_logger.dart`, bump `pubspec.yaml` 1.2.1→1.2.2, thêm mục CHANGELOG. `flutter test` (packages/ad_sdk): 649/649 pass. Xem `doc/audit/audit_claude.md` round 9.
