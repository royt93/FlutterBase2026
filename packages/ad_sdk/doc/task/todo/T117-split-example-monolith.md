# T117 — Tech debt: Chia example/lib/main.dart theo từng demo

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `example/lib/main.dart`, example tests/integration tests

## Vấn đề

`example/lib/main.dart` dài khoảng 2700 dòng, chứa config, splash, buffers và toàn bộ pages; thay đổi 1 demo tạo conflict và khó tìm đoạn tích hợp chuẩn. [đồng thuận 2 nguồn]

## Việc cần làm

- [ ] Tách `config/`, `bootstrap/`, `demos/<format>/`, `shared/`
- [ ] KHÔNG đổi key/widget text đang được integration test tìm
- [ ] Chạy lại toàn bộ `example/integration_test/` sau khi tách, xác nhận không vỡ

## Ghi chú

Priority P2 — chưa xác nhận độ ưu tiên trực tiếp với user (hết slot câu hỏi), để mặc định theo BACKLOG doc.
