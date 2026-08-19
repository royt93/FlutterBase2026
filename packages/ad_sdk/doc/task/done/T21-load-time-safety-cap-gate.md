# T21 — Preload/load không check daily/hourly safety cap → phí request

- **REQ:** 3, 7 (đúng vòng đời, không rủi ro; policy tuân thủ) + audit mới "minimize request / maximize fill rate"
- **Priority:** P2 · **Severity:** MEDIUM · **Status:** done
- **Nguồn:** `doc/audit/audit_gemini.md` — audit request-minimization vs fill-rate (round mới, 2026-07-08)
- **Files dự kiến:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`_retryRefillAds`, `loadInterstitial`/`loadRewardedAd`/`loadAppOpenAd`), `packages/ad_sdk/lib/src/config/ad_safety_config.dart` (thêm helper mới)

## Vấn đề (Why)

`AdSafetyConfig.canShowFullscreenAd()` (throttle + session/hour/day cap) chỉ được gọi ở **show time** (`ad_manager.dart` tại các lệnh gọi `showInterstitial`/`showRewardedAd`/`showAppOpenAd`), KHÔNG được gọi ở **load time**. `loadInterstitial()`/`loadRewardedAd()`/`loadAppOpenAd()` chỉ check VIP/consent/connectivity, không check safety cap.

Hệ quả: user đã đạt `maxFullscreenAdsPerDay`/`maxFullscreenAdsPerHour` vẫn bị SDK tiếp tục preload (qua `_retryRefillAds` mỗi 5 phút + reload sau mỗi lần show) — tốn request ad không bao giờ có thể show được trong phần còn lại của giờ/ngày đó. Ngược hẳn mục tiêu "tối thiểu request, tối đa fill rate".

## Fix đề xuất

Thêm helper read-only trên `AdSafetyConfig` (ví dụ `dailyCapReached()`, tách khỏi `canShowFullscreenAd()` vì hàm đó còn tính throttle/CTR — không cần thiết ở load time). Gọi check này ở:
- `AdManager._retryRefillAds()` — skip loadX nếu đã cap ngày.
- Từng `loadX()` (`loadInterstitial`/`loadRewardedAd`/`loadAppOpenAd`) — skip sớm nếu `!_isVipMember && AdSafetyConfig.dailyCapReached()`, log `SafeLogger.d` tương tự các skip-log khác.

Chỉ cần check cap **ngày** (tín hiệu rẻ nhất, bền nhất qua `AdPreferences.getDailyAdCount()`) — không cần replicate toàn bộ throttle/hour/CTR logic ở load time.

## Acceptance criteria
- [x] `AdSafetyConfig.dailyCapReached()` mới, không đổi behavior của `canShowFullscreenAd()`.
- [x] `_retryRefillAds` + 3 `loadX()` skip đúng khi đã cap ngày (không VIP).
- [x] VIP member không bị ảnh hưởng (không check cap khi `_isVipMember`).
- [x] Test mới: cap ngày đạt → loadX không gọi adapter; VIP → vẫn load bình thường dù cap ngày (`test/daily_cap_load_gate_test.dart` +3, `test/ad_safety_config_test.dart` +2).
- [x] `flutter analyze` sạch, test SDK xanh.
