# P50 — Đo latency baseline lúc idle (trước khi bắt đầu stress test)

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source (idea, hạ tầng trực tiếp cho [[P25-idea-bufferbloat-score]])
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/latency_service.dart`, `models/test_result.dart`

## Ý tưởng
Hiện latency chỉ đo trong lúc đang tải (dưới stress). Thêm 1 lần đo latency **idle** (trước khi bắt đầu download loop, mạng chưa bị tải) → field mới `idleLatencyMs` trong `TestResult`. Chênh lệch `avgLatencyMs - idleLatencyMs` chính là chỉ số bufferbloat thô — hạ tầng trực tiếp cho [[P25-idea-bufferbloat-score]] đã ghi trong backlog vòng 1.

## Việc cần làm (đề xuất, chưa code)
- Thêm field `idleLatencyMs` vào `TestResult` (+ Hive adapter tay, theo pattern hiện có — không dùng build_runner).
- Gọi `LatencyService` 1 lần trước khi start download loop trong `StressorController`, lưu kết quả.

## Acceptance criteria
- [ ] Test mới lưu đủ `idleLatencyMs` cùng `avgLatencyMs`.
- [ ] Hiển thị chênh lệch idle vs under-load ở `test_detail_screen.dart` (tối thiểu 1 dòng info, chưa cần UI phức tạp).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm ticket này trước [[P25-idea-bufferbloat-score]] — P25 cần field `idleLatencyMs` thêm ở đây làm dữ liệu thật để tính điểm, không đoán số.
