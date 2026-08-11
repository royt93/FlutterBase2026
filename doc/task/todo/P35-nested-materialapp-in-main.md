# P35 — `MyApp` render `MaterialApp` lồng trong `GetMaterialApp`, theme xung đột

- **Priority:** P1 · **Severity:** HIGH · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** claude CLI + subagent đọc source (2 nguồn độc lập cùng chỉ ra)
- **Files:** `lib/main.dart:75-121` (outer `GetMaterialApp`), `lib/main.dart:149-170` (`MyApp`/`_MyAppState`, inner `MaterialApp`)

## Vấn đề
`runApp()` (dòng 75) dựng `GetMaterialApp` với `theme: ThemeData.light().copyWith(primaryColor: ColorConstants.appColor, ...)` (dòng 111-116) và `home: const MyApp()` (dòng ~90). `MyApp.build()` lại trả về 1 `MaterialApp` con (không phải `GetMaterialApp`) bọc `Scaffold(SplashScreen())`, với `theme` riêng dùng `primarySwatch: Colors.red` — 2 cây `MaterialApp` lồng nhau, theme trong xung đột/che khuất theme ngoài cho toàn bộ subtree bắt đầu từ `SplashScreen`. Đây cũng là nguồn gốc khả năng gây blink theme sai màu (đỏ thay vì `ColorConstants.appColor`) trong khoảnh khắc trước khi `Get.to`/`Get.off` chuyển sang route dùng `GetMaterialApp`'s `Navigator` thật.

## Bằng chứng
- `main.dart:75` — `runApp(... GetMaterialApp(...))`.
- `main.dart:111-116` — theme thật: `ColorConstants.appColor`.
- `main.dart:149-170` — `MyApp`/`_MyAppState.build()` trả `MaterialApp(theme: ThemeData(primarySwatch: Colors.red), home: Scaffold(body: SplashScreen()))`.

## Việc cần làm (đề xuất, chưa code)
- Bỏ `MaterialApp` lồng trong `MyApp` — trả trực tiếp `SplashScreen()` (hoặc `Scaffold(body: SplashScreen())` không bọc `MaterialApp`), để toàn app chỉ có 1 `GetMaterialApp` gốc duy nhất.
- Verify lại `Navigator`/theme hoạt động đúng sau khi bỏ lớp lồng (chạy full app, kiểm tra route push/pop, banner ad RouteAware vẫn hoạt động vì phụ thuộc đúng `Navigator` gốc).

## Acceptance criteria
- [ ] Chỉ còn 1 `MaterialApp`/`GetMaterialApp` trong toàn cây widget (`flutter analyze` + review lại `main.dart`).
- [ ] Theme hiển thị đúng `ColorConstants.appColor` ngay từ `SplashScreen`, không có màu đỏ nhấp nháy.
- [ ] Navigation/ad RouteAware (banner pause/resume) không regress sau khi sửa.
