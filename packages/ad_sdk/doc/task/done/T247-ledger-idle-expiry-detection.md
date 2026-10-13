# T247 — Phát hiện revenue gap dù app idle

- **Loại:** Enhancement
- **Priority:** P2 · **Effort:** M
- **Confidence:** CONFIRMED limitation, not confirmed loss of correctness
- **Status:** done (full suite, device checks, and whole-diff audit passed; 2026-10-13)
- **Evidence:** `lib/src/monetization/revenue_integrity_ledger.dart`; `lib/src/core/ad_manager.dart` resume sweep; `test/revenue_integrity_ledger_test.dart`, `test/ad_manager_core_test.dart`, `example/integration_test/t145_revenue_integrity_ledger_test.dart`
- **Dependency:** none

## Giá trị

Ban đầu ledger chỉ sweep khi có event mới, sau đó thêm timer để phát hiện khi app idle. Timer đơn độc không thể đảm bảo hết hạn trong lúc thiết bị sleep, nên hiện deadline lưu bằng wall-clock `DateTime`, timer one-shot phục vụ khi app active, và `AdManager` sweep ledger đã đăng ký mỗi khi app resume. Clock correction có thể đổi thời điểm hết hạn; đây vẫn là heuristic, không phải bằng chứng mất doanh thu.

## Phạm vi

- Đã chọn: deadline theo wall-clock `DateTime`; mọi ledger tự register với `AdManager`, sweep ngay khi resume để tính cả thời gian ngủ. Khi app active, timer re-check tối đa mỗi phút để bắt clock jump tiến; clock correction có thể làm expiry sớm/muộn.
- Giữ nguyên match chính xác theo `requestId`, fallback FIFO hiện tại, và semantics `dispose()`.
- Xác nhận `matchWindow <= 0`, nhiều pending show, callback đến sát hạn, event trễ, và clock injection.

## Acceptance criteria

- [x] Unit: active idle expiry by timer; injected wall-clock exact-boundary remains valid and +1µs expires; matching revenue before deadline prevents incident; late revenue does not undo incident.
- [x] Unit: wall-clock moves backward, timer fires early, pending show stays and re-arms; dispose cancels pending work; zero/negative windows terminate; multi-pending and FIFO deadline ordering covered.
- [x] AdManager lifecycle tests: any constructed ledger auto-registers for resume sweep before init/adapter guards; dispose unregisters it and `destroy()` disposes all registered ledgers. Sweep starts no ad work.
- [x] Widget test: N/A — ledger is non-UI logic; lifecycle binding is exercised by manager test and integration tests.
- [x] Android Pixel 7 Pro integration: real-deadline resume test passes 1/1 with screen off; `dumpsys power` reported `mWakefulness=Dozing`, `/proc/uptime` advanced ~5.17s over 5s. Verifies Dozing/resume dispatch, not confirmed deep CPU suspend.
- [x] Prior Samsung S24 Ultra combined T145+T146 integration passed 5/5; iOS Simulator T145 wall-clock resume suite passed 4/4.
- [x] Final Pixel 7 Pro targeted integration: Dozing/screen-off resume case 1/1; overdue resume 1/1; before-deadline resume 1/1. A broader all-T145 invocation stalled after APK install, so final evidence uses the individually targeted cases.
- [x] iOS Simulator integration: T145 wall-clock resume cases pass 4/4; verifies Flutter lifecycle dispatch and wall-clock logic, not actual deep-sleep duration.
- [x] Independent full-diff audit: 9.2/10, no findings (2026-10-13).
- [x] Package analyzer clean; full SDK suite 2677/2677 pass after wall-clock implementation and guard fix.

## Tiến độ thực tế (2026-10-13)

- `RevenueIntegrityLedger` dùng deadline wall-clock, active timer polling tối đa mỗi phút, và resume sweep qua ledger registry nội bộ của `AdManager`; không có observer riêng hay ad work trong sweep.
- Unit/lifecycle/guard/API focused suite: 375/375 pass; package analyzer clean; full SDK suite 2677/2677 pass.
- Samsung S24 Ultra combined T145+T146 integration passed 5/5; Pixel 7 Pro Dozing, overdue-resume và before-deadline cases đều pass; iOS lifecycle integration pass. Synthetic events only; không tuyên bố đã ép deep CPU sleep hay callback ad network.
- Format sạch; API golden unchanged. Final audit score 9.2/10, no findings.

## Prompt vòng lặp

Triển khai T247 theo TDD; đọc lại code/test và backlog liên quan trước khi sửa. Viết test đỏ cho idle expiry, matching trước/sau hạn, nhiều pending và dispose; chỉ chọn timer sau khi chứng minh semantics cần thiết. End loop: audit lại changes, chấm điểm /10, bổ sung unit + widget + integration cho mọi case (ghi rõ widget không áp dụng nếu vẫn không có UI), smoke test thiết bị và nêu giới hạn app background. Chỉ khi toàn bộ test/analyze pass và điểm >9/10 mới commit/push theo yêu cầu task; không mở rộng phạm vi.