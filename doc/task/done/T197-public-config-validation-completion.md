# T197 — Runtime validation cho public config knobs (FIX)
Priority P2 · Status todo · Sources `fill_rate_monitor.dart:38-81`, `fill_rate_baseline_monitor.dart`, `bypass_audit_trail.dart:75-83`.

Window <=0, threshold ngoài [0,1], maxEntries<=0 chỉ assert/không validate; release có monitor vô dụng hoặc lỗi runtime. Khuyến nghị ArgumentError runtime (clamp là option resilient nhưng che lỗi; giữ assert không đủ).

Tests: unit boundary/negative/release; widget config form; integration bad config; debug/release device smoke.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 mới commit+push.

## Kết quả (2026-09-13)

Sửa đúng cả 3 file theo khuyến nghị chính: đổi `assert` (bị loại bỏ ở
release build) sang `ArgumentError` thật (chạy ở MỌI build mode). KHÔNG
tự động "clamp" giá trị về khoảng hợp lệ — như mô tả gốc cảnh báo, clamp
sẽ che giấu lỗi cấu hình thay vì báo ngay cho dev biết.

Phát hiện thêm khi đọc kỹ `BypassAuditTrail`: `maxEntries` âm không chỉ
"vô dụng" như 2 monitor kia — nó làm `record()`'s dòng
`removeRange(0, _entries.length - maxEntries)` tính ra chỉ số kết thúc
LỚN HƠN độ dài danh sách thật (trừ số âm = cộng), gây crash `RangeError`
thật ngay lần trim đầu tiên. Đây là lý do `BypassAuditTrail` trước đó
KHÔNG có bất kỳ validation nào (kể cả assert) — nghiêm trọng hơn 2
monitor kia.

Xác minh không vô nghĩa: tạm bỏ cả 3 đoạn validation, xác nhận 6/7 test
liên quan fail đúng như mong đợi (test còn lại chỉ document lại cơ chế
crash gốc bằng code thuần, không phụ thuộc code SDK nên không đổi), rồi
khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2055 test xanh (từ 2042,
+13); example suite 47 file xanh (không đổi).

**Không có "widget config form" hay "device smoke" nào** — cả 3 demo
trong `example/` đều dùng giá trị hằng số hợp lệ cố định khi gọi
`enableFillRateMonitor`/`enableArbitrator` (không có UI cho người dùng
tự nhập ngưỡng), và bản thân fix này thuần Dart, không đụng platform
channel nào — không có sự khác biệt hành vi thật giữa build debug/
release để cần chứng minh trên thiết bị thật (đây CHÍNH LÀ điểm mấu chốt
của fix: `ArgumentError` chạy giống hệt nhau ở mọi build mode, không như
`assert` cũ). Không tạo UI mới chỉ để có chỗ test (đúng tinh thần
YAGNI).

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ cho cả 3
file, và tự phát hiện thêm rủi ro crash thật ở `BypassAuditTrail` ngoài
mô tả gốc.
