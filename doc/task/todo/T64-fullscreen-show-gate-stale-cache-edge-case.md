# T64 — `canShowInterstitial`/`canShowRewardedAd` không re-check consent/network sau khi ad đã cache

- **REQ:** audit round mới 2026-08-15 (codex, đã verify độc lập — PLAUSIBLE, phạm vi hẹp hơn báo cáo gốc)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:2342-2351,2632`

## Vấn đề (Why)
Verified: `canShowInterstitial()`/`canShowRewardedAd()` check VIP, `isShowing`, `AdLoadingDialog.isShowing`, `AdSafetyConfig.canShowFullscreenAd()` (cap/cooldown) và `slot.isReady`, nhưng KHÔNG check `canRequestAds`/connectivity trực tiếp. Gap thật chỉ xảy ra khi consent bị revoke hoặc mất mạng SAU KHI ad đã load xong và cache sẵn — không phải "luôn thiếu check" như nhận định gốc, vì `isReady==true` thường ngụ ý consent/network đã ổn tại thời điểm load. Tần suất hiếm.

## Đề xuất
Cân nhắc thêm check nhẹ `canRequestAds` trước khi show nếu muốn siết chặt edge case này (revoke consent giữa lúc ad đã cache và lúc show). Ưu tiên thấp.

## Acceptance criteria
- [ ] (Nếu làm) test: ad đã load+ready, consent bị revoke trước khi show → `canShowInterstitial`/`canShowRewardedAd` trả `false`.
