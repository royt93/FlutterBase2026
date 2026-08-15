# T83 — CI không track code coverage theo thời gian

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `.github/workflows/test.yml`

## Vấn đề (Why)
Con số 66.4% (audit 20260711) là đo thủ công 1 lần, không lặp lại mỗi audit. Quyết định quan trọng (bump major, thông báo consumer) hiện chỉ sống trong audit log, không có backlog item chính thức hay số liệu tự động theo thời gian.

## Đề xuất
Thêm bước `flutter test --coverage` + report (badge hoặc artifact) vào CI job `sdk`, không nhất thiết phải set threshold gate ngay — trước mắt chỉ cần có số liệu theo mỗi run.

## Acceptance criteria
- [ ] CI job `sdk` xuất coverage report mỗi run (artifact hoặc log).
