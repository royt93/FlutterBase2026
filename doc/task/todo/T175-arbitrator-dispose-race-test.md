# T175 — Thêm test cho: tắt tính năng tự chọn mạng đúng lúc đang xử lý dở

**Loại:** test-coverage
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent vip+monetization / test-coverage-gap
**Quyết định chủ dự án (2026-09-08):** Thêm test ngay

## Vấn đề (giải thích thực tế)
Tính năng tự động chọn mạng quảng cáo trả tiền cao hơn (`MonetizationArbitrator`) có gần đủ test (test file 856 dòng, có test dispose-swap tốt), nhưng thiếu đúng 1 trường hợp hiếm: nếu app bị tắt (`dispose()`) đúng lúc 1 sự kiện đang xử lý dở (`_onEvent` chưa xong), có thể gây rò rỉ bộ nhớ nhỏ hoặc đảo lộn thứ tự đọc/ghi. Chưa từng gặp thực tế, chỉ là lỗ hổng lý thuyết chưa có test chắc chắn — nhưng `SelfHealingObserver` (module tương tự trong cùng package) đã có đúng test này ("dispose() awaits the in-flight dedupe write"), nên đây là mẫu nên áp dụng lại.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart` (409 dòng) — chưa có test cho `dispose()` gọi đồng thời với event đang in-flight.
- Tham khảo: `test/self_healing_observer_test.dart` đã có test "dispose() awaits the in-flight dedupe write" — dùng làm mẫu.

## Việc cần làm
1. Đọc `_onEvent` trong `monetization_arbitrator.dart` xác định đúng đoạn async có thể bị cắt ngang bởi `dispose()`.
2. Nếu code hiện tại ĐÃ an toàn (chỉ thiếu test), viết test xác nhận. Nếu phát hiện thật sự có race (rò rỉ/đảo lộn), sửa theo đúng pattern `self_healing_observer.dart` đã dùng (`dispose()` await in-flight write trước khi hủy subscription).
3. Cập nhật CHANGELOG.md nếu có sửa code (không chỉ thêm test).

## Prompt để chạy loop-fix
```
Đọc packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart, đặc biệt _onEvent và dispose(). Đối chiếu packages/ad_sdk/lib/src/monetization/self_healing_observer.dart (đã có pattern "dispose() awaits the in-flight dedupe write", xem test tương ứng trong test/self_healing_observer_test.dart để hiểu đúng cách test). Viết test tương tự cho MonetizationArbitrator: dispose() gọi đúng lúc _onEvent đang xử lý dở (mock 1 async op chưa resolve) — xác nhận không rò rỉ subscription, không ghi dữ liệu sau khi đã dispose. Nếu test phát hiện race thật (không chỉ thiếu test), sửa dispose() để await in-flight work trước khi hủy, đúng pattern self_healing_observer.dart.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Test mới cho dispose-during-in-flight-event, pass rõ ràng (không flaky).
3. Nếu có sửa code: CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: nếu có sửa code, smoke test thật trên device (bật/tắt arbitrator liên tục qua demo có sẵn trong `example/`), xác nhận không crash/leak quan sát được; nếu chỉ thêm test thì bỏ qua bước smoke test.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
