# T196 — Clear nullable ConsentSettings (FIX/ENHANCE)
Priority P2 · Status todo · Source `lib/src/consent/consent_settings.dart:66-81`.

`copyWith(askedAt:null,country:null)` không xoá được giá trị cũ vì `?? this.field`. Khuyến nghị thêm `clearAskedAt`/`clearCountry` flags (non-breaking); sentinel một API nhưng typing phức tạp; đổi semantics nullable là breaking.

Tests: unit set/preserve/clear/JSON; widget privacy UI; integration persist/reload; device smoke redaction.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; chỉ >9/10 commit+push.

## Kết quả (2026-09-13)

Sửa đúng theo khuyến nghị chính: thêm `clearAskedAt`/`clearCountry`
(bool, mặc định `false`, không phá caller cũ nào). Không dùng sentinel
object (phức tạp typing hơn nhiều so với lợi ích) và không đổi semantics
nullable hiện có (đúng là breaking như mô tả gốc cảnh báo). Thêm
`assert` chặn truyền đồng thời cả giá trị VÀ cờ clear cho cùng 1 field
(mâu thuẫn) — chỉ có tác dụng ở debug/test build, không ảnh hưởng
release.

Xác minh không vô nghĩa: tạm bỏ logic clear, xác nhận cả unit test lẫn
test tích hợp (persist/reload thật qua `ConsentManager`) đều fail đúng
như mong đợi, rồi khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2042 test xanh (từ 2032,
+10, gồm cả unit test set/preserve/clear/JSON và 1 test tích hợp
persist→reload thật qua `ConsentManager.bootstrap`/`set`, mô phỏng
"mở app lại" bằng cách tạo `ConsentManager` mới từ cùng `prefs`); example
suite 47 file xanh (không đổi).

**Không có "widget privacy UI" nào để test** — `ConsentSettings` là
data-class thuần, chưa có UI nào trong SDK/example dùng
`clearAskedAt`/`clearCountry` (tính năng này chuẩn bị sẵn cho T200 —
"scoped SDK data erasure" — vốn chưa làm). **Không có device smoke** vì
lý do tương tự: không có tính năng "redaction" thật nào tồn tại để chạy
thử trên máy thật — logic clear là thuần Dart, không đụng platform
channel/native code nào (khác T195 — nơi race điều kiện thật sự phụ
thuộc timing của Keychain/Keystore thật). Đã bù bằng 1 test tích hợp
persist/reload thật (không giả lập ConsentManager) để chứng minh giá trị
bị xoá không "sống lại" sau khi lưu + tải lại.

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ ở cả 2 tầng
test (data-class thuần + tích hợp qua ConsentManager thật).
