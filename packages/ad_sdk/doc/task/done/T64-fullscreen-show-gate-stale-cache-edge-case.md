# T64 — `canShowInterstitial`/`canShowRewardedAd` không re-check consent/network sau khi ad đã cache

- **REQ:** audit round mới 2026-08-15 (codex, đã verify độc lập — PLAUSIBLE, phạm vi hẹp hơn báo cáo gốc)
- **Priority:** P2 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`canShowInterstitial`, `canShowRewardedAd`), `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
Verified: `canShowInterstitial()`/`canShowRewardedAd()` check VIP, `isShowing`, `AdLoadingDialog.isShowing`, `AdSafetyConfig.canShowFullscreenAd()` (cap/cooldown) và `slot.isReady`, nhưng KHÔNG check `canRequestAds`/connectivity trực tiếp. Gap thật chỉ xảy ra khi consent bị revoke hoặc mất mạng SAU KHI ad đã load xong và cache sẵn — không phải "luôn thiếu check" như nhận định gốc. Tần suất hiếm, nhưng đây là vấn đề tuân thủ pháp lý (GDPR consent revoke phải chặn hiển thị ad ngay, kể cả ad đã cache) nên vẫn đáng làm dù ưu tiên P2.

## Đã làm (2026-08-15, TDD)
Thêm `if (!canRequestAds) return false;` vào cả 2 hàm. Với `canShowRewardedAd()`, đặt SAU nhánh `_isVipMember` (giữ nguyên quirk có chủ đích "VIP luôn true, chỉ gate UI cho nút watch-to-extend, quyết định thật nằm ở `vipAutoGrant`" — không đụng, ngoài scope). Viết test trước (RED: ready+consent hợp lệ → true; revoke consent → vẫn cache-ready nhưng phải false), fix, GREEN. `flutter test`: 711/711 pass, `flutter analyze` sạch.

## Acceptance criteria
- [x] Test: ad đã load+ready, consent bị revoke trước khi show → `canShowInterstitial`/`canShowRewardedAd` trả `false`.
- [x] Quirk VIP-bypass của `canShowRewardedAd()` không bị đổi hành vi.
