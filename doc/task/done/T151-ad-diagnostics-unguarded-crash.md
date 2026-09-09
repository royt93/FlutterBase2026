# T151 — Màn hình debug tổng hợp có thể sập vì log cũ không đúng định dạng

**Loại:** bug
**Ưu tiên:** P1 (không ảnh hưởng người dùng cuối, chỉ dev)
**Trạng thái:** DONE — verified 9.5/10 (codex, 2 vòng review độc lập, 2 finding sửa xong)
**Nguồn phát hiện:** subagent vip+monetization, tự verify

## Kết quả (2026-09-09)
Fixed. `lastWaterfallBySlotFrom` thay `AdSlotType.values.byName(...)` (throw) bằng vòng lặp tìm khớp an toàn (giống `WaterfallTuner._Key.tryParse`), skip entry lỗi thay vì crash.

Codex review vòng 1 bắt 2 finding: (P2) thiếu log đếm số entry bị skip (đúng yêu cầu gốc của task) — đã thêm `SafeLogger.w`; (P2) demo trong example gọi thẳng hàm pure `lastWaterfallBySlotFrom` với list tự dựng, bỏ qua đúng đường thật (`AdManager().diagnostics()` đọc từ `AdEventLog` đã persist) — đã sửa bằng cách thêm debug seam `AdEventLog.debugInjectRawEntry()` + `AdManager().debugEventLog` getter, demo giờ tiêm entry lỗi vào log thật rồi gọi `diagnostics()` thật. Vòng 2: sạch.

Test: 2 unit test mới (garbage slotType + null/thiếu slotType) trong `test/ad_diagnostics_test.dart` (nay 9 test). Demo mới trong `DiagnosticsDemoPage` (nút "Simulate corrupted log entry") + widget test mới. Smoke test thật **PASS trên Pixel 7 Pro** — log xác nhận đúng dòng cảnh báo skip xuất hiện qua đường `AdManager().diagnostics()` thật. Suite: 1799/1799 (ad_sdk) + 36/36 (example) xanh, `flutter analyze` sạch.
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Màn hình debug nội bộ (chỉ dev xem log, không phải người dùng cuối) có thể bị sập nếu 1 dòng log cũ từ bản SDK đời trước còn sót lại trên máy, không đúng định dạng mới. Không ảnh hưởng người dùng cuối, chỉ ảnh hưởng dev khi debug.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/ad_diagnostics.dart:69` — `AdSlotType.values.byName(e['slotType'] as String)` không có guard, đọc thẳng từ compliance-log đã persist (`AdEventLog.entries`) — log này sống qua nhiều lần update app, không được validate `slotType` tại load time.
- So sánh: `ad_event_log.dart`'s `_load()` (cùng chủ đề) đã tự lọc bỏ entry thiếu `timestampMs` hợp lệ đúng vì lý do này; `WaterfallTuner._Key.tryParse` cũng trả `null` thay vì throw cho tình huống tương tự. `ad_diagnostics.dart` là chỗ duy nhất không theo convention "skip lỗi, đừng throw".
- Entry với `slotType` thiếu/null/không khớp enum (log cũ từ version khác, SharedPreferences bị chỉnh tay, hoặc field hỏng) sẽ ném `TypeError`/`ArgumentError` không bắt, sập toàn bộ `AdManager().diagnostics()`.

## Việc cần làm
1. Thay `AdSlotType.values.byName(...)` bằng kiểm tra an toàn (VD `AdSlotType.values.firstWhereOrNull((t) => t.name == e['slotType'])`), skip entry lỗi thay vì throw — nhất quán với `WaterfallTuner._Key.tryParse`.
2. Thêm log SafeLogger khi 1 entry bị skip vì `slotType` không hợp lệ (đếm số lượng bị skip để dev biết log có bị hỏng hàng loạt không).
3. Thêm test: log entry có `slotType` là chuỗi rác/null → `diagnostics()` không throw, entry đó bị skip, các entry hợp lệ khác vẫn xử lý bình thường.
4. Thêm demo trong `example/` debug overlay: nút "chèn log rác" để tự tay tái hiện case này và chứng minh không sập.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/ad_diagnostics.dart dòng ~69: AdSlotType.values.byName(e['slotType'] as String) throw không kiểm soát nếu slotType không hợp lệ/null/không khớp enum. Đổi sang parse an toàn kiểu tryParse (đối chiếu convention đã dùng ở WaterfallTuner._Key.tryParse cùng package, hoặc ad_event_log.dart's _load() lọc bỏ entry hỏng) — skip entry lỗi, log qua SafeLogger, không throw. Viết unit test: AdEventLog chứa 1 entry slotType='garbage_value' và 1 entry slotType=null xen giữa các entry hợp lệ — gọi diagnostics() không throw, entry rác bị bỏ qua, entry hợp lệ vẫn có trong kết quả. Thêm demo trong example/ debug overlay.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho slotType rác/null xen giữa entry hợp lệ, xác nhận không throw.
3. Log SafeLogger đầy đủ (đếm số entry bị skip).
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, chèn log rác qua demo, mở màn debug tổng hợp, xác nhận không sập.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
