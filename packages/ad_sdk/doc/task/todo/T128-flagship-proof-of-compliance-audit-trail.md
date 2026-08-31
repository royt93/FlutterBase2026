# T128 — Flagship: Proof-of-compliance — audit trail ký số cho mọi lần bypass safety

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/compliance/compliance_signing.dart` (tái dùng hạ tầng ký), `lib/src/core/ad_manager.dart` (nơi `bypassSafety`/`bypassVipGuard` được đọc)

## Vấn đề

SDK đã có hạ tầng Ed25519 dùng cho VIP key (T18/AVP2), VIP revocation (T95), compliance report (T96) — nhưng chính các "cửa hậu" hợp pháp (`bypassSafety: true`, `bypassVipGuard: true`, `dryRun`) hiện chỉ là boolean trần, không kiểm chứng được SAU KHI build đã ship rằng chúng chỉ được gọi đúng nơi SDK cho phép (splash app-open, VIP-extend rewarded) chứ không bị lạm dụng để cày impression. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Mỗi lần `bypassSafety`/`bypassVipGuard` được gọi: ghi 1 record (timestamp, call-site tag do host truyền vào, kết quả) vào ring buffer
- [ ] Cuối phiên (hoặc theo lịch) xuất ra 1 file ký Ed25519 bằng CHÍNH private key host đã dùng cho compliance report (T96)
- [ ] Verify bằng tool CLI tương tự `tool/vip_mint.dart`/verifier đã có
- [ ] Hoàn toàn offline
- [ ] Test: bypass được gọi → record đúng; file xuất ra verify chữ ký đúng; giả mạo record → verify fail
