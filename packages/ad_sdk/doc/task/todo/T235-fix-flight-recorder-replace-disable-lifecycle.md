# T235 — Fix recorder cũ ghi đè evidence sau replace/disable

- **Loại:** Fix (Bug / Lifecycle)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** 🔲 todo

## Vấn đề (Why)

`AdManager.enableFlightRecorder()` tại `packages/ad_sdk/lib/src/core/ad_manager.dart:967-973` chỉ gán `_flightRecorder = recorder`; `disableFlightRecorder()` tại dòng 977-979 chỉ gán `null`. Recorder bị thay thế/vô hiệu hóa không được flush/cancel/detach.

Trong khi đó, mỗi `AdFlightRecorder` giữ `_prefs`, `_debounceTimer` và `_persistChain` riêng (`lib/src/compliance/ad_flight_recorder.dart:238-295`), nhưng tất cả cùng ghi chung key trong `AdPreferences`. Recorder A có write debounce đang chờ có thể bị thay bằng B; sau đó timer A vẫn chạy và ghi snapshot cũ đè lên evidence mới của B.

Có thêm race cùng root cause tại `AdManager.recordFlightRecorderEvent()` (`ad_manager.dart:1011-1014`): method chụp `final recorder = _flightRecorder`, rồi `await IabStorage.read(...)`. Nếu host disable/replace trong lúc await, call cũ vẫn tiếp tục `recorder.record(...)` vào instance không còn active; instance đó vẫn có prefs và có thể persist stale data.

## Đề xuất giải pháp

Thêm lifecycle kết thúc tối giản cho `AdFlightRecorder`: cancel debounce, chờ/flush hoặc loại bỏ pending writer theo semantics rõ ràng, và detach khỏi prefs. `AdManager` phải dùng cùng cơ chế swap/dispose an toàn như các observer opt-in khác; trước khi commit record sau `await`, xác nhận recorder vẫn là instance active.

### Acceptance Criteria

- [ ] Replace A→B không để A ghi xuống storage sau khi B active.
- [ ] Disable không để event đang chờ IAB read hoặc debounce cũ append/persist thêm.
- [ ] Pending evidence trước replace được xử lý theo contract rõ ràng (flush trước swap hoặc discard có chủ đích), không silently race.
- [ ] Gọi enable/disable lặp lại idempotent, không leak Timer/future.
- [ ] Không đổi hành vi khi chỉ có một recorder suốt vòng đời app.
- [ ] `flutter analyze` sạch; full `flutter test` pass.

## Kế hoạch kiểm thử

- Unit: record bằng A, replace B trước debounce 1s; record bằng B; chờ hết timer, reload prefs và assert không có snapshot stale của A ghi đè B.
- Unit: giữ `IabStorage.read` pending, disable/replace, resolve read; assert recorder cũ không nhận entry.
- Lifecycle: enable→disable→enable nhiều vòng, dispose app, kiểm tra không Timer/callback sau teardown.
- Integration/device: đổi recorder runtime, export sau cold restart, verify đúng chain active duy nhất.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T235 theo quy trình TDD chuẩn:
1. Viết RED test cho stale debounce writer và in-flight IAB read trước khi sửa.
2. Dùng lifecycle/swap pattern sẵn có; không tạo manager mới hay dependency mới.
3. Bao phủ success, failure, replace, disable, destroy, cold restart; mutation-test guard identity.
4. Tín hiệu kết thúc vòng lặp: audit độc lập >9/10, đủ unit/widget/integration, smoke test device thật, rồi mới commit/push.
