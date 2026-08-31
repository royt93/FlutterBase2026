# T125 — Idea: Offline incident recorder + replayable support bundle

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** 🔲 todo
- **Files:** event log, diagnostics, safety snapshots, consent transitions, connectivity events, compliance signing

## Vấn đề

Diagnostics/report là snapshot; race "không hiện ad" thường cần chuỗi trạng thái trước đó và khó tái tạo trên máy publisher. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Ring buffer có giới hạn lưu state-transition timeline, config fingerprint đã redact và clock deltas
- [ ] Export bundle ký (Ed25519, tái dùng hạ tầng compliance-signing)
- [ ] Tool CLI replay state machine từ bundle, hoàn toàn local
- [ ] Test: replay từ bundle cho ra đúng chuỗi trạng thái đã ghi
