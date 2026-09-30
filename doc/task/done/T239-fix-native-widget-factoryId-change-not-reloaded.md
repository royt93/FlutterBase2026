# T239 — Fix đổi `factoryId`/`templateType` trên NativeAdWidget đã mount không reload

- **Loại:** Fix (Bug)
- **Priority:** P3 · **Severity:** LOW
- **Status:** ✅ done (2026-09-30)

## Kết quả (Done)

Fix trong `NativeAdWidget.didUpdateWidget`: khi `_allowed.value == true` và provider là AdMob, so sánh `factoryId`/`templateType` qua helper thuần `NativeAdWidget.debugConfigChanged` (`@visibleForTesting`) — đổi thì `AdManager().disposeNativeInstance(this)` + reset `_allowed` + `_initNative()` lại, tái dùng đúng path `disposeNativeInstance`/stale-callback identity-guard (`_nativeRegistry.isCurrent`) sẵn có từ T65/T114/T228. AppLovin path không đổi (không có khái niệm factoryId/templateType; `customNativeAdBuilder` build lại thuần Dart mỗi build, không cần reload adapter).

RED→GREEN: comment out điều kiện mới (`if (false && ...)`) → 3/10 test T239 fail đúng như dự đoán (factoryId A→B, templateType small→medium, rapid A→B→C) → uncomment → 10/10 pass. Widget test file: `packages/ad_sdk/test/native_ad_widget_test.dart` (group "T239 — runtime native configuration reload", 10 test cases: reload-decision helper, factoryId reload, templateType reload, no-op rebuild, rapid coalesce, dispose-during-reload safety, consent-gate-blocked, offline-gate-blocked, AppLovin divergence). Stale-callback guard test riêng trong `packages/ad_sdk/test/admob_late_callback_test.dart` (late onAdLoaded từ config A không đánh dấu config B loaded — tái dùng đúng slot-identity guard có sẵn).

Integration: `packages/ad_sdk/example/integration_test/t228_custom_native_ad_test.dart` mở rộng — thêm nút `T239_toggle_factory_id` trên `NativeDemoPage` (`example/lib/main.dart`) đổi factoryId runtime trên CÙNG widget instance (cùng `State` identity, không remount), verify chạy qua path native factory thật (Android `T228CustomNativeAdFactory.kt` / iOS `.swift`).

Real-device: không có Pixel/TECNO kết nối. Flutter phát hiện Samsung SM A507FN (`R58MA6WYRPE`), nên đã thử integration thật với hard cap 180s. Gradle build APK thành công 39.1s nhưng bước cài app đứng 141s, tổng 175s không có tiến triển tiếp nên process bị kill đúng timeout — chưa chạy tới test body/native-factory log, vì vậy **không có bằng chứng real-device T239 trong phiên này**. `flutter analyze` package + example sạch; T239 targeted 10/10 pass; public API golden 2/2 pass. Full `flutter test` chạy đúng một lần sau fix: 2423 pass, 1 fail ở `vip_manager_robustness_test.dart` timing test không liên quan T239 (tái hiện riêng 2/2 lần, không file VIP nào thay đổi). Example suite: 66 pass, 1 pre-existing fail `compliance_demo_page_test.dart` do secure-storage plugin mock, tái hiện riêng. Golden API không đổi (method helper gắn `@visibleForTesting` trên `NativeAdWidget` nên bị loại khỏi golden).

## Vấn đề (Why)

`NativeAdWidget.didUpdateWidget` (`packages/ad_sdk/lib/src/widget/native_ad_widget.dart:221-230`) chỉ phản ứng với thay đổi của `active` và `controller`:

```dart
void didUpdateWidget(NativeAdWidget oldWidget) {
  super.didUpdateWidget(oldWidget);
  if (widget.active && !_allowed.value) _initNative();
  if (oldWidget.controller != widget.controller) { ... }
}
```

`factoryId` (T228) và `templateType` không được so sánh. `_initNative()` (dòng ~392) chỉ chạy lại khi `!_allowed.value` — với một widget đã load xong (`_allowed.value == true`), đổi `factoryId` qua rebuild (ví dụ host đổi factory theo A/B test hoặc theo theme) không gọi `mgr.loadAdmobNativeIfNeeded` lại; `AdMobAdapter.preloadNative` (`lib/src/adapters/admob_adapter.dart:2406-2427`) cũng tự early-return khi `_nativeAdsByKey.containsKey(key)` nên kể cả gọi lại cũng không load bằng factory mới cho tới khi ad hiện tại bị dispose.

Đây là gap thật nhưng hẹp — hầu hết app không đổi `factoryId` runtime trên cùng 1 widget instance (thường cấu hình tĩnh lúc build). Xếp LOW/P3, không phải regression từ T228, mà là behavior chưa từng được đặc tả.

## Đề xuất giải pháp

Trong `didUpdateWidget`, nếu `oldWidget.factoryId != widget.factoryId` (hoặc `templateType` đổi) trong khi widget đã allowed/loaded, dispose instance cũ qua đúng path đã có (`AdManager().disposeNativeInstance(this)`, giống `controllerRefresh()` đang làm) rồi `_initNative()` lại.

### Acceptance Criteria

- [ ] Đổi `factoryId` trên widget đã load → ad cũ dispose đúng, ad mới load với factory mới.
- [ ] Đổi `templateType` hành xử tương tự.
- [ ] Không đổi hành vi khi `factoryId`/`templateType` không đổi giữa các rebuild (tránh reload thừa mỗi lần parent rebuild).
- [ ] AppLovin path (`customNativeAdBuilder`) không bị ảnh hưởng — đây là AdMob-only concern giống `factoryId` gốc.
- [ ] `flutter analyze` sạch; full `flutter test` pass.

## Kế hoạch kiểm thử

- Widget: mount với `factoryId: 'a'`, đợi allowed, rebuild với `factoryId: 'b'`, assert dispose+reload đúng 1 lần, không loop.
- Widget: rebuild giữ nguyên `factoryId` nhiều lần, assert KHÔNG reload thừa (regression guard).
- Widget: đổi `templateType` tương tự.
- Integration: xác nhận trên device thật với `T228CustomNativeAdFactory` đổi factoryId runtime không crash, log đúng factory mới.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T239 theo quy trình TDD chuẩn:
1. Viết test RED cho đổi factoryId/templateType không reload.
2. Sửa tối giản trong `didUpdateWidget`, tái dùng `disposeNativeInstance`/`_initNative` sẵn có.
3. Bao phủ no-op case (rebuild không đổi field) để tránh reload thừa.
4. Tín hiệu kết thúc vòng lặp: audit độc lập >9/10, đủ test pyramid, smoke test thật đổi factoryId runtime trên device, rồi mới commit/push.
