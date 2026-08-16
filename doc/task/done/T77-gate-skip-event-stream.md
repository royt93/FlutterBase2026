# T77 — Event stream cho gate/skip decision (`AdGateEvent`/`AdSkipEvent`) thay vì chỉ log text

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:2271,2302,2981`, `packages/ad_sdk/lib/src/event/ad_event.dart`

## Vấn đề (Why)
Quyết định gate/skip (vd VIP suppress, cap chặn, cooldown) hiện chỉ đi qua `SafeLogger`. App muốn audit funnel/dashboard phải tự parse log text.

## Đề xuất
Emit structured event (`AdGateEvent`/`AdSkipEvent`) vào event stream đã có sẵn, kèm lý do skip.

## Acceptance criteria
- [x] Mỗi lần gate/skip 1 ad, event tương ứng được emit với đủ context (loại ad, lý do).
- [x] Test xác nhận event emit đúng cho từng lý do skip chính (VIP, cap, cooldown, consent).

## Đã làm (2026-08-16)
Thêm `AdSkipEvent extends AdEvent` (`lib/src/state/ad_event.dart`) — field `action` ('load'/'show') + `reason` (machine-readable: 'vip', 'daily_cap', 'consent', 'no_network', 'adapter_null', 'busy', 'cooldown', 'splash_only_inactive', 'resume_only_trigger'). `AdEvent` là `sealed class` nên Dart compiler tự bắt buộc cập nhật switch exhaustive còn thiếu ở `_eventExtra()` (ad_event_log.dart) — không thể quên serialize field mới.

Emit `_emitSkip(...)` (helper mới) tại MỌI điểm skip hiện có (giữ nguyên `SafeLogger.d` cũ, thêm emit ngay cạnh) trong `loadInterstitial`/`loadRewardedAd`/`loadAppOpenAd` (load-side: adapter_null/vip/daily_cap/consent/no_network + splash_only cho appOpen) và `showInterstitial`/`showRewardedAd`/`showAppOpenAd` (show-side: adapter_null/vip/consent/busy/cooldown). KHÔNG đụng vào `MonetizationArbitrator`'s veto path — đã có `ArbitratorNudgeEvent` riêng, tránh double-emit trùng ý nghĩa. KHÔNG emit trong `canShowInterstitial()`/`canShowRewardedAd()` (predicate thuần, host có thể poll liên tục để cập nhật UI — emit ở đó sẽ spam event stream sai mục đích "funnel dashboard").

TDD: 4 test mới `ad_manager_core_test.dart` — VIP/daily_cap/consent (load) + cooldown thật (show, kích hoạt qua click-spam suspicious pause). Lộ 2 vấn đề khi chạy full suite: (1) `AdPreferences.getInstance()` là singleton cache xuyên suốt cả file test khổng lồ — thêm `AdPreferences.resetForTest()` vào setUp; (2) broadcast `StreamController` không đồng bộ — listener nhận event ở microtask sau, cần `await Future<void>.delayed(Duration.zero)` sau mỗi action trước khi assert.

`flutter test`: 748/748 pass (chạy 3 lần xác nhận hết flaky), `flutter analyze` sạch.
