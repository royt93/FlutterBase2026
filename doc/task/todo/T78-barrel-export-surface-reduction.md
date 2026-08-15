# T78 — Thu hẹp barrel export, giảm lộ low-level/testing surface

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/applovin_admob_sdk.dart`

## Vấn đề (Why)
Barrel export hiện lộ adapter, event bus, slot/backoff/log — nhiều phần chỉ nên dùng nội bộ/test, không phải public API ổn định cho consumer.

## Đề xuất
Rà soát từng export, giữ lại đúng public API cần thiết, ẩn phần internal (có thể qua `src/` không export hoặc đánh dấu `@internal`).

## Acceptance criteria
- [ ] Danh sách export mới không còn class/hàm chỉ dùng cho test nội bộ.
- [ ] `flutter analyze` sạch, example app vẫn build được với export mới.
