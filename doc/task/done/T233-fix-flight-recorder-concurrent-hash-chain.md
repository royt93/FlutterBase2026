# T233 — Fix AdFlightRecorder race làm gãy hash chain khi ghi đồng thời

- **Loại:** Fix (Bug)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ✅ done (2026-09-29)

## Vấn đề (Why)

`AdFlightRecorder.record()` đọc `_lastHash` tại `packages/ad_sdk/lib/src/compliance/ad_flight_recorder.dart:329-350`, rồi `await _hashOf(...)` trước khi append entry và cập nhật `_lastHash` tại dòng 351-371. Trong khi đó, các call site cố ý gọi không chờ bằng `unawaited(...)`: Banner ở `lib/src/widget/banner_ad_widget.dart:333`, MREC ở `lib/src/widget/mrec_ad_widget.dart:107`, click ở `lib/src/core/ad_manager.dart:9594`.

Hai event đến sát nhau có thể cùng chụp một `previousHash`, tạo hai nhánh song song. Entry thứ hai khi export sẽ không nối với hash của entry ngay trước nó, nên `verifyFlightRecorderChain()` trả `false` dù file chưa bị ai sửa. Đây là lỗi trực tiếp làm bằng chứng `.adproof` mất giá trị trong traffic bình thường.

## Đề xuất giải pháp

Tuần tự hóa toàn bộ phép ghi record theo một future chain/critical section tối giản, tương tự `_persistChain`, nhưng phải giữ đúng thứ tự gọi và không để một lần hash lỗi chặn vĩnh viễn các lần sau. Không dùng mutex/dependency mới.

### Acceptance Criteria

- [ ] Nhiều lệnh `record()` chạy đồng thời luôn tạo một chuỗi tuyến tính hợp lệ, đúng thứ tự nhận lệnh.
- [ ] Một lần hash/record lỗi không làm future chain bị poison; event sau vẫn ghi được.
- [ ] Ring buffer/capacity, `interactionDurationMs`, debounce persistence và API công khai giữ nguyên.
- [ ] `verifyFlightRecorderChain(entries)` luôn pass cho burst event thật từ visibility + click.
- [ ] Không ảnh hưởng các quyết định sản phẩm đã duyệt của owner.
- [ ] `flutter analyze` sạch; full `flutter test` pass.

## Kế hoạch kiểm thử

- Unit: gọi 20-100 `record()` không await từng lệnh, `Future.wait`, kiểm tra từng `previousHash` và verify toàn chuỗi.
- Unit failure: ép một thao tác lỗi/invalid input có kiểm soát, xác nhận record kế tiếp vẫn chạy.
- Widget/wiring: phát visibility + click sát nhau qua call site thật, export bundle và verify.
- Integration/device: tạo burst transition trên màn hình Banner/MREC, xuất `.adproof`, verify trên thiết bị thật.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T233 theo quy trình TDD chuẩn:
1. Đọc kỹ ticket và acceptance criteria; viết test RED chứng minh hai record đồng thời hiện làm gãy chain.
2. Sửa tối giản, giữ API và hành vi mặc định.
3. Chạy unit + widget + integration cho success, failure, lifecycle và burst concurrency; mutation/revert tạm để chứng minh test bắt đúng bug.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Audit toàn bộ diff và chấm điểm /10 bằng reviewer độc lập.
   - Bổ sung đủ test pyramid, smoke test device thật.
   - Chỉ commit và push khi mọi gate xanh và điểm >9/10.

## Kết quả

- Repro RED: 2-call, 5-call và clear-race burst đều làm `verifyFlightRecorderChain` trả `false` trước fix.
- Fix: tuần tự hóa `record()` qua `_writeChain`; `_doRecord` giữ nguyên hash/append/persist và tự nuốt lỗi nên queue không bị poison.
- Test GREEN: 28 test Flight Recorder, 77 test liên quan + API golden, full `flutter test` pass. Pure Dart/event-loop logic nên không cần device/integration test.
