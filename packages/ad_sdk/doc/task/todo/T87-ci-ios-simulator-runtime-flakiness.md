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

## Ghi chú (2026-08-16) — chưa làm, cần quyết định của user

Ticket này khác các vé khác trong round này: acceptance criteria đòi đo timing thật trên GitHub Actions CI, không thể verify bằng `flutter test`/local như mọi fix khác trong session này. Job `sdk-integration-ios` hiện tại đã được tune rất kỹ qua nhiều lần debug thật trên CI (comment trong `test.yml` ghi rõ run ID cụ thể cho từng fix: OOM killer, apsd/DDS log-stream flooding, Xcode/runtime version mismatch). Sửa "đoán" mà không có CI thật để verify có rủi ro làm hỏng lại 1 setup đang ổn định, không đúng tinh thần "chỉ sửa khi verify được" đã áp dụng xuyên suốt session này.

User chọn: bỏ qua ticket này trong round hiện tại, giữ nguyên ở `todo/`, chuyển sang xử lý khi có dịp verify được trên CI thật (vd 1 branch thử nghiệm riêng, đo qua `gh run view`).
