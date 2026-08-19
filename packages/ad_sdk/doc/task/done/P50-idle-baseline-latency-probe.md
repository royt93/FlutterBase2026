# P50 — Đo latency baseline lúc idle (trước khi bắt đầu stress test)

- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-08-11)
- **Nguồn:** subagent đọc source (idea, hạ tầng trực tiếp cho [[P25-idea-bufferbloat-score]])
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/latency_service.dart`, `models/test_result.dart`

## Ý tưởng
Hiện latency chỉ đo trong lúc đang tải (dưới stress). Thêm 1 lần đo latency **idle** (trước khi bắt đầu download loop, mạng chưa bị tải) → field mới `idleLatencyMs` trong `TestResult`. Chênh lệch `avgLatencyMs - idleLatencyMs` chính là chỉ số bufferbloat thô — hạ tầng trực tiếp cho [[P25-idea-bufferbloat-score]] đã ghi trong backlog vòng 1.

## Việc cần làm (đề xuất, chưa code)
- Thêm field `idleLatencyMs` vào `TestResult` (+ Hive adapter tay, theo pattern hiện có — không dùng build_runner).
- Gọi `LatencyService` 1 lần trước khi start download loop trong `StressorController`, lưu kết quả.

## Acceptance criteria
- [x] Test mới lưu đủ `idleLatencyMs` cùng `avgLatencyMs`.
- [x] Hiển thị chênh lệch idle vs under-load ở `test_detail_screen.dart` (tối thiểu 1 dòng info, chưa cần UI phức tạp).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm ticket này trước [[P25-idea-bufferbloat-score]] — P25 cần field `idleLatencyMs` thêm ở đây làm dữ liệu thật để tính điểm, không đoán số.

## Kết quả (2026-08-11)
- `test_result.dart`: thêm field `idleLatencyMs` (double?, index mới trong constructor/copyWith/fromControllerData/toJson/fromJson) + getter `idleLatencyFormatted` và `bufferbloatMs`/`bufferbloatFormatted` (= `avgLatencyMs - idleLatencyMs`, `null` nếu thiếu 1 trong 2 mốc — record cũ hoặc probe lỗi).
- `test_result_adapter.dart`: bump `numOfFields` 19 → 20, field index 19 = `idleLatencyMs` (double?). Record cũ (thiếu index 19) đọc ra `null` — cùng pattern backward-compat với `roomTag`/`thermalStatus`.
- `stressor_controller.dart`: `_startTest()` đổi sang `async`, `await _latencyService.probe()` **trước** khi start bất kỳ download loop/timer nào (mạng còn idle thật, chưa bị tải) → lưu vào field `_idleLatencyMs`. Guard bằng `_testGeneration` (nếu user Stop hoặc Start lại trong lúc đang chờ probe idle thì không ghi nhầm vào state của lần test khác) — cùng convention với các snapshot khác trong `_saveTestResult`. Snapshot `_idleLatencyMs` truyền vào `TestResult.fromControllerData` khi lưu.
- `test_detail_screen.dart`: thêm 1 dòng info `bufferbloat` (dùng `result.bufferbloatFormatted`, hiện `+N ms`/`-N ms`/`N/A`) ngay dưới dòng `latency` — đáp ứng acceptance criteria "tối thiểu 1 dòng info".
- Translations: thêm `bufferbloat` (en_us.dart + vi_vn.dart).
- Test: `test/p50_idle_latency_test.dart` (mới — bufferbloatMs tính đúng, null khi thiếu 1 mốc, formatted string, copyWith giữ nguyên field) + cập nhật `test/wave6_room_tag_test.dart` (numOfFields 19 → 20 field, round-trip thêm field 19). `flutter analyze` sạch, `flutter test` toàn bộ pass.
- Không đổi `latency_service.dart` — `probe()` sẵn generic, tái dùng nguyên cho lần đo idle, không cần API mới.
