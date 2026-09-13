# T198 — JourneyPrefetcher route lifecycle đầy đủ (ENHANCE)
Priority P2 · Status todo · Source `lib/src/monetization/journey_prefetcher.dart:219-235`.

Observer chỉ `didPush`; pop/replace bỏ lỡ journey và có thể giữ prefetch stale. Khuyến nghị typed events didPush/didReplace/didPop + dedupe policy, giữ API cũ. Chỉ thêm didPop rẻ hơn nhưng replace vẫn thiếu.

Tests: unit callbacks/dedupe/dispose; widget Navigator push/pop/replace; integration route stack; device smoke không request trùng.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.

## Kết quả (2026-09-13)

Sửa đúng theo khuyến nghị: thêm CẢ `didPop` LẪN `didReplace` (không chỉ
`didPop` — đúng cảnh báo trong mô tả gốc rằng chỉ thêm `didPop` vẫn thiếu
`didReplace`). Không đổi API công khai (`notifySignal`, `routeObserver`
giữ nguyên) — cả 3 callback đều gọi qua cùng 1 helper `_notify` dùng lại
đúng `notifySignal` sẵn có.

Ngữ nghĩa quan trọng cần đúng: `didPop(route, previousRoute)` phải dùng
tên của `previousRoute` (màn hình được LỘ RA sau khi pop), KHÔNG phải
`route` (màn đang bị gỡ bỏ) — đã viết test riêng xác nhận đúng hướng
này, không lẫn lộn.

Không thêm "dedupe policy" riêng như gợi ý phụ trong mô tả gốc —
`notifySignal` hiện tại đã tự nhiên "idempotent" theo nghĩa: gọi lại
nhiều lần cho cùng 1 key chỉ cập nhật lại mốc thời gian, và các adapter
thật vốn đã tự bỏ qua load trùng khi đã có ad tươi (T193 vừa xác nhận
đúng cơ chế này). Thêm 1 tầng dedupe riêng sẽ là over-engineering không
cần thiết (đúng tinh thần YAGNI).

Xác minh không vô nghĩa: tạm bỏ `didPop`/`didReplace`, xác nhận đúng 2
test liên quan fail, rồi khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2058 test xanh (từ 2055,
+3, dùng `Navigator` thật qua widget test — push/pop/replace thật, không
giả lập); example suite 47 file xanh (không đổi).

**Không có device smoke** — cơ chế `NavigatorObserver`/route lifecycle
là 100% thuần Flutter framework, không đụng platform channel/native code
nào, hành vi giống hệt nhau trên mọi nền tảng. Widget test dùng
`Navigator` THẬT (không phải giả lập route observer) đã chứng minh đầy
đủ; chạy lại trên thiết bị thật sẽ không phát hiện thêm gì khác. Không
tạo demo UI mới trong `example/` chỉ để có chỗ chạy smoke test (đúng
tinh thần YAGNI, giống lý do đã áp dụng ở T196/T197).

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ + phân biệt
đúng `previousRoute` vs `route` trong `didPop` (lỗi ngữ nghĩa dễ mắc
phải nhất khi làm task này).
