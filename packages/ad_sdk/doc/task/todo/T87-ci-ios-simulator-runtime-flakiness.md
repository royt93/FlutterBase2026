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

## Ghi chú (2026-08-22) — thử lại, sửa trực tiếp trên main

User chọn sửa trực tiếp trên `main` (không qua branch thử nghiệm), khác quyết định 2026-08-16 ở trên. Để giảm rủi ro, chỉ thêm **CocoaPods cache** (`actions/cache@v4`, key theo `Podfile.lock`) + `cache: true` cho `subosito/flutter-action` — không đụng vào logic boot simulator / log-stream / retry đã tune kỹ (không có rủi ro reintroduce apsd/DDS flakiness vì code đường đó giữ nguyên). Vẫn CHƯA push — acceptance criteria (đo trước/sau) cần 1 lần chạy CI thật trên `main` mới verify được, chưa đo local được.

## Ghi chú (2026-08-22, phát hiện chặn) — GitHub Actions bị block do billing, không đo được

Fix cache ở trên **đã được push** trong lúc này (commit `1a8185d`, đã lên `origin/main` từ trước — không phải do phiên này push). Khi thử `gh run view` để đo timing trước/sau theo kế hoạch, phát hiện: **30 CI run gần nhất (từ 2026-08-09 đến nay) đều fail trong 3-7 giây**, annotation ghi rõ:

> "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings."

Nghĩa là **không có CI run thật nào chạy** kể từ 2026-08-09 — mọi kết luận "CI xanh"/"649/649 pass" trong các audit round trước đây chỉ dựa trên `flutter test` local, chưa từng được GitHub Actions xác nhận thật trong hơn 2 tuần qua. Đây là vấn đề billing tài khoản GitHub, ngoài khả năng Claude Code xử lý — cần user vào `github.com/settings/billing` cập nhật phương thức thanh toán/spending limit.

User chọn (2026-08-22): tạm bỏ qua billing, không chờ xử lý ngay, tiếp tục xác nhận bằng `flutter analyze` + `flutter test` local thay thế (891/891 pass, analyze sạch) — nhưng **acceptance criteria đo timing CI thật của ticket này vẫn KHÔNG THỂ đóng được** cho tới khi billing được khôi phục và có ít nhất 1 run CI thật để so sánh trước/sau cache. Giữ ticket ở `todo/`.
