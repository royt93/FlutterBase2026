# T155 — Nhật ký "back door" biến mất mỗi khi tắt hẳn app

**Loại:** enhancement (bảo toàn bằng chứng compliance)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent consent+compliance, tự verify
**Quyết định chủ dự án (2026-09-08):** Lưu lại lâu dài (persist), không giữ chỉ-tạm-thời

## Vấn đề (giải thích thực tế)
Khi có sự cố, hệ thống dùng "back door" (`bypassSafety`) đúng 1 chỗ duy nhất lúc mở app — màn hình chờ đầu tiên (splash), theo đúng hợp đồng tích hợp trong README/CLAUDE.md. Hệ thống có ghi lại nhật ký (`BypassAuditTrail`, tự gọi là "flagship proof-of-compliance") để sau này chứng minh "chỉ dùng đúng chỗ đã khai báo". Nhưng nhật ký này chỉ nằm trong bộ nhớ tạm (RAM) — mỗi lần người dùng tắt hẳn app (rất hay xảy ra trên điện thoại), nhật ký cũ biến mất. Nếu sau này cần chứng minh cho đối tác/audit, chỉ còn nhật ký của lần mở app gần nhất.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart` (toàn bộ) + `packages/ad_sdk/lib/src/core/ad_manager.dart:1293` — `BypassAuditTrail` chỉ là ring-buffer trong RAM, không persist qua `AdPreferences` như `AdEventLog` (`ad_event_log.dart` có `_load()`/`_persist()` qua SharedPreferences).
- Nguồn ghi chính (`bypassSafety`) xảy ra ở mỗi cold-start splash — app bị kill là chuyện thường ngày trên mobile, nên lịch sử "back door" của phiên trước biến mất khỏi RAM nếu host không chủ động export ngay trong phiên đó.

## Việc cần làm
1. Persist `BypassAuditTrail` giống `AdEventLog` (dùng cùng debounce/persist pattern có sẵn qua `AdPreferences`).
2. Giữ giới hạn kích thước hợp lý (ring-buffer, không phình vô hạn) — quyết định số lượng entry tối đa lưu trữ, document rõ trong docstring.
3. Thêm log SafeLogger khi entry mới được ghi và khi persist thành công/thất bại.
4. Thêm demo trong `example/`: hiển thị lịch sử bypass đã lưu qua nhiều lần mở/tắt app (không chỉ phiên hiện tại).
5. Cập nhật CHANGELOG.md và docstring của `BypassAuditTrail` (bỏ giới hạn "chỉ phiên hiện tại" cũ, ghi rõ giờ đã persist).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart: BypassAuditTrail hiện chỉ là ring-buffer trong RAM (final BypassAuditTrail bypassAuditTrail = BypassAuditTrail(); ở ad_manager.dart:1293), mất dữ liệu mỗi khi app bị kill. Đọc ad_event_log.dart để hiểu đúng pattern persist/debounce/_load()/_persist() qua AdPreferences đã dùng cho AdEventLog, áp dụng tương tự cho BypassAuditTrail — giữ ring-buffer nhưng ghi xuống SharedPreferences định kỳ/mỗi lần thêm entry, load lại lúc khởi động. Giới hạn số entry lưu trữ hợp lý (đối chiếu AdEventLog dùng bao nhiêu). Viết unit test: thêm entry, "khởi động lại" (tạo instance mới đọc từ cùng AdPreferences mock), xác nhận entry cũ vẫn còn. Thêm log SafeLogger. Thêm demo trong example/ hiển thị lịch sử bypass qua nhiều lần khởi động lại app.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test persist/reload cho `BypassAuditTrail` (giống pattern test của `AdEventLog`); test giới hạn kích thước ring-buffer.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md + docstring cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device — dùng bypass ở splash, tắt hẳn app (kill process thật, không chỉ background), mở lại, xác nhận lịch sử bypass cũ vẫn còn trong demo.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
