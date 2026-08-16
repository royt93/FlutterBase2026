# T92 — Ý tưởng: Per-placement safety cap (không chỉ global)

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/config/ad_safety_config.dart`

## Ý tưởng
Cap hiện tại (daily/hourly/session) áp dụng toàn cục theo loại ad, không phân biệt placement (vd splash vs sau khi hoàn thành 1 tác vụ trong app). Cho phép cap riêng theo placement giúp host tinh chỉnh UX chi tiết hơn mà không phải tắt cap toàn SDK.

## Việc cần làm (đề xuất, chưa code)
- [x] Thiết kế API cấu hình cap theo `placement` (string/key tự đặt) song song cap global hiện có.

## Đã làm (2026-08-16)

**Thiết kế:** `AdSafetyParams.maxPerPlacementAdsPerDay` (`Map<AdPlacement, int>?`, mặc định `null` = tắt hoàn toàn, tương thích ngược 100%). Check ở tầng `AdManager`'s 4 hàm show (`showInterstitial`/`showRewardedAd`/`showRewardedInterstitialAd`/`showAppOpenAd`) NGAY SAU check cooldown global hiện có — LUÔN kèm thêm, không bao giờ thay thế cap global. `AppOpen` tôn trọng `bypassSafety` giống cap global (bypass toàn bộ hay không, không nửa vời).

Persistence: `AdPreferences.getPlacementDailyCounts()`/`incrementPlacementDailyCount()` — mirror đúng pattern day-rollover đã có sẵn cho counter global (`getDailyAdCount`/`incrementDailyAdCount`), lưu 1 blob JSON keyed theo `placement.id` (string tự đặt bởi host, không cần scheme key-động-per-placement phức tạp).

**Phát hiện thật khi TDD (không chỉ về mặt logic, mà về ngôn ngữ Dart):** `AdPlacement` override `==`/`hashCode` (custom equality) → Dart CẤM dùng làm key trong CONST map literal (const map cần key có primitive identity). Nghĩa là `const AdSafetyParams(maxPerPlacementAdsPerDay: {...})` KHÔNG COMPILE ĐƯỢC — ảnh hưởng thật đến cách host dùng field mới này (không chỉ test của tôi). Đã ghi rõ trong dartdoc field + README + CHANGELOG, tránh host gặp lỗi compiler khó hiểu.

TDD: 3 test thuần logic (`ad_safety_config_test.dart` — không cap thì không chặn, đạt cap thì chặn ĐÚNG placement đó không ảnh hưởng placement khác, sống sót qua "restart"). 1 test AdManager-level (`ad_manager_core_test.dart`, nhóm T77 sẵn có — đạt cap → emit `AdSkipEvent(reason: 'placement_cap')`, placement khác không bị ảnh hưởng, vẫn show bình thường).

`flutter test`: 794/794 pass (2 lần), `flutter analyze` sạch.
