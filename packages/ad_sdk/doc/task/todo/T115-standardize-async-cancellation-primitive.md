# T115 — Tech debt: Chuẩn hoá primitive huỷ callback async

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `ad_manager.dart`, 2 adapter, UMP, VIP manager, splash controller, loading dialog

## Vấn đề

Code dùng lẫn generation int, bool disposed, timer, identity check và `Completer` — correctness hiện phụ thuộc comment dài tại từng call site. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] Internal `AsyncEpoch` thống nhất `isCurrent`/`invalidate`/`dispose` — `lib/src/utils/async_epoch.dart`, 6 test (`test/async_epoch_test.dart`)
- [ ] Migrate từng subsystem một, giữ timing hiện tại bằng fake clock test
- [ ] KHÔNG đổi hành vi observable — chỉ đổi cách biểu diễn nội bộ

## Batch D (2026-08-31) — chỉ làm phần 1, DỪNG trước migrate

Xây xong primitive (pure code mới, 0 rủi ro, 6 test). KHÔNG migrate bất kỳ
call site nào — `ad_manager.dart`/2 adapter/UMP/VIP/splash/dialog đều là file
đã audit 26+ vòng, mỗi lần migrate là 1 thay đổi rủi ro riêng cần tự chạy
`test/adapter_contract_test.dart` + full suite + review kỹ, không nên gộp
nhiều subsystem trong 1 lượt không chia nhỏ được. Để ticket này mở, gợi ý
tách thành ticket con theo từng subsystem khi làm tiếp (vd T115a =
`ad_loading_dialog.dart`'s `_generation` — nhỏ nhất, tự chứa, ứng viên đầu
tiên hợp lý).
