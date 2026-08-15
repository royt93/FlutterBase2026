# T89 — Ý tưởng: Hỗ trợ định dạng Rewarded Interstitial Ad

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** (mới) tương tự `lib/src/adapters/*` interstitial/rewarded hiện có

## Ý tưởng
Cả AdMob và AppLovin MAX đều hỗ trợ "Rewarded Interstitial" — quảng cáo xen kẽ có thưởng xuất hiện ở bước chuyển tự nhiên, không ép user chủ động bấm xem. Tăng eCPM mà không gây khó chịu UX như rewarded thuần.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thêm ad type mới song song `showInterstitial`/`showRewardedAd`, dùng chung safety layer/gate/cooldown đã có.
- [ ] Wire cả 2 adapter (AdMob `RewardedInterstitialAd`, AppLovin MAX tương đương).
