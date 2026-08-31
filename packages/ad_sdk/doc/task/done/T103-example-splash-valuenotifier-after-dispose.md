# T103 — Example splash ghi ValueNotifier đã dispose khi ad-load callback trễ

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (2026-08-31)
- **Files:** `example/lib/main.dart` (`_SplashScreenState._showAppOpen`, `_goHome`, `dispose`)

## Vấn đề

`_SplashScreenState.dispose()` dispose `_navigated` nhưng không đánh dấu điều hướng/vô hiệu hoá callback async trước đó. Callback load/dialog đã giao cho native trước dispose có thể gọi `_goHome()` (gán `_navigated.value = true` trước kiểm tra `mounted`) → "ValueNotifier was used after being disposed". Implementation riêng của example, khác `AdReadinessSplashController` đã fix ở round-26.

## Việc cần làm

- [x] Dùng bool lifecycle token thay vì ValueNotifier — root cause thật: `_navigated` chưa từng được listen ở đâu, chỉ dùng làm cờ, nên đổi hẳn `ValueNotifier<bool>` → `bool` loại bỏ toàn bộ lớp lỗi "dùng sau dispose" thay vì chỉ vá 1 điểm race.
- [x] `dispose()` set `_navigated = true` NGAY DÒNG ĐẦU (trước khi làm bất kỳ việc dọn dẹp nào khác) — callback trễ gọi `_goHome()` sau đó luôn thấy `_navigated == true` và return ngay, không chạm `Navigator`/`context`.
- [ ] Regression test tự động: KHÔNG viết được — `_SplashScreenState`/`_navigated` là private trong `example/lib/main.dart`, ví dụ khác trong repo (B5) cũng không có unit test harness cho phần này. Verify bằng `flutter analyze` sạch + lý luận: đổi sang `bool` là an toàn theo cấu trúc (không còn `dispose()` nào để "dùng sau" nữa), không phải một mitigation xác suất cần chứng minh bằng timing test.
