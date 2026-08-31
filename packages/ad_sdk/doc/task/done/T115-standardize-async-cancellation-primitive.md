# T115 — Tech debt: Chuẩn hoá primitive huỷ callback async

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (primitive + first migration)
- **Files:** `ad_manager.dart`, 2 adapter, UMP, VIP manager, splash controller, loading dialog

## Vấn đề

Code dùng lẫn generation int, bool disposed, timer, identity check và `Completer` — correctness hiện phụ thuộc comment dài tại từng call site. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] Internal `AsyncEpoch` thống nhất `isCurrent`/`invalidate`/`dispose` — `lib/src/utils/async_epoch.dart`, 6 test (`test/async_epoch_test.dart`)
- [x] Migrate 1 subsystem cô lập (`ad_loading_dialog.dart`) — xem "Migrate đầu tiên" bên dưới
- [x] KHÔNG đổi hành vi observable — chỉ đổi cách biểu diễn nội bộ, xác nhận qua test hiện có không sửa

## Batch D (2026-08-31) — chỉ làm phần 1, DỪNG trước migrate

Xây xong primitive (pure code mới, 0 rủi ro, 6 test). KHÔNG migrate bất kỳ
call site nào — `ad_manager.dart`/2 adapter/UMP/VIP/splash/dialog đều là file
đã audit 26+ vòng, mỗi lần migrate là 1 thay đổi rủi ro riêng cần tự chạy
`test/adapter_contract_test.dart` + full suite + review kỹ, không nên gộp
nhiều subsystem trong 1 lượt không chia nhỏ được. Để ticket này mở, gợi ý
tách thành ticket con theo từng subsystem khi làm tiếp (vd T115a =
`ad_loading_dialog.dart`'s `_generation` — nhỏ nhất, tự chứa, ứng viên đầu
tiên hợp lý).

## Migrate đầu tiên (2026-09-01) — `ad_loading_dialog.dart`

Đúng gợi ý ở trên: `static int _generation` → `static final AsyncEpoch _epoch`.
3 điểm chạm: `resetState()`/`dismiss()` gọi `_epoch.invalidate()` (thay
`_generation++`); `showAdBuffer()` gọi `_epoch.invalidate(); myGen =
_epoch.token;` (thay `myGen = ++_generation` — cần 2 dòng vì `AsyncEpoch`
tách rõ "invalidate" và "read token", không gộp 1 bước như biến int thô);
check cuối đổi `myGen != _generation` → `!_epoch.isCurrent(myGen)`.

KHÔNG đụng `ad_manager.dart`/2 adapter/UMP/VIP/splash — đúng như cảnh báo,
đây vẫn là vùng rủi ro cao, để dành ticket con riêng nếu làm tiếp.

Xác nhận không đổi hành vi bằng test CÓ SẴN (không viết test mới — hành vi
observable không đổi thì không có gì mới để test): nhóm
`test/ad_loading_dialog_test.dart`'s "showAdBuffer generation guard
(stranded-dialog fix)" (11 test, đúng kịch bản double-tap + stacked-popup
regression mà cơ chế này tồn tại để chặn) chạy xanh nguyên không sửa 1 dòng.
Full suite 1475 pass (không đổi số — không thêm hành vi mới), `flutter
analyze` sạch.
