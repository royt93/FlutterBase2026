# T89 — Ý tưởng: Hỗ trợ định dạng Rewarded Interstitial Ad

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** ✅ done (AdMob only — AppLovin không có định dạng này)
- **Files:** (mới) tương tự `lib/src/adapters/*` interstitial/rewarded hiện có

## Ý tưởng
Cả AdMob và AppLovin MAX đều hỗ trợ "Rewarded Interstitial" — quảng cáo xen kẽ có thưởng xuất hiện ở bước chuyển tự nhiên, không ép user chủ động bấm xem. Tăng eCPM mà không gây khó chịu UX như rewarded thuần.

## Việc cần làm (đề xuất, chưa code)
- [x] Thêm ad type mới song song `showInterstitial`/`showRewardedAd`, dùng chung safety layer/gate/cooldown đã có.
- [x] Wire cả 2 adapter (AdMob `RewardedInterstitialAd`, AppLovin MAX tương đương).

## Đã làm (2026-08-16) — phát hiện quan trọng khi verify

**Verify trước khi code (đúng thói quen session này):** kiểm tra source thật `applovin_max` package (4.6.4) — KHÔNG có bất kỳ class/API nào tên "Rewarded Interstitial" hay tương đương. AppLovin MAX chỉ có Interstitial và Rewarded như 2 loại riêng biệt, không có định dạng lai thứ 3. Claim gốc của ticket ("Cả AdMob và AppLovin MAX đều hỗ trợ") **SAI một nửa** — chỉ AdMob (`google_mobile_ads`) có `RewardedInterstitialAd` thật.

**Quyết định scope:** implement ĐẦY ĐỦ cho AdMob, AppLovin implement như no-op có tài liệu rõ ràng (đúng pattern đã dùng cho `preloadNative`/`templateType` trước đó trong session này) — không giả vờ hỗ trợ 1 tính năng network không có.

**Thiết kế:** `AdSlotType.rewardedInterstitial` (enum value mới) + `AdMobConfig.rewardedInterstitialId` (kèm android/iOS override, đúng convention các ad type khác) + `AdProviderAdapter.rewardedInterstitialSlot/loadRewardedInterstitial()/showRewardedInterstitial()`. Gate ở tầng `AdManager` mirror `showInterstitial()` (không phải `showRewardedAd()`) — **cố tình bỏ VIP-bypass-to-extend-VIP và SSV params**: đây là ad hiển thị ở natural transition, không phải hành động chủ động "bấm xem để nhận thưởng" của user, nên 2 tính năng đó (thiết kế riêng cho consent/xác thực 1 hành động CHỦ ĐỘNG) không phù hợp ngữ nghĩa.

`GmaBridge`/`RealGmaBridge` thêm `loadRewardedInterstitial` mirror `loadRewarded` gần như nguyên vẹn (Google's `RewardedInterstitialAd.load`/`.show` API giống hệt `RewardedAd`). `AdMobAdapter` implement đầy đủ (load/show/dispose/reset, watchdog tái dùng helper T76). `AppLovinAdapter` no-op documented — slot không bao giờ rời `idle`.

TDD: `admob_behavioral_test.dart` (5 test adapter-level: load success/fail, earn/dismiss/no-load), `ad_manager_core_test.dart` (6 test AdManager-level: gate VIP/consent cho cả load lẫn show, success path emit event + reload, AppLovin no-op thật sự không làm gì).

README + CHANGELOG cập nhật đầy đủ, giải thích rõ tại sao thiếu VIP-bypass/SSV so với `showRewardedAd`.

`flutter test`: 771/771 pass (2 lần), `flutter analyze` sạch.
