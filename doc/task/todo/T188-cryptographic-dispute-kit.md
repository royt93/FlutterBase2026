# T188 — Bộ tạo bằng chứng khiếu nại đòi tiền quảng cáo (Cryptographic Dispute Kit)

**Loại:** exclusive-feature
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** agy (ý tưởng lớn, tận dụng hạ tầng T145 + `compliance_signing.dart` có sẵn)
**Quyết định chủ dự án (2026-09-08):** Làm (đây là 1 trong 4 ý tưởng lớn, được chọn làm THẬT vì effort thấp/ROI rõ — 3 ý tưởng lớn còn lại T189/T190/T191 chỉ ghi plan/nghiên cứu)

## Ý tưởng (giải thích thực tế)
Khi Google/AppLovin từ chối trả tiền cho 1 lượt quảng cáo (nói "không hợp lệ"), SDK tự tạo 1 file "bằng chứng" có chữ ký số (chứng minh quảng cáo đã thật sự hiện cho người dùng) để gửi khiếu nại đòi lại tiền. Tận dụng đồ nghề chữ ký số đã có sẵn từ `compliance_signing.dart` (T-trước) và dữ liệu đối chiếu từ `RevenueIntegrityLedger`/`IncidentRecorder` (T145) — không cần làm gì mới từ đầu về mặt hạ tầng crypto.

**Lưu ý quan trọng cần nói rõ với chủ dự án (đã nêu lúc hỏi ý kiến):** file bằng chứng này chỉ là bằng chứng PHÍA BẠN — không bắt buộc Google/AppLovin phải chấp nhận, chỉ giúp lập luận tốt hơn khi khiếu nại. Không hứa quá mức về khả năng "chắc chắn đòi được tiền".

## Chi tiết kỹ thuật
- Tận dụng: `packages/ad_sdk/lib/src/compliance/compliance_signing.dart` (Ed25519 signing đã có), `packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart` (T150 xong sẽ cho dữ liệu match chính xác hơn), `packages/ad_sdk/lib/src/compliance/incident_recorder.dart` (đã ghi lại incident `revenue_integrity_missing:*`).
- Cần thiết kế mới: format file `dispute_evidence_bundle` (JSON, có thể nén `.gz`), nội dung gồm: thông tin lượt quảng cáo bị từ chối (provider, placement, type, timestamp, giá trị kỳ vọng), incident liên quan từ `IncidentRecorder`, chữ ký Ed25519 của toàn bộ payload để chứng minh không bị chỉnh sửa sau khi tạo.
- API công khai mới: `AdManager().exportDisputeEvidence({DateTime? since})` trả về file/bytes.

## Việc cần làm
1. Thiết kế cấu trúc `DisputeEvidenceBundle` (class mới trong `lib/src/monetization/` hoặc `lib/src/compliance/`) — liệt kê chính xác field cần có.
2. Implement `AdManager().exportDisputeEvidence(...)`: gom incident + revenue-integrity data liên quan, ký bằng `compliance_signing.dart` có sẵn, xuất ra JSON (nén gz nếu cần).
3. Viết test cho: export khi không có incident nào (rỗng, không lỗi); export khi có nhiều incident; xác nhận chữ ký hợp lệ và bị phát hiện nếu payload bị chỉnh sửa sau khi ký.
4. Thêm demo trong `example/`: nút "Xuất bằng chứng khiếu nại" trong debug overlay, hiển thị nội dung file xuất ra được.
5. Cập nhật CHANGELOG.md và README.md (mục mới, giải thích rõ đây là bằng chứng phía app, không bảo đảm kết quả khiếu nại).

## Prompt để chạy loop-fix
```
Thiết kế và implement tính năng xuất "bằng chứng khiếu nại đòi tiền quảng cáo" cho packages/ad_sdk. Đọc kỹ packages/ad_sdk/lib/src/compliance/compliance_signing.dart (cơ chế ký Ed25519 có sẵn), packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart (đảm bảo T150 đã xong trước khi bắt đầu — đọc doc/task/done/T150*.md để xác nhận), và packages/ad_sdk/lib/src/compliance/incident_recorder.dart (incident tag revenue_integrity_missing:*). Thiết kế class DisputeEvidenceBundle mới chứa: danh sách lượt quảng cáo bị nghi ngờ thất thoát tiền (provider, placement, type, timestamp, chi tiết incident), ký toàn bộ payload bằng compliance_signing.dart hiện có. Thêm API công khai AdManager().exportDisputeEvidence({DateTime? since}) trả về bytes/JSON string. Viết test: export rỗng, export có nhiều incident, xác nhận verify chữ ký phát hiện đúng khi payload bị chỉnh sửa sau ký. Thêm demo trong example/ debug overlay: nút xuất bằng chứng, hiển thị nội dung. Cập nhật README.md, ghi rõ đây là bằng chứng phía app, không bảo đảm kết quả khiếu nại với network quảng cáo.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho export rỗng/có dữ liệu, verify chữ ký; widget test cho demo overlay; integration test cho luồng export end-to-end.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật (ghi rõ giới hạn "không bảo đảm kết quả").
4. Audit độc lập (kiểm tra kỹ: chữ ký không thể giả mạo, không lộ thông tin nhạy cảm của người dùng trong file xuất) — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, tạo tình huống incident thật (mô phỏng), xuất file bằng chứng qua demo, xác nhận nội dung đúng và chữ ký hợp lệ.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
