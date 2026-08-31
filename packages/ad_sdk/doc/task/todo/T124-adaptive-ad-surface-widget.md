# T124 — Idea: AdaptiveAdSurface — 1 widget tự chọn banner/MREC/native theo kích thước

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** 3 widget inline hiện có, 2 adapter/bridge, `MediaQuery`, visibility helper

## Vấn đề

AppLovin đã thích ứng width và AdMob có anchored adaptive sizing, nhưng host vẫn tự quyết banner/MREC/native và breakpoint. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] `AdaptiveAdSurface` tự chọn banner/MREC/native-template theo available width, orientation và policy host
- [ ] Debounce resize, giữ đúng instance ownership
- [ ] Không đổi format khi fullscreen đang bận
- [ ] Test: đổi orientation/width, xác nhận chọn đúng format, không leak instance cũ
