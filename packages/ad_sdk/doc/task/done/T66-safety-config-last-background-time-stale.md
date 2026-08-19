# T66 — `AdSafetyConfig._lastBackgroundTime` có thể stale khi Android resume nhanh bất thường

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_safety_config.dart:233-240,425-433,471-480,558-561`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2787-2805`

## Vấn đề (Why — CONFIRMED)
`_lastBackgroundTime` chỉ được ghi nhận trong `recordAppWentBackground()` (`ad_safety_config.dart:558-561`) khi `AdManager.didChangeAppLifecycleState` nhận sự kiện `AppLifecycleState.paused` (`ad_manager.dart:2787-2788`). Mốc thời gian này không bao giờ được xóa hoặc reset khi app resume (dòng 234-239 giữ nguyên có chủ đích cho một số check khác).

Khi có các chuỗi lifecycle không đi qua `paused` trên Android (ví dụ: system permission dialog, kéo thả notification shade — Flutter chỉ gửi `resumed -> inactive -> resumed`):
1. `recordAppWentBackground()` không hề được gọi, do đó `_lastBackgroundTime` vẫn giữ nguyên timestamp từ lần background thật sự trước đó (có thể từ nhiều giờ trước).
2. Khi sự kiện `resumed` kích hoạt `showAppOpenAdOnResume()` (`ad_manager.dart:2801`), `canShowAppOpenOnResumeStrict()` tính `timeInBackground = now - _lastBackgroundTime` (`ad_safety_config.dart:471-480`).
3. Vì `_lastBackgroundTime` đã quá cũ, `timeInBackground` ra giá trị rất lớn (hàng triệu ms), khiến điều kiện chặn `timeInBackground < _params.minTimeAppOpenResume` bị bỏ qua (đánh giá thành `false`).
4. Kết quả: App Open ad có thể bung ra ngay giữa phiên sử dụng của user sau một thao tác kéo notification shade hoặc đóng popup cấp quyền.

## Việc cần làm
- [x] **Verify trước:** Đã đọc trực tiếp source `ad_safety_config.dart` và `ad_manager.dart`. Bug **CONFIRMED** — `_lastBackgroundTime` không được tiêu thụ/reset sau resume và `resumed` từ `inactive` (không qua `paused`) tính sai `timeInBackground` dựa trên mốc cũ từ nhiều giờ trước.
- [x] Nếu confirm: xử lý edge case chuỗi lifecycle event không hoàn chỉnh (tiêu thụ/clear background state khi resume hoặc chỉ kích hoạt App Open khi có flag background thực sự).

## Đã làm (2026-08-16)
Thêm flag one-shot mới `_pendingResumeGate` (tách khỏi `_backgroundToResumeSignalPending` vốn chỉ phục vụ diagnostic signal, không gate quyết định show thật). `recordAppWentBackground()` set `_pendingResumeGate = true`. Trong `_canShowAppOpenOnResumeStrict()`: nếu `_lastBackgroundTime > 0` nhưng `_pendingResumeGate` đã bị tiêu thụ (resumed lần trước đã consume) → block ngay với lý do "resume with no new background since the last check (spurious lifecycle event)", KHÔNG tính lại `timeInBackground` từ mốc cũ nữa. Nếu còn pending (background thật vừa xảy ra) → consume flag rồi tính `timeInBackground` như cũ.

TDD: viết test RED trước (`ad_safety_config_test.dart`) mô phỏng đúng kịch bản — consume cold start, `recordAppWentBackground()` + resume thật (phải cho qua), rồi gọi `canShowAppOpenOnResume()` lần 2 không có `paused` mới (phải bị chặn). Test fail đúng lý do (`Actual: <true>`) trước khi fix, pass sau khi thêm gate.

`resetForReinit()` cũng reset `_pendingResumeGate = false` để không rò rỉ giữa các lần re-init/test.

`flutter test`: 723/723 pass, `flutter analyze` sạch.
