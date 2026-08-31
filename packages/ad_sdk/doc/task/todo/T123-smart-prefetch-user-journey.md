# T123 — Idea: Smart prefetch theo hành trình người dùng

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** manager load APIs, route observer, ad slot/backoff, safety config

## Vấn đề

Preload hiện chủ yếu theo init/resume/reconnect, chưa biết 1 placement sắp được dùng. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Host khai báo lightweight signal (`levelStarted`, `screenEntered`, `expectedBreakIn`) + budget
- [ ] SDK học rolling time-to-show on-device để preload vừa đủ sớm
- [ ] Tự bỏ qua khi VIP/cap/offline/consent đóng
- [ ] Test: signal đến sớm/muộn khác nhau, xác nhận preload timing hợp lý, không giữ ad quá lâu
