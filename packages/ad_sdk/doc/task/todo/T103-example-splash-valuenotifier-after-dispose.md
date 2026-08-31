# T103 — Example splash ghi ValueNotifier đã dispose khi ad-load callback trễ

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `example/lib/main.dart` (`_SplashScreenState._showAppOpen`, `_goHome`, `dispose`)

## Vấn đề

`_SplashScreenState.dispose()` dispose `_navigated` nhưng không đánh dấu điều hướng/vô hiệu hoá callback async trước đó. Callback load/dialog đã giao cho native trước dispose có thể gọi `_goHome()` (gán `_navigated.value = true` trước kiểm tra `mounted`) → "ValueNotifier was used after being disposed". Implementation riêng của example, khác `AdReadinessSplashController` đã fix ở round-26.

## Việc cần làm

- [ ] Dùng bool lifecycle token hoặc set terminal state TRƯỚC dispose
- [ ] Kiểm tra generation/mounted trước mọi write
- [ ] Regression test: callback load/dismiss trễ sau dispose
