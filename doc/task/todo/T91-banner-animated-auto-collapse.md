# T91 — Ý tưởng: Animated auto-collapse banner khi no-fill

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart`

## Ý tưởng
Khi banner không tải được hoặc đang cooldown, layout giật hoặc để trống làm giảm trải nghiệm (CLS). Thêm transition thu gọn mượt mà giữ giao diện chuyên nghiệp hơn `SizedBox.shrink()` đột ngột.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thêm `AnimatedSize`/`AnimatedContainer` wrap quanh state chuyển đổi có/không có banner.
