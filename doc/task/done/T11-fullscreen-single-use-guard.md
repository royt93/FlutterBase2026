# T11 — Guard single-use: chống double-show ad đã dispose

- **REQ:** 3 (đúng vòng đời, no crash)
- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-07-05)

## Kết luận
Finding của agent là **false positive**: double-show đã được chặn sẵn bởi slot state machine (`isReady` + `beginShow()` atomic + null-on-dismiss + `_disposeAd` idempotent) ở CẢ AdMob và AppLovin adapter. Không cần đổi code. Đã thêm **regression test** (`admob_behavioral_test.dart` group "single-use / double-show guard", 2 case) khoá invariant: second-show-while-showing bị từ chối (shown 1 lần, không dispose ad sống); sau dismiss không tái dùng ad đã dispose. **269/269 test xanh.**
- **Files:** `adapters/admob_adapter.dart` (show/dispose interstitial & rewarded), `adapters/applovin_adapter.dart` (tương ứng), `core/ad_manager.dart` (`showInterstitial` `:1064`, `showRewardedAd` `:1196`)

## Vấn đề (Why)
Interstitial/Rewarded là one-shot: sau show → dispose + slot idle. Nhưng object không bị null-out ngay đầu `show()`. Cuộc gọi `show` thứ hai trong lúc callback dismiss chưa fire có thể `show()` trên object **đã dispose** → crash/undefined. (Rewarded có `_rewardedInFlight` che một phần; interstitial dựa `isShowing`.)

## Acceptance criteria
- [ ] Ngay khi bắt đầu show, chốt trạng thái (null-out object hoặc set field "showing") để cuộc gọi thứ hai bị từ chối an toàn.
- [ ] Sau dismiss/fail: dispose đúng object, slot về idle, preload cái mới (giữ hành vi hiện có).
- [ ] Không có đường dẫn nào `show()` được gọi trên object đã dispose (kể cả re-entrancy interstitial).
- [ ] Áp dụng đồng nhất cả AdMob và AppLovin adapter.

## Test
- [ ] Unit/adapter: gọi show 2 lần liên tiếp → lần 2 no-op, không dùng object đã dispose.
