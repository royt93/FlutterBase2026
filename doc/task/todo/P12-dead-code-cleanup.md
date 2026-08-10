# P12 — Dọn dead code (0 caller, đã grep xác nhận toàn `lib/`)

- **Priority:** P3 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source (grep xác nhận từng item)
- **Files:** nhiều file (xem danh sách dưới)

## Vấn đề
Các item dưới đây **không có caller nào** trong toàn bộ `lib/` (đã grep xác nhận, không phải suy đoán). Giữ lại chỉ tăng diện tích cần đọc/maintain, không có giá trị runtime.

## Danh sách dead code
- `MainScreen` (`lib/mckimquyen/widget/main/main_screen.dart`) — chỉ được tạo với `isShowMenu: false` cứng (`splash_screen.dart:638`), biến thể `kDebugMode` đã comment out (`splash_screen.dart:639`) → nút "Ad demo"/"Wifi stressor" và cả `AppBar` (toolbarHeight: 0, vô hình) không bao giờ hiện ra cho user thật.
- `showAlertDialogWidget`, `showAlertDialog` (`lib/mckimquyen/core/base_stateful_state.dart:30-207`) — 0 caller.
- `AppLoading` (`lib/mckimquyen/core/base_controller.dart:5-13`) — định nghĩa, không bao giờ instantiate.
- `HeroConstants`, `Constants` (`lib/mckimquyen/common/const/hero_constants.dart`, `constants.dart`) — 0 import.
- `ExitApp.handlePop` (`lib/mckimquyen/util/exit_app.dart`) — chưa wire vào `PopScope`/`WillPopScope` nào, flow "bấm back 2 lần để thoát" không hoạt động.
- Trong `UIUtils`: `getAppBar`, `getOutlineButton`, `getStyleText`, `getText`, `getCustomFontTextStyle`, `getCustomGradient`, `getCircularProgressIndicator`, `buildHorizontalDivider`, `buildVerticalDivider`, `showBottomSheet`, `showDialogSuccess`, `showErrorDialog`, `getImageBase64`, `sleep`, `showBottomSheetNotification` (permission request cho placeholder text "Notification settings removed to reduce APK size").
- Trong `UrlLauncherUtils`: `moreApp`, `launchPolicy` (trỏ URL privacy policy **cũ, khác** `AdKey.privacyPolicyUrl` — nếu ai wire lại nhầm sẽ ship link sai), `launchGroupTester`, `rateApp`, `rateAppInApp`.
- `ValidateUtils`, `DateTextFormatter`, `TimeUtils`, `ScaffoldGradientBackground`, `GridScreen`/`GridPainter`, `ext/router.dart#backScreen()`.

## Việc cần làm (đề xuất, chưa code)
- Xoá từng item sau khi double-check lại bằng `grep` ngay trước khi xoá (code có thể đổi giữa lúc audit và lúc thực thi).
- Với `MainScreen`: quyết định xoá hẳn (route Splash → thẳng `WiFiStressorApp`) hoặc giữ lại làm debug menu thật (gate bằng long-press/build-flavor) — xem thêm P-tương ứng nếu muốn giữ.
- Với `ExitApp.handlePop`: quyết định wire vào `WiFiStressorApp` root hoặc xoá hẳn — không để dở dang.

## Acceptance criteria
- [ ] Từng item được xoá hoặc wire lại có chủ đích (ghi rõ quyết định), không còn code "lửng lơ".
- [ ] `flutter analyze` sạch sau khi xoá.
