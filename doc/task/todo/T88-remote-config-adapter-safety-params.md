# T88 — Ý tưởng: Remote Config adapter cho `AdSafetyParams` + dynamic ad unit ID

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/config/ad_safety_config.dart`, `packages/ad_sdk/lib/src/config/ad_config.dart`

## Ý tưởng
Tham số an toàn (tần suất, giới hạn ngày/giờ) và Ad Unit ID hiện cứng trong code client. Cung cấp interface cắm Remote Config (Firebase Remote Config hoặc custom API tự host) giúp publisher điều chỉnh chiến lược kiếm tiền từ xa mà không cần submit bản cập nhật App Store/Google Play.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thiết kế interface abstract (không ép buộc Firebase cụ thể) cho `AdSafetyParams`/ad unit ID provider.
- [ ] SDK tự áp dụng giá trị mới khi provider trả về, có validate + fallback về giá trị local nếu remote lỗi/không có mạng.
