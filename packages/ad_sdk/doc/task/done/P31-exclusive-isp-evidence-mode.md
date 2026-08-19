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

## Bổ sung (2026-08-11, audit vòng 2 — subagent + agy CLI)
2 nâng cấp thêm để cân nhắc khi thiết kế:
- Loại trừ (hoặc đánh dấu riêng) các test bị `thermalStatus` throttle nặng khi tính "% dưới tốc độ cam kết" — nếu không, report có thể bị phản bác vì máy nóng làm chậm chứ không phải ISP.
- Đính kèm QR code encode signature/public-key-fingerprint để người nhận verify nhanh bằng điện thoại, không cần công cụ riêng.

## Acceptance criteria
- [x] Report gộp được dữ liệu nhiều tuần, không bị cắt ở boundary ngày.
- [x] Report có signature xác minh được bằng public key đã công bố, phát hiện được nếu file bị chỉnh sửa sau khi export.
- [x] Key ký report tách biệt hoàn toàn với private key Ed25519 dùng cho VIP (không tái sử dụng).

## Kết quả (2026-08-13)
- **AC1 (đa tuần, không cắt boundary):** đã có sẵn từ trước (P39 sửa
  `getResultsByDateRange` thành inclusive 2 đầu mốc + `showDateRangePicker`
  cho chọn khoảng bất kỳ tới 2 năm) — không cần sửa gì thêm, chỉ xác nhận lại.
- **AC2 + AC3 (ký số tamper-evident, key riêng biệt):**
  `services/isp_report_signer.dart` (mới) — keypair Ed25519 tự sinh **trên
  máy** lần đầu dùng, lưu seed qua `SharedPreferences` (key
  `isp_report_signing_key_seed_v1`), hoàn toàn tách biệt khỏi hạ tầng VIP
  (VIP verify dùng public key hardcode sẵn trong `vip_keys.dart`; VIP mint
  dùng private key không nằm trong app) — dùng thư viện `cryptography` (cùng
  version `^2.9.0` đã dùng ở `packages/ad_sdk`, pure Dart không đụng native).
  - `generateIspDisputeReport()`: build 1 canonical text string deterministic
    (`ISP_DISPUTE_REPORT_V1` + mọi field + toàn bộ rows) TRƯỚC khi
    `doc.save()`, ký chuỗi đó, in cả public key + signature + hướng dẫn
    verify ngắn gọn vào cuối PDF.
  - Loại trừ (bổ sung theo audit vòng 2): test có `thermalStatus >=
    kThermalThrottleThreshold` (dùng chung ngưỡng với P56) bị loại khỏi mẫu
    tính "% dưới tốc độ cam kết" — kèm dòng chú thích số lượng bị loại.
  - Test: `test/p31_isp_report_signer_test.dart` (4 case: ký+verify roundtrip,
    phát hiện nội dung bị sửa, tái dùng đúng keypair đã lưu, từ chối verify
    với public key không khớp).

ponytail: chưa xuất kèm file JSON máy-đọc-được riêng để verify tự động (dù
ticket cho phép cả 2 hướng) — chữ ký + public key nhúng trực tiếp trong PDF
(dạng text), người nhận verify bằng cách gõ lại canonical string theo đúng
format đã ghi. Đủ để phát hiện tamper theo đúng AC, chưa build tool verify
tự động vì chưa có nhu cầu thực tế. Cũng chưa làm QR code encode signature
(gợi ý "Bổ sung", không nằm trong Acceptance Criteria) — thêm khi có yêu cầu
UX quét mã thật.
