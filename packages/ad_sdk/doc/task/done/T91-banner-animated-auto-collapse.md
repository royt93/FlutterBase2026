# T91 — Ý tưởng: Animated auto-collapse banner khi no-fill

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart`

## Ý tưởng
Khi banner không tải được hoặc đang cooldown, layout giật hoặc để trống làm giảm trải nghiệm (CLS). Thêm transition thu gọn mượt mà giữ giao diện chuyên nghiệp hơn `SizedBox.shrink()` đột ngột.

## Việc cần làm (đề xuất, chưa code)
- [x] Thêm `AnimatedSize`/`AnimatedContainer` wrap quanh state chuyển đổi có/không có banner.

## Đã làm (2026-08-16)
Wrap `build()`'s toàn bộ subtree trong 1 `AnimatedSize` duy nhất (thay vì sửa từng điểm `SizedBox.shrink()` riêng lẻ — có ~6 điểm khác nhau trong `_buildAdmob()`/`_buildAppLovin()`, wrap 1 lần ở ngoài cùng cover hết, DRY hơn). Thêm param `collapseAnimationDuration` (default 250ms), `Duration.zero` để tắt animation hoàn toàn.

**Bug thật phát hiện khi TDD:** truyền `Duration.zero` thẳng cho `AnimatedSize` gây lỗi framework thật ("A RenderAnimatedSize was mutated in its own performLayout implementation") — `AnimationController` 0-length có thể hoàn tất NGAY TRONG cùng 1 layout pass, gây re-entrant `markNeedsLayout()`. Fix: khi `duration == Duration.zero`, bỏ qua hẳn `AnimatedSize`, trả `child` trực tiếp — không truyền `Duration.zero` vào `AnimatedSize` bao giờ.

TDD: 2 test mới — collapse thật sự animate (kiểm tra height nằm GIỮA 0 và height đã load tại 1 frame giữa chừng, không nhảy thẳng), và `Duration.zero` vẫn ra đúng kết quả cuối (không animation, không throw).

`flutter test`: 790/790 pass (2 lần), `flutter analyze` sạch.
