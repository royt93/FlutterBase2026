# T75 — Public `ValueListenable` cho fullscreen mutex busy state

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:644,2267,2458`

## Vấn đề (Why)
`_fullscreenBusyReason` bảo vệ tốt trong SDK nhưng app không quan sát được trạng thái busy để disable CTA hoặc tránh mở dialog riêng chồng lên.

## Đề xuất
Expose `ValueListenable<FullscreenBusyState>` hoặc stream read-only.

## Acceptance criteria
- [x] Listenable phản ánh đúng thời điểm bắt đầu/kết thúc fullscreen busy trong test.

## Đã làm (2026-08-16)
Thêm `AdManager().fullscreenBusy` — `ValueNotifier<bool>`, mirror thật của `_fullscreenBusyReason != null`. `_fullscreenBusyReason` phụ thuộc 5 nguồn: 3 slot fullscreen (`appOpenSlot`/`interstitialSlot`/`rewardedSlot`, live trên adapter instance), `AdLoadingDialog.isShowing`, `AdScreenRouteLogger.isDialogOnTop` — cả 5 trước đây đều KHÔNG reactive (2 cái sau là static bool/int thường).

Thêm `ValueNotifier<bool>` cho cả `AdLoadingDialog` (`isShowingNotifier`) và `AdScreenRouteLogger` (`isDialogOnTopNotifier`), đồng bộ qua field-riêng + setter-riêng (tất cả call site gán giá trị cũ tự động đi qua, không phải sửa từng chỗ). `AdManager._adapter` cũng đổi thành field + setter riêng — mọi lần gán (init thật, `destroy()`, `debugSetAdapter` test seam) đều tự re-wire 3 listener slot fullscreen, không cần sửa các call site đó.

`AdLoadingDialog.isShowingNotifier`/`AdScreenRouteLogger.isDialogOnTopNotifier` wire 1 lần trong `AdManager._internal()` (2 class kia sống suốt process, không như adapter bị destroy/re-init).

**Bug phụ phát hiện khi chạy full suite:** 3 fake adapter test (`integration_self_check_test.dart`, `privacy_options_test.dart`, `npa_consent_wiring_test.dart`) chưa từng override `appOpenSlot`/`interstitialSlot`/`rewardedSlot` (dựa vào `noSuchMethod`), trước giờ vô hại vì `debugSetAdapter()` chỉ gán field đơn thuần. Giờ `_adapter` setter mới THẬT SỰ đọc 3 getter đó ngay khi gán → lộ `NoSuchMethodError`. Thêm `AdSlot` thật cho cả 3 fake, đúng pattern đã dùng ở T65.

TDD: 3 test mới trong `ad_manager_core_test.dart` — slot chuyển showing/dismissed, `AdLoadingDialog.show()/dismiss()`, `AdScreenRouteLogger` push/pop popup — đều assert `fullscreenBusy.value` bật/tắt đúng lúc.

`flutter test`: 742/742 pass (chạy 2 lần xác nhận ổn định), `flutter analyze` sạch.
