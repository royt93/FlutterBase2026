# T106 — Enhancement: Bootstrap API 1 hàm gom ATT→UMP→initialize→splash

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_manager.dart`, `att_consent.dart`, `ump_consent.dart`, `ad_readiness_splash_controller.dart`, `doc/init.md`, example splash

## Vấn đề

Flow khuyến nghị hiện buộc host tự xâu chuỗi ATT, UMP, fallback consent, initialize và splash timeout. Example dài và dễ copy thiếu 1 bước dù SDK đã có đủ primitive. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Thêm `bootstrap(AdBootstrapOptions)` trả `AdBootstrapResult` chứa ATT/UMP/init/diagnostic outcome
- [ ] Giữ API thấp tầng và callback cũ tương thích (không breaking)
- [ ] Cập nhật example dùng API mới làm reference, giữ bản cũ minh hoạ song song nếu cần
- [ ] Test: bootstrap end-to-end với fake adapter, xác nhận đúng thứ tự ATT→UMP→init
