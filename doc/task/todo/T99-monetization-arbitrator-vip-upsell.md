# T99 — Flagship: Smart Monetization Arbitrator → VIP upsell nudge khi ad value thấp (sau khi T58 fix đơn vị eCPM)

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng flagship, phụ thuộc T58) — **BLOCKED bởi T58**
- **Files:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`

## Vì sao độc quyền
Thay vì hiển thị 1 ad giá trị thấp cho user tiềm năng cao, Arbitrator (sau khi T58 fix đơn vị eCPM) có thể chủ động phân tích eCPM thực tế + tín hiệu chuyển đổi để từ chối ad rẻ tiền và gợi ý user nâng cấp VIP — tối ưu ARPU. Đây là hướng phát triển tiếp của tính năng arbitrator đã có, không phải xây từ đầu.

## Việc cần làm (đề xuất, chưa code — chờ T58 xong trước)
- [ ] Sau khi T58 fix đơn vị, thiết kế hook `onLowValueAdVetoed` để app tự hiển thị nudge VIP (SDK không tự vẽ UI, chỉ emit tín hiệu).
