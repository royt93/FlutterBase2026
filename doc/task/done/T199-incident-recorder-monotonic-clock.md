# T199 — Incident timeline dùng monotonic clock (ENHANCE)
Priority P3 · Status todo · Source `lib/src/monetization/incident_recorder.dart:99-107`.

DateTime.now rollback bởi NTP/timezone có thể tạo delta âm. Khuyến nghị inject clock, lưu monotonic elapsed + wall-clock display và đánh dấu clock jump; clamp-only che giấu nguyên nhân.

Tests: unit rollback/forward/injected clock; widget timeline; integration restart; device smoke đổi timezone/NTP.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Kết quả (2026-09-13)

**Sửa lại vị trí file trong mô tả gốc**: `IncidentRecorder` thật sự nằm
ở `lib/src/compliance/incident_recorder.dart` (không phải
`monetization/` như mô tả gốc ghi) — đã đọc code thật trước khi sửa.

**Cố ý KHÔNG làm đúng y hệt khuyến nghị chính** ("lưu monotonic elapsed
+ wall-clock display") — sau khi đọc kỹ `VipManager._effectiveNow`/
`resyncSessionClock` (cùng repo, xử lý đúng vấn đề "đồng hồ nhảy" cho
VIP), phát hiện: `Stopwatch` (nguồn monotonic duy nhất trong Dart thuần)
NGỪNG CHẠY khi máy ngủ/khoá màn hình. Nếu dùng elapsed monotonic làm giá
trị `deltaMs` chính, 1 khoảng cách THẬT (app chạy nền vài giờ giữa 2
incident) sẽ bị báo cáo SAI thành rất ngắn — một lỗi ÂM THẦM còn tệ hơn
delta âm đang muốn sửa. `VipManager` từng mất nhiều vòng audit mới xử lý
đúng vấn đề tương tự (dùng `resyncSessionClock()` neo lại lúc app resume)
— với `IncidentRecorder` (công cụ debug nhẹ, không phải cơ chế bảo mật/
doanh thu), thêm độ phức tạp đó là không xứng đáng.

**Giải pháp thay thế, xử lý đúng bản chất vấn đề trong mô tả gốc**: giữ
`deltaMs` dựa trên wall-clock (đúng cho khoảng cách nền hợp lệ), nhưng
khi wall-clock đọc NGƯỢC (delta âm) — dấu hiệu CHÍNH XÁC của 1 lần đồng
hồ nhảy lùi — clamp `deltaMs` về 0 (không hiển thị số âm khó hiểu) VÀ
lưu riêng giá trị âm gốc vào field mới `clockRolledBackMs` (null nếu
không có rollback). Đúng tinh thần "clamp-only che giấu nguyên nhân" mà
mô tả gốc cảnh báo — không chỉ clamp, còn đánh dấu rõ.

Đã có sẵn "inject clock" từ trước (`record(..., {DateTime? now})`) —
không cần thêm gì, tái dùng nguyên vẹn.

Xác minh không vô nghĩa: tạm bỏ logic phát hiện rollback, xác nhận 3/6
test liên quan fail đúng (3 test còn lại kiểm tra trường hợp "không có
rollback", không đổi vì logic case bình thường không bị ảnh hưởng), rồi
khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2064 test xanh (từ 2058,
+6, gồm cả round-trip qua `IncidentBundle` JSON export/import thật);
example suite 47 file xanh (không đổi).

**Không có widget timeline / device smoke đổi timezone-NTP** — không có
UI nào trong SDK/example hiện hiển thị `IncidentEntry`/timeline (chưa
có tính năng này) nên không có "widget timeline" để test; và tự động
đổi timezone/NTP thật trên thiết bị giữa lúc chạy integration test là
thao tác xâm lấn, không an toàn để tự động hoá — thay vào đó, unit test
đã tiêm (`now:`) chính xác kịch bản 1 đồng hồ đọc lùi thật sự tạo ra (mô
phỏng trung thực NTP/timezone rollback, không phải giả định suông).

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ + tự phát
hiện và tránh đúng cái bẫy monotonic-elapsed mà `VipManager` từng dính
phải, tránh lặp lại sai lầm cũ trong cùng codebase.
