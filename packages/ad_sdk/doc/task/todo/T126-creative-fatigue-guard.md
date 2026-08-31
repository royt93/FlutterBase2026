# T126 — Idea: Creative fatigue guard on-device

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `AdRevenueEvent.networkName`, safety config, event log, adapter callbacks/metadata

## Vấn đề

Cap hiện đếm impression/click theo thời gian/placement nhưng không nhận biết 1 network/creative lặp quá dày gây UX xấu và CTR bất thường. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Hash identifier không đảo ngược, lưu rolling exposure local
- [ ] Khi có đủ metadata: cooldown creative/network lặp; khi thiếu metadata: fail-open về cap hiện hữu
- [ ] KHÔNG can thiệp click hay nội dung creative
- [ ] Test: creative/network lặp quá ngưỡng → cooldown đúng; thiếu metadata → không chặn gì thêm
