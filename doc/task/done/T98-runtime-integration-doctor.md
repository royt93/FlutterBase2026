# T98 — Flagship: Runtime integration doctor cho consuming app

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/debug/integration_self_check.dart`, `packages/ad_sdk/lib/src/debug/ad_debug_overlay.dart`, `packages/ad_sdk/README.md:73`

## Vì sao độc quyền
Phần lớn lỗi ads SDK thật xảy ra ở integration layer (thiếu navigator key, route observer, ATT/UMP config, SKAdNetwork/Info.plist, Android manifest, mediation/pod graph), không phải Dart API logic. Package đã có self-check/debug overlay — nâng cấp thành "doctor" chạy runtime hoặc trong integration test sẽ là khác biệt rất thực tế so với SDK khác.

## Việc cần làm (đề xuất, chưa code)
- [~] Mở rộng self-check thêm check mới — xem "Đã làm" cho scope thực tế đã làm khác đề xuất gốc.
- [x] Hiển thị kết quả doctor trong debug overlay, dạng pass/fail per check.

## Đã làm (2026-08-16)

Ghi chú path sai trong ticket: `lib/src/debug/integration_self_check.dart` và
`lib/src/debug/ad_debug_overlay.dart` không tồn tại — file thật là
`lib/src/core/integration_self_check.dart` và
`lib/src/widget/debug_ad_overlay.dart`.

**Scope quyết định KHÁC đề xuất gốc (tự quyết, có lý do rõ ràng — không âm
thầm nhận đã làm cái chưa làm):** đề xuất gốc muốn check SKAdNetwork/
Info.plist entries, Android manifest permissions/meta-data, pod graph version
— cả 3 đều KHÔNG đọc được từ Dart thuần lúc runtime:
- SKAdNetwork/Info.plist entries & Android manifest permissions/meta-data:
  cần code native (Swift/Kotlin) mới qua platform channel để đọc file bundle
  thật — không có sẵn hạ tầng này, viết mới là 1 khối lượng việc lớn hơn hẳn
  scope 1 ticket P2 "mở rộng self-check".
- Pod graph version: khái niệm THỜI ĐIỂM BUILD (CocoaPods dependency
  resolution) — không tồn tại representation nào ở runtime để kiểm tra; chỉ
  verify được qua `tool/check_pinning_wall.sh` (T85) chạy trên checkout, không
  phải trong app đang chạy.

Thay vào đó mở rộng self-check với 3 check MỚI thật sự đọc được từ Dart
runtime, tất cả read-only (không bao giờ trigger ad load thật/ATT prompt
thật):
- `lib/src/core/ad_route_observer.dart` — `AdScreenRouteLogger` thêm static
  counter `navigationEventsObserved` (tăng ở mọi `didPush`/`didPop`/
  `didRemove`/`didReplace`), reset trong `resetState()` sẵn có. 1 instance chỉ
  nhận được callback này nếu THẬT SỰ được thêm vào `navigatorObservers` của 1
  Navigator sống — nên số >0 là bằng chứng thật, không phải suy đoán.
- `lib/src/core/ad_manager.dart` — 3 method mới gọi trong
  `runIntegrationSelfCheck()`:
  - `_selfCheckNavigatorKey()` — fail nếu `_navigatorKey == null`; skipped
    (không phải fail) nếu đã set nhưng `currentContext == null` (chưa gắn vào
    tree sống — có thể chỉ do check chạy trước frame đầu).
  - `_selfCheckRouteObserver()` — pass nếu `navigationEventsObserved > 0`,
    ngược lại skipped (chưa chắc sai, có thể do chưa navigate lần nào).
  - `_selfCheckAtt()` — chỉ gọi `AppTrackingTransparency.trackingAuthorizationStatus`
    (đọc, KHÔNG gọi `requestTrackingAuthorization()` — method đó hiện prompt
    thật, 1 diagnostic thụ động không được phép tự ý bật). skipped trên
    non-iOS.
  - Test seam mới `debugClearNavigatorKey()` (`@visibleForTesting`) — cần cho
    test tự cô lập `_navigatorKey` giữa các test (AdManager singleton, không
    có cách reset nào khác).
- `lib/src/widget/debug_ad_overlay.dart` — `_DoctorSection` mới: nút "🩺 Run
  integration doctor" (KHÔNG tự chạy khi mở overlay — check load thật ads
  thật, tự ý chạy lúc mở panel sẽ tốn quota/cap safety layer mà dev không
  biết), hiện từng dòng pass/fail/skipped sau khi bấm.
- Test mở rộng: `test/integration_self_check_test.dart` — 5 test mới (fail
  khi chưa set navigator key, skipped khi set nhưng chưa gắn tree, skipped
  khi chưa có navigation event, pass sau khi có navigation event thật, ATT
  skipped trên host test non-iOS). Đã sửa test "all-pass path" cũ để set
  navigator key (nếu không sẽ tự fail vì check mới).
  Root-cause debug thật trong lúc viết: 1 test `testWidgets` ban đầu dùng
  `pumpWidget` + `pumpAndSettle` để tạo navigation event thật rồi chạy full
  self-check (bao gồm load ads thật) bị TREO VÔ HẠN — nghi vấn do
  `Completer.future.timeout(...)` bên trong `_selfCheckLoad` dùng `Timer`
  thật trong khi `testWidgets`' fake-clock binding không tự trôi nếu không
  `pump()` đúng khoảng thời gian; sửa bằng cách bỏ hẳn `testWidgets`/
  `pumpAndSettle`, gọi thẳng `AdScreenRouteLogger().didPush(...)` trong 1
  `test()` thường — cùng pattern hoạt động ổn định với mọi test khác trong
  file, tránh rủi ro fake-clock/real-Timer trộn lẫn.
- `flutter analyze`: No issues found! `flutter test`: 830/830 pass.
