# T130 — Flagship: Token chuyển VIP sang máy mới (ký offline, 1 lần dùng)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** 🔲 todo
- **Files:** `lib/src/vip/signed_vip_key.dart` (tái dùng scheme ký sẵn có), `lib/src/vip/vip_manager.dart`, `lib/src/vip/_redeemed_key_ledger.dart`

## Vấn đề

README tự công bố giới hạn: Android không có anti-reinstall bền vững, "clear app data" hoặc đổi máy làm mất VIP. Thay vì chỉ coi đây là rủi ro cần chấp nhận: user chủ động export 1 token ký Ed25519 (dùng CHÍNH private key app, không phải public key VIP) chứa thời gian VIP còn lại + danh sách `kid` đã dùng, TRƯỚC KHI gỡ cài đặt/đổi máy; máy mới verify token offline và áp lại đúng số ngày còn lại, 1 lần dùng.

## Việc cần làm

- [ ] API export token (ký Ed25519, chứa remaining-VIP-time + used-kid-list)
- [ ] API import: verify offline, áp lại VIP, tự thêm token's kid vào `_redeemed_key_ledger` như đã tiêu (chống dùng lại)
- [ ] Vẫn 1 lần dùng, vẫn cần hành động chủ động của user trước khi mất dữ liệu cũ (không làm yếu anti-abuse)
- [ ] Test: export→import đúng thời gian còn lại; import lại token đã dùng → từ chối

## Ghi chú

Priority P3 — chưa xác nhận độ ưu tiên trực tiếp với user (hết slot câu hỏi), để mặc định theo BACKLOG doc.
