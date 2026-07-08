# T22 — `AdScreenState.showRewardedAd()` thiếu disclosure hook cho reward

- **REQ:** 3, 7 (đúng pháp lý theo loại ad)
- **Priority:** P2 · **Severity:** LOW · **Status:** todo
- **Nguồn:** `doc/audit/audit_gemini.md` — audit pháp lý theo loại ad (round mới, 2026-07-08)
- **Files dự kiến:** `packages/ad_sdk/lib/src/core/ad_screen.dart` (`showRewardedAd`), có thể thêm 1 widget nhỏ tái dùng pattern của `vip_redeem_screen.dart`

## Vấn đề (Why)

`vip_redeem_screen.dart` (SDK-owned) đã disclosure đúng chuẩn trước khi xem quảng cáo thưởng: tiêu đề, badge "FREE", subtitle nêu rõ phần thưởng, nút "Watch ad" tường minh — đúng policy AdMob/AppLovin yêu cầu user biết trước phần thưởng là gì và việc xem là tự nguyện.

Nhưng helper generic `AdScreenState.showRewardedAd()` (dùng cho bất kỳ host screen nào muốn dùng rewarded ngoài VIP flow) đi thẳng từ `onPressed` → `AdLoadingDialog.showAdBuffer` → native ad, KHÔNG có bước disclosure nào. Hiện tại không phải bug (host app chỉ dùng rewarded qua VIP screen, đã disclosure đúng), nhưng là gap thật nếu sau này có host screen mới gọi thẳng `showRewardedAd()` mà quên tự viết disclosure.

## Fix đề xuất

Thêm optional param cho `showRewardedAd()` (ví dụ `rewardDescription`/`onShowDisclosure` callback), hoặc 1 widget nhỏ `RewardedAdDisclosureSheet` tái dùng copy pattern của `vip_redeem_screen.dart`, để integrator mới có disclosure "miễn phí" thay vì phải tự nhớ viết.

## Acceptance criteria
- [ ] `showRewardedAd()` có optional disclosure path (không breaking API cũ — param optional, default giữ nguyên behavior).
- [ ] Test mới xác nhận disclosure hiển thị trước khi gọi native ad khi param được truyền.
- [ ] `flutter analyze` sạch, test SDK xanh.
