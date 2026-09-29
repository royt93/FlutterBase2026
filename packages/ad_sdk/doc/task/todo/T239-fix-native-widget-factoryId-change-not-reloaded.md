# T239 — Fix đổi `factoryId`/`templateType` trên NativeAdWidget đã mount không reload

- **Loại:** Fix (Bug)
- **Priority:** P3 · **Severity:** LOW
- **Status:** 🔲 todo

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
