# T73 — `NativeAdWidget` hỗ trợ cấu hình kích thước/template (không cố định medium/320)

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:36,139-148`

## Vấn đề (Why)
Cố định `_height = 320` và `TemplateType.medium`. Host muốn nhúng native ad vào `ListView` in-feed (template nhỏ ~90dp) không có cách cấu hình.

## Đề xuất
Cho phép truyền `TemplateType`/custom height qua constructor, giữ default hiện tại nếu không set.

## Acceptance criteria
- [x] `NativeAdWidget(templateType: TemplateType.small)` render đúng kích thước nhỏ.
- [x] Default không đổi khi không truyền param mới (backward-compatible).

## Đã làm (2026-08-16)
`NativeAdWidget` thêm 2 param mới: `templateType` (Google `TemplateType`, default `.medium`, re-export qua barrel để host không cần import trực tiếp `google_mobile_ads`) và `height` (nullable, override tuỳ ý). Height mặc định suy ra từ `templateType` khi không truyền `height`: `medium`→320 (không đổi), `small`→90. Áp dụng cho CẢ 2 provider (AppLovin không có khái niệm template nhưng vẫn tôn trọng `height` cho layout riêng của nó).

Thread `templateType` xuyên suốt: widget → `AdManager.loadAdmobNativeIfNeeded(key, templateType:)` → `AdProviderAdapter.preloadNative(key, {templateType})` → `AdMobAdapter` dùng để build `NativeTemplateStyle` thật (thay vì hardcode `.medium`). AppLovin's `preloadNative` nhận param nhưng bỏ qua (đã ghi rõ trong doc comment — không có khái niệm tương đương).

**Bug phụ phát hiện khi implement:** connectivity/resume retry path trong `AdMobAdapter` gọi lại `preloadNative(key)` KHÔNG kèm `templateType` — nếu không sửa, 1 native `small` bị lỗi trong lúc mất mạng sẽ load lại nhầm về `medium` khi retry. Thêm `Map<Object, TemplateType> _nativeTemplateTypeByKey` ghi nhớ template mỗi key đã yêu cầu, dùng lại đúng giá trị đó ở retry path; dọn dẹp trong `disposeNativeInstance`.

TDD: 4 test mới trong `native_ad_widget_test.dart` — default giữ nguyên 320, `small` → 90, `height` tường minh thắng override, và xác nhận `templateType` được truyền đúng xuống adapter.

`flutter test`: 737/737 pass, `flutter analyze` sạch (cả package lẫn example).
