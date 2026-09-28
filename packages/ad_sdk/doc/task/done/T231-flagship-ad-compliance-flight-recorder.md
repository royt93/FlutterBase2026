# T231 — Tính năng độc quyền: Hộp đen bằng chứng tuân thủ quảng cáo (Flight Recorder)

- **Loại:** Flagship (Độc quyền)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** 🔲 todo

## Vấn đề (Why)
Khi nhà mạng (AdMob/AppLovin) phạt trừ tiền hoặc khóa tài khoản vì nghi ngờ 'Invalid Traffic' hoặc 'Ad layout che UI', nhà phát triển hầu như không có bằng chứng đối chất. SDK cần một 'Hộp đen' ghi nhận bất biến mọi trạng thái.

## Đề xuất giải pháp & Acceptance Criteria
1. Mở rộng `DisputeKit` thành `AdFlightRecorder` dạng chuỗi băm Merkle liên tục.
2. Ghi nhận: Tọa độ pixel của ad view trên màn hình, tỉ lệ hiển thị (viewability %), thời gian tương tác, chuỗi đồng thuận GDPR TCF, và trạng thái touch.
3. Ký số Ed25519 cục bộ cho từng phiên ghi, xuất file chứng cứ `.adproof` không thể làm giả để gửi kháng cáo nhà mạng.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: Kiểm tra tính toàn vẹn chữ ký và cấu trúc băm Merkle.
- Integration test: `example/integration_test/t144_dispute_kit_test.dart`.
- On-device test: Xuất file bằng chứng thực tế và verify qua tool CLI.

### Bằng chứng bổ sung trên thiết bị (2026-09-28)

- Google Pixel 7 Pro (`2B051FDH3006MU`): `flutter test integration_test/t231_flight_recorder_test.dart -d 2B051FDH3006MU` pass `1/1` trên thiết bị thật.
- Logcat không có `FATAL EXCEPTION`; recorder ghi `bannerVisible` với pixel bounds/viewability thật, hash chain và signed bundle đều được test xác minh. Kết quả này đóng khoảng trống bằng chứng thiết bị được ghi nhận trong final integration audit.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T231 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T231-flagship-ad-compliance-flight-recorder.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
