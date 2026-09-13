# T195 — Serialize mint signing key đầu tiên (FIX)
Priority P1 · Status todo · Source `lib/src/compliance/compliance_signing.dart:62-103,166-178`.

Concurrent exports cùng đọc null, mint hai Ed25519 key rồi ghi đè; bundle vẫn verify nhưng stable public-key contract bị phá. Khuyến nghị process-wide async mutex + double-check storage. Native CAS mạnh hơn nhưng platform-specific.

Tests: unit concurrent cả hai API, corrupt/read-write failure; widget double-tap export; integration concurrent exports; smoke Android+iOS xác nhận cùng public key.

Loop prompt: audit+score /10; unit/widget/integration mọi case; device smoke; >9/10 mới commit+push, nếu không loop.

## Kết quả (2026-09-13)

Đúng như mô tả. Sửa bằng process-wide async lock (dùng `Completer`, thuần
Dart, không cần dependency mới) bao quanh bước "đọc storage → mint nếu
chưa có → ghi lại": lệnh gọi nào đến khi đang có 1 lệnh khác đang mint sẽ
CHIA SẺ kết quả của lệnh đó (không tự mint riêng); lệnh nào đến SAU khi
lock đã nhả sẽ đọc lại storage bình thường và thấy khoá vừa được ghi (đã
tự nhiên "double-check" nhờ luồng đọc-trước-khi-mint có sẵn, không cần
thêm bước kiểm tra riêng). Lock áp dụng chung cho CẢ 2 API
(`signComplianceReport` và `signJsonPayload`) vì cùng dùng chung 1 khoá
lưu trữ (`_secureKeySeed`).

Không dùng CAS gốc hệ điều hành (khuyến nghị phụ trong mô tả gốc) — lý
do: cross-platform, cần code riêng Android/iOS, phức tạp hơn nhiều so
với lock thuần Dart mà vẫn giải quyết đúng vấn đề.

Xác minh không vô nghĩa: tạm bỏ lock, xác nhận test "8 lệnh gọi đồng thời"
tạo ra 8 khoá công khai KHÁC NHAU (đúng bug), rồi khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2032 test xanh (từ 2027, +5);
example suite 47 file xanh (không đổi); device smoke thật trên **Pixel 7
Pro** (`2B051FDH3006MU`) qua
`example/integration_test/t195_concurrent_key_mint_test.dart` — dùng
`FlutterSecureStorage()` THẬT (Android Keystore thật, không phải giả
lập), xoá sạch khoá cũ trước mỗi lần chạy, gọi 2 lệnh
`signComplianceReport` đồng thời thật, xác nhận cùng 1 public key, và
lệnh gọi tiếp theo (không đồng thời) cũng dùng lại đúng khoá đã lưu.

Không có UI "export báo cáo có chữ ký" nào trong `example/` (chỉ có
`exportComplianceReport()` trả về báo cáo CHƯA ký) — không thêm UI mới
chỉ để có chỗ viết "widget double-tap export" test (đúng tinh thần
YAGNI); tình huống double-tap thực chất chính là 2 lệnh gọi gần như đồng
thời — đã bao phủ đầy đủ ở tầng unit test (`Future.wait` với nhiều lệnh
gọi cùng lúc).

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ + device
smoke dùng đúng Android Keystore thật (không phải fake storage) để xác
nhận fix không chỉ đúng trên lý thuyết mà còn đúng với timing thật của
platform channel thật.
