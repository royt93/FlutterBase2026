# P31 — Tính năng độc quyền: ISP Dispute Evidence Mode nâng cấp

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + claude CLI
- **Files liên quan (đã có sẵn):** `history_controller.dart:533` (`exportIspDisputeReport()`), hạ tầng Ed25519 verify (dùng cho VIP key, `packages/ad_sdk` — chỉ tái dùng nguyên lý ký số, không đụng code SDK)

## Ý tưởng
`exportIspDisputeReport()` đã tồn tại. Nâng cấp thành báo cáo đa tuần, đầy đủ timestamp, có thể **ký số tamper-evident** (tận dụng nguyên lý Ed25519 đã dùng cho VIP key — ký local, verify offline, không cần backend) để làm bằng chứng khiếu nại ISP đáng tin hơn (chứng minh dữ liệu không bị chỉnh sửa sau khi export).

## Việc cần làm (đề xuất, chưa code)
- Mở rộng `exportIspDisputeReport()` để nhận khoảng nhiều tuần (phụ thuộc P05 — sửa boundary date range trước).
- Thiết kế format ký số: hash nội dung report, ký bằng key riêng của app (KHÔNG dùng chung private key VIP — cần key riêng để tránh rủi ro bảo mật nếu 2 mục đích dùng chung 1 key), đính kèm signature + public key vào file export để người nhận verify độc lập.
- Quyết định format export cuối (PDF có ký số nhúng, hoặc file JSON/text + signature file riêng).

## Acceptance criteria
- [ ] Report gộp được dữ liệu nhiều tuần, không bị cắt ở boundary ngày.
- [ ] Report có signature xác minh được bằng public key đã công bố, phát hiện được nếu file bị chỉnh sửa sau khi export.
- [ ] Key ký report tách biệt hoàn toàn với private key Ed25519 dùng cho VIP (không tái sử dụng).
