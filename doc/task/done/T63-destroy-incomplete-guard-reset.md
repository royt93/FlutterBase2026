# T63 — `destroy()` không reset đủ consent/ATT guard flag

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P1 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`_resetGuardState`, `debugUmpAttemptFailed` setter mới), `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
**PLAUSIBLE, nhưng tác động của bốn field không giống nhau.** `destroy()` gọi `_resetGuardState()` tại `ad_manager.dart:1915`, trong khi method này tại dòng 1937-1945 chỉ reset `_footgunBlocked`, `_umpRequested`, `_consentExplicitlySet` và hai timer. Nó không ghi lại `_canRequestAds` (khai báo dòng 617), `_lastUmpResult` (695), `_umpAttemptFailed` (699) hay `_attRequested` (727). Nhánh re-init không qua `destroy()` cũng dùng cùng method tại dòng 1043-1057, nên cả hai lifecycle đều giữ bốn giá trị này.

Phạm vi tác động thật:

- `_canRequestAds` là lỗi chức năng rõ nhất: nếu phiên trước để `false`, re-init với `autoRequestUmpConsent: false` không có assignment nào mở lại default, nên public `canRequestAds` vẫn đóng. Với auto-UMP bật, init chủ động đóng gate tại dòng 1272 rồi flow mới cập nhật lại, nên stale value ít đáng kể hơn.
- `_umpAttemptFailed = true` sống qua teardown; lần offline→online sau re-init sẽ gọi lại UMP tại dòng 2927-2935, kể cả config/session mới không tạo failure đó.
- `_lastUmpResult` sống sót nhưng `_umpRequested` được reset về false, nên bình thường không được đọc ngay. Nó chỉ được dùng ở skip branch dòng 1677-1693 sau khi `_umpRequested` lại true; rủi ro stale thấp hơn claim gốc và chủ yếu liên quan flow bất đồng bộ/race.
- `_attRequested` chỉ điều khiển warning thứ tự ATT→UMP tại dòng 1695-1705; trạng thái ATT native vẫn do OS/SDK quản lý. Việc giữ `true` làm mất warning trong session SDK mới, không tái sử dụng hay thay đổi ATT authorization.

Consent đã persist trong `ConsentManager` được giữ qua `destroy()` có chủ đích (`ad_manager.dart:1886-1891`), nên ticket này không nên yêu cầu xoá lựa chọn consent bền vững hay mô tả mọi logout/login là bị “lẫn consent”. Finding chỉ áp dụng cho runtime guard/diagnostic state của singleton.

## Việc cần làm
- [x] **Verify trước:** đối chiếu trực tiếp `destroy()`, `_resetGuardState()`, re-init branch và từng read/write site; xác nhận cả bốn field không được reset, đồng thời phân loại tác động như trên.
- [x] Bổ sung regression test cho `_canRequestAds` và `_umpAttemptFailed` qua `debugResetGuardState()`.
- [x] Bổ sung 2 field có tác động chức năng thật vào `_resetGuardState()`.

## Đã làm (2026-08-15, TDD)
Chỉ fix `_canRequestAds` (reset về default `true`) và `_umpAttemptFailed` (reset về `false`) trong `_resetGuardState()` — đúng 2 field codex xác định có tác động chức năng thật. **Cố ý KHÔNG đụng `_lastUmpResult`/`_attRequested`**: theo phân tích verify ở trên, rủi ro của 2 field này thấp (cache-hit semantics và mất 1 warning thứ tự ATT→UMP, không phải gate chức năng), tự sửa thêm có thể đổi semantics cache không cần thiết ngoài scope ticket.

Thêm setter `debugUmpAttemptFailed` (trước đó chỉ có getter) để test dựng được kịch bản "phiên trước có UMP attempt fail". Viết test trước (RED: `Expected: true, Actual: false` trên `canRequestAds` sau reset), fix, GREEN. `flutter test`: 709/709 pass, `flutter analyze` sạch.
