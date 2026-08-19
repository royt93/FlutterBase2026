# T80 — Thiếu regression test khoá lại fix init-retry-flag (2.0.1)

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/test/ad_manager_core_test.dart`, `packages/ad_sdk/CHANGELOG.md` [2.0.1]

## Vấn đề (Why)
CHANGELOG 2.0.1 ghi nhận đã fix 1 bug liên quan cờ init-retry, nhưng grep tên biến này trong test hiện có → 0 kết quả trùng khớp đúng kịch bản (2 lệnh `initialize()` chồng lấn). Một regression thật đã fix nhưng không có gì ngăn nó tái diễn nếu ai refactor logic init.

## Đề xuất
Viết test 2 lệnh `initialize()` gọi chồng lấn (lệnh 2 gọi trước khi lệnh 1 hoàn tất), xác nhận `onComplete`/event init không fire kép hoặc bị lẫn state.

## Acceptance criteria
- [x] Test mới pass, fail nếu revert lại fix 2.0.1 (verify bằng cách tạm comment fix, thấy test đỏ).

## Đã làm (2026-08-16)
Root cause của việc "không viết được test thật" cho bug này: real `adapter.initialize()` fail gần như tức thời dưới `flutter test` (không có native platform channel) — không có cách nào tự nhiên tạo được đúng race "retry timer bắn trong lúc 1 lệnh initialize() khác đang giữ `_isInitializing`", vì `initialize()` tự khởi tạo adapter thật nội bộ, không inject được fake có thể làm chậm timing theo ý muốn.

Giải pháp: thêm 2 seam test-only (`@visibleForTesting`) — `debugSimulateInternalRetryRaceWithBusyGuard()` (set thẳng `_isInitializing=true` + `_isInternalInitRetryCall=true`, tái tạo CHÍNH XÁC trạng thái tại thời điểm bug xảy ra) và `debugIsInternalInitRetryCall` getter. Test: giả lập race → gọi `initialize()` thật (rơi vào early-return vì `_isInitializing`) → assert flag đã được clear (không rò rỉ sang lệnh tiếp theo) + `onComplete` không bị gọi.

**Verify test thật sự bắt được regression** (đúng acceptance criteria): tạm đảo ngược thứ tự fix (đưa check `_isInitializing` lên TRƯỚC đoạn đọc+clear flag, y hệt code trước 2.0.1) → test đỏ đúng dự kiến (`Expected: false, Actual: <true>`) → khôi phục lại fix → xanh trở lại.

`flutter test`: 750/750 pass, `flutter analyze` sạch.
