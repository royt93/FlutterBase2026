# T111 — Enhancement: RemoteAdSafetyProvider thiếu đường re-fetch định kỳ

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/config/remote_ad_safety_provider.dart`, `lib/src/core/ad_manager.dart:2156-2168`

## Vấn đề

`fetchSafetyParamOverrides()` chỉ được gọi 1 lần bên trong `initialize()`. Muốn áp giá trị remote mới, host phải `destroy()`+`initialize()` lại toàn bộ SDK — nặng hơn nhiều so với `VipRevocationProvider` (T95) vốn có `refreshRevocationList()` gọi được bất cứ lúc nào không cần re-init.

## Việc cần làm

- [ ] Thêm `AdManager().refreshRemoteSafetyParams()` public, mirror đúng pattern `refreshRevocationList` (fail-open, giữ giá trị cũ nếu lỗi)
- [ ] Test: refresh thành công áp giá trị mới; refresh lỗi giữ nguyên giá trị cũ, không throw
