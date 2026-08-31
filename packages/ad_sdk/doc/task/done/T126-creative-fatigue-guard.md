# T126 — Idea: Creative fatigue guard on-device

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/core/ad_safety_config.dart`, `lib/src/core/ad_manager.dart`, `test/ad_safety_config_test.dart`

## Vấn đề

Cap hiện đếm impression/click theo thời gian/placement nhưng không nhận biết 1 network/creative lặp quá dày gây UX xấu và CTR bất thường. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] Identifier: dùng thẳng `networkName`/`mediationWaterfall.first` — KHÔNG hash. Đây không phải dữ liệu nhạy cảm/PII (tên network mediation như "vungle"/"ironsource"), hash 1 chuỗi công khai không thêm bảo mật thật, chỉ làm khó debug. Ghi chú lệch khỏi checklist gốc, có lý do.
- [x] `AdSafetyConfig.recordNetworkShown(type, network)` + `isNetworkFatigued(type)` — rolling window (`networkFatigueWindowMs`, default 15 phút), threshold `maxSameNetworkShowsPerWindow` (default 4). Khi thiếu metadata (`network == null`): không ghi nhận gì — fail-open tuyệt đối, không có exposure history thì không bao giờ fatigue.
- [x] Không đụng click hay nội dung creative — chỉ cooldown việc LOAD lại (4 site: loadAppOpen/Interstitial/Rewarded/RewardedInterstitial), mirror đúng pattern `dailyCapReached()` đã có.
- [x] Test: 4 test mới (`test/ad_safety_config_test.dart`, group "T126") — ngưỡng đúng, fail-open khi thiếu metadata, không lẫn giữa các `AdSlotType`, `resetSession()` dọn sạch.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/creative_fatigue_guard_test.dart` — xác nhận params mới type-check + default (999, tắt) không chặn `canShowInterstitial()` thật. Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.
