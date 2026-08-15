# T87 — Tối ưu thời gian/flakiness CI iOS Simulator

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `.github/workflows/test.yml:143-270`, `.github/scripts/integration-retry.sh`

## Vấn đề (Why)
Job `sdk-integration-ios` mất ~16-18 phút (đã shard 3 runner), vẫn phụ thuộc script retry để vượt lỗi nghẽn DDS/apsd daemon macOS runner.

## Đề xuất
Tối ưu chu trình boot simulator, giảm log stream không cần thiết, cân nhắc thêm cache warm simulator giữa các run để giảm dưới 10 phút.

## Acceptance criteria
- [ ] Thời gian chạy job giảm rõ rệt (đo trước/sau), không tăng flakiness.
