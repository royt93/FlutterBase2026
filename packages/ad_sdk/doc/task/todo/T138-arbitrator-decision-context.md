# T138 — Enhancement: MonetizationArbitrator trả về lý do quyết định (DecisionContext)

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** M
- **Files (dự kiến):** `lib/src/monetization/monetization_arbitrator.dart`
- **Nguồn gợi ý:** codex + agy đồng thuận
- **Dependency:** không

## Vấn đề

**Sửa lại premise ban đầu sau khi đọc code thật — brainstorm gốc SAI 1 phần:**
`monetization_arbitrator.dart:87-101` cho thấy đa tiền tệ **ĐÃ được xử lý
đúng** — mẫu eCPM được bucket riêng theo `'<slot>|<currency>'`
(`_bucketKey`, dòng 104), và dòng 99-101 tự ghi rõ lý do: "a stray event in
another currency cannot be averaged in with it". **Không cần sửa phần đa
tiền tệ — bỏ khỏi scope ticket này.**

Phần còn lại của premise gốc ĐÚNG: `decide(AdSlotType slot)` (dòng 249) trả
về `ArbitratorDecision` — 1 **enum chỉ 2 giá trị** (`showAd` / `nudgeVip`,
dòng 10-15), không mang theo bất kỳ lý do nào (ngưỡng eCPM nào bị vi phạm,
guardrail veto-rate có đang trip không — dòng 68-72, hay do
likelihood-signal host cung cấp thấp). Host gọi `decide()` chỉ biết
"show hay không show", không biết TẠI SAO — gây khó debug/quan sát khi
muốn hiểu vì sao 1 slot bị veto liên tục.

## Việc cần làm

- [ ] Giữ nguyên `enum ArbitratorDecision` (đang được so sánh trực tiếp ở
      nhiều nơi trong `ad_manager.dart:6468/6788/7081` — đổi type trả về
      của `decide()` sẽ break các call site này, phải xử lý cẩn thận).
- [ ] Thêm method MỚI song song, không đổi `decide()` hiện có — ví dụ
      `ArbitratorDecisionDetail decideWithContext(AdSlotType slot)` trả về
      1 class mới:
      ```dart
      class ArbitratorDecisionDetail {
        final ArbitratorDecision decision;
        final String reason; // "trailing eCPM below threshold", "guardrail: veto-rate exceeded", "likelihood signal too low", ...
        final double trailingEcpm;
        final double threshold;
        final bool guardrailTripped;
      }
      ```
      Implement bằng cách tái dùng logic `decide()` hiện có (refactor
      phần lõi thành 1 private method trả về context đầy đủ, rồi cả
      `decide()` (giữ nguyên chữ ký cũ) và `decideWithContext()` đều gọi
      qua đó — KHÔNG lặp code, KHÔNG duplicate logic).
- [ ] `decide()` cũ vẫn hoạt động y hệt — test hồi quy đảm bảo không đổi
      behavior của các call site hiện có trong `ad_manager.dart`.
- [ ] Cập nhật README's Monetization Arbitrator section (nếu có ví dụ code
      dùng `decide()`) thêm 1 đoạn ngắn giới thiệu `decideWithContext()`
      cho ai muốn debug/log lý do quyết định.

## Ghi chú

Effort M vì về bản chất chỉ là refactor-and-extend (tách logic quyết định
ra 1 hàm chung, thêm 1 lớp kết quả mới), không đổi kiến trúc — miễn là
KHÔNG đổi chữ ký `decide()` hiện có (breaking change không cần thiết, đã
có 3 call site production đang dùng enum trực tiếp).

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T138-arbitrator-decision-context.md này (nếu đã
chuyển sang inprogress/ hoặc done/ thì đọc ở đó). Implement ĐÚNG scope mô tả
trong "Việc cần làm" — KHÔNG thêm scope ngoài mô tả. Phần "đa tiền tệ" đã bị
loại khỏi scope (đã xác nhận code hiện tại xử lý đúng) — đừng động vào
`_bucketKey`/currency logic trừ khi tự phát hiện bug thật khác, và nếu vậy
hãy dừng lại báo user trước.

SDK này KHÔNG có backend/server riêng — ticket này thuần refactor nội bộ,
không liên quan remote config.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R
nguyên khối tránh ENOSPC) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
