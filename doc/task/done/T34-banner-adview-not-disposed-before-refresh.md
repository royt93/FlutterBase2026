# T34 — Banner native AdView chưa dispose trước khi refresh/reconnect

- **REQ:** 3 (vòng đời, no memory leak)
- **Priority:** P2 · **Severity:** LOW · **Status:** ✅ done (2026-07-13, T12 partial → complete)
- **Files:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart` (dòng ~970-977)

## Vấn đề (Why)
Path refresh/resume-recovery (khi mạng reconnect, `_retryRefillAds` gọi `preloadBanner()` lại) chỉ null hoá reference rồi preload mới — **không** dispose tường minh native `AdView` cũ trước đó. Dispose thật chỉ xảy ra ở `dispose()` toàn adapter (teardown hoàn toàn). Nếu 1 session có nhiều chu kỳ mất mạng/có mạng lại, có thể tích tụ native view chưa giải phóng.

## Giải pháp đề xuất
Gọi dispose native view cũ (nếu tồn tại) trước khi gán reference mới trong path preload-lại, tương tự pattern đã làm đúng ở `dispose()` toàn phần.

## Acceptance criteria
- [ ] Refresh/reconnect banner nhiều lần trong 1 session không tích native view leak (verify qua counter mock hoặc theo dõi native call `destroy`/`dispose` được gọi đúng số lần preload).

## Test
Mở rộng `connectivity_resilience_test.dart` hoặc `banner_leak_regression_test.dart`: simulate offline→online nhiều vòng, assert dispose native view được gọi đúng 1 lần mỗi vòng trước khi preload mới.

## Kết quả
Phạm vi thực tế hẹp hơn mô tả gốc: path cần sửa là `onAppResumed()` (recreate banner lỗi khi app resume), không phải toàn bộ path reconnect qua `_retryRefillAds`. Thêm `unawaited(_bridge.destroyWidgetAdView(oldId).catchError(...))` trước `preloadBanner()`, giữ nguyên signature `void onAppResumed()` (không đổi thành async). Test mới `group('onAppResumed() recreates errored banner AdView (T34)')` trong `applovin_adapter_test.dart` dùng `FakeAppLovinBridge` (thêm `destroyWidgetAdViewCalls` tracking list) xác nhận `destroyWidgetAdView` được gọi đúng 1 lần với `oldId` cũ trước khi preload.

## Giới hạn đã biết
`destroyWidgetAdView` gọi qua `unawaited` (fire-and-forget) — nếu native call thất bại chỉ log warning, không retry, không block đường preload mới (chấp nhận được vì đây là dọn dẹp best-effort, không phải correctness-critical path).
