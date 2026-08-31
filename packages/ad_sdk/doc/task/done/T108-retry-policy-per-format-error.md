# T108 — Enhancement: Retry policy cấu hình theo format + loại lỗi

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `lib/src/state/ad_retry_policy.dart` (mới), `state/ad_slot.dart`, 2 adapter (4 site AdMob + 3 site AppLovin), `core/ad_manager.dart` (`_retryRefillAds`), `lib/applovin_admob_sdk.dart`, test `test/ad_retry_policy_test.dart` (mới)

## Vấn đề

SDK đã có `Backoff` và watchdog nhưng chủ yếu dùng 1 policy chung; no-fill, network, invalid-request và timeout có ý nghĩa khác nhau. [đồng thuận 3 nguồn]

## Việc đã làm

- [x] `AdRetryPolicy` (lib/src/state/ad_retry_policy.dart): `backoff` (tái dùng `Backoff` sẵn có), `jitterFraction` (0..1, seed ổn định từ `lastErrorAt`+`consecutiveFailures` — không re-roll mỗi lần check, tránh flip-flop), `isRetryable(int? errorCode)` classifier, `resetOnConnectivityRestored`
- [x] `AdSlot` (state/ad_slot.dart): thêm `lastErrorCode` (int?, set qua `markFailed({int? errorCode})` — default null nên MỌI call site cũ giữ nguyên), `retryPolicy` (mutable, default null). `beginLoad()` dùng `retryPolicy.canRetryNow(...)` khi có, fallback `Backoff.isInCooldown` khi không — default KHÔNG đổi hành vi. `reset()` clear thêm `lastErrorCode`. Thêm `clearCooldownOnReconnect()` (no-op trừ khi policy opt-in)
- [x] Wire `errorCode` vào 7 call site `markFailed()` thật sự có mã lỗi trong scope (4 AdMob: appOpen/interstitial/rewarded/rewardedInterstitial `onFailed: (code, ...)`; 3 AppLovin: appOpen/inter/rewarded `onAdLoadFailedCallback: (id, err)` → `err.code.value`). Nhánh `catch (e, st)` (lỗi Dart không có mã số) vẫn gọi `markFailed()` trần — đúng ý nghĩa "không phân loại được"
- [x] `AdManager._retryRefillAds()` gọi `clearCooldownOnReconnect()` cho 4 slot fullscreen trước khi xét load lại — closure thật cho `resetOnConnectivityRestored` (trước đây field này sẽ không có nghĩa gì nếu không có nơi gọi)
- [x] Export công khai: `AdRetryPolicy` (mới) + `Backoff` (T78, trước đây cố tình giấu — giờ cần vì `AdRetryPolicy.backoff` là constructor param public)
- [x] Default giữ nguyên hành vi hiện tại — non-breaking: `retryPolicy == null` mọi nơi trừ khi host tự set qua `AdManager().adapter?.interstitialSlot.retryPolicy = AdRetryPolicy(...)` (không cần thêm API mới trên `AdManager`/`AdConfig` — `adapter` getter + slot getter công khai sẵn có đã đủ, xem ghi chú)
- [x] Test (`test/ad_retry_policy_test.dart`, 11 test): default-behavior parity với `Backoff` thuần, `isRetryable` chặn/không chặn theo mã lỗi (kể cả path `errorCode: null`), jitter ổn định qua nhiều lần check + hướng jitter assert được qua `random` injectable, `resetOnConnectivityRestored` bật/tắt, `reset()` clear `lastErrorCode`. Full suite 1413→1424, không regression

## Ghi chú

- KHÔNG đụng `config/ad_config.dart` — ticket liệt kê file này nhưng hoá ra không cần: `AdSlot.retryPolicy` là field public, và `AdProviderAdapter`/`AdManager().adapter` đã expose slot getter công khai sẵn, nên host set policy trực tiếp trên slot instance sau `initialize()` mà không cần thêm tham số `AdConfig`/`AdManager` nào.
- Chỉ wire `errorCode` cho 4 slot fullscreen (appOpen/interstitial/rewarded/rewardedInterstitial) — banner/mrec/native dùng cơ chế watchdog khác (T108's Files list ban đầu không nhắc 3 loại này) và không nằm trong `_retryRefillAds`'s phạm vi hiện có.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/ad_retry_policy_test.dart` — gán `AdRetryPolicy` vào `AdManager().adapter.rewardedSlot` thật, xác nhận round-trip qua adapter thật (không chỉ `AdSlot` cô lập). Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.

**Xác nhận chạy thật trên thiết bị (2026-09-01):** pass trên emulator Pixel_10_Pro_XL và máy thật Samsung SM-S928B, `--dart-define=AD_PROVIDER_ADMOB=true`. Không phải chỉ `flutter analyze`.
