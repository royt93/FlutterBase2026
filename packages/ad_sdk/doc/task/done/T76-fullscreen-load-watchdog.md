# T76 — Load watchdog/timeout cho fullscreen ad load thường (không chỉ on-demand rewarded)

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart`

## Vấn đề (Why)
SDK đã có timeout cho on-demand rewarded load, nhưng preload/load thường của interstitial/rewarded vẫn phụ thuộc hoàn toàn vào callback native SDK — nếu native SDK im lặng, không có watchdog.

## Đề xuất
Thêm watchdog timer tương tự on-demand rewarded cho preload/load thường, timeout → coi như load fail, retry theo backoff hiện có.

## Acceptance criteria
- [x] Test: adapter không gọi callback trong X giây → slot tự chuyển về trạng thái fail thay vì treo vô hạn.

## Đã làm (2026-08-16)
Thêm helper `_armLoadWatchdog(label, slot, timeout)` — `Timer` 1 lần sau mỗi lời gọi `loadInterstitial()`/`loadRewardedAd()`/`loadAppOpenAd()` thật; nếu slot VẪN còn `AdSlotState.loading` khi timer bắn (native SDK không bao giờ gọi callback) → `slot.markFailed()`, tự động kích hoạt lại đúng backoff/retry hiện có (không cần logic mới, `markFailed()` đã handle). Guard 2 lớp (check trước khi arm timer + check lại khi timer bắn) đảm bảo không bao giờ ghi đè 1 ad đã load thật thành công (native trả lời trước khi watchdog bắn thì watchdog thành no-op).

Cả 3 hàm load thêm param `Duration watchdog = const Duration(seconds: 30)` (không đổi hành vi mặc định — chỉ thêm timeout mới hoàn toàn không tồn tại trước đây). App Open: `markFailed()` tự động fire `onAdLoaded(false)` qua `AdSlot.pendingCallback`/`_firePending` sẵn có, không cần code riêng.

TDD: dùng `fakeAsync` + fake adapter's `hangLoad` (cờ có sẵn từ trước, dùng cho on-demand rewarded test) mô phỏng native callback không bao giờ bắn — assert slot chuyển `cooldown` đúng lúc watchdog hết hạn, không sớm hơn. Test thứ 2 xác nhận watchdog KHÔNG đụng vào 1 ad đã load thành công (`loadMarksReady`).

`flutter test`: 744/744 pass, `flutter analyze` sạch.
