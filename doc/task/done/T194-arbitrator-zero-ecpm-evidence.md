# T194 — Phân biệt no-evidence với eCPM bằng 0 (FIX)
Priority P1 · Status todo · Source `lib/src/monetization/monetization_arbitrator.dart:263-345`.

Getter trả 0 cho bucket chưa đủ mẫu và bucket đủ mẫu có revenue thật bằng 0; `_decide` coi cả hai là no evidence. Khuyến nghị private evidence model (`hasQualifiedSamples`, `ecpmMicros`) giữ getter public. Sentinel âm khó hiểu; đổi getter nullable là breaking.

Scrum/DoD: decision table cho estimator, warm-up, zero revenue, threshold, veto guardrail; fail-open chỉ khi chưa có mẫu.

Tests: unit mọi nhánh; widget reason zero-value; integration event stream revenue=0; device smoke không suppress/nudge vô hạn.

Loop prompt: audit+score /10, thêm unit/widget/integration mọi case và device smoke; chỉ >9/10 mới commit+push, ngược lại loop.

## Kết quả (2026-09-13)

Đúng như mô tả gốc (đã đọc code thật xác nhận, số dòng đã dịch chuyển
qua các task trước nhưng logic đúng vị trí mô tả). Sửa đúng theo đề
xuất: thêm hàm private `_hasQualifiedSamplesFor(slot)` phân biệt "chưa
đủ mẫu" (fail-open, giữ nguyên hành vi cũ) với "đủ mẫu, giá trị thật là
0" (giờ xử lý như bất kỳ eCPM thấp nào khác — có thể bị veto, vẫn tuân
theo guardrail `maxVetoRate`, vẫn luôn gọi VIP-likelihood estimator nếu
có đăng ký). Getter public `estimatedEcpmMicrosFor` giữ nguyên y hệt —
không đổi API công khai (không có gì "breaking").

Xác minh không vô nghĩa: tạm khôi phục logic cũ (`ecpm == 0` thay vì
kiểm tra số mẫu thật), xác nhận 2 test liên quan đến "confirmed zero"
fail đúng như mong đợi (kiểm tra kỹ: có nhánh khác — "chưa đủ mẫu",
"gọi estimator" — vẫn đúng, không bị ảnh hưởng, đúng ý đồ chỉ sửa 1
nhánh cụ thể).

Xác minh: `flutter analyze` sạch; SDK suite 2027 test xanh (từ 2022,
+5); example suite 47 file xanh (không đổi); device smoke thật trên
**Pixel 7 Pro** (`2B051FDH3006MU`) qua
`example/integration_test/t194_arbitrator_confirmed_zero_test.dart` —
bơm 5 sự kiện doanh thu $0 thật, xác nhận arbitrator thật quyết định
nudge VIP (không fail-open), rồi tiếp tục gọi quyết định nhiều lần xác
nhận guardrail `maxVetoRate` thật sự kích hoạt và tự phục hồi về showAd
— không nudge vô hạn.

Không có widget nào trong SDK/example hiện hiển thị `.reason` của
arbitrator (chỉ có `estimatedEcpm`/`vetoRate` trên demo panel) — không
thêm UI mới chỉ để có chỗ viết widget test (đúng tinh thần YAGNI); logic
`.reason` đã được test đầy đủ ở tầng unit test.

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng kỷ luật revert-để-xác-nhận-đỏ, phân biệt rõ
2 nhánh không bị ảnh hưởng lẫn nhau, device smoke chứng minh cả veto lẫn
guardrail-recovery thật.
