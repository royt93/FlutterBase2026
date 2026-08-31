# T119 — Idea: AdManager().explainLastSkip(AdSlotType) — bộ giải thích tại sao ad không hiện

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/core/ad_manager.dart`, `test/ad_manager_core_test.dart`

## Vấn đề

README/CHANGELOG nhắc lại câu hỏi hỗ trợ phổ biến nhất của SDK quảng cáo: "ad không hiện, tại sao?" — hiện phải bật verbose log + đọc tag. Data đã tồn tại rải rác ở các gate (VIP/consent/cooldown/cap/network/dryRun), chỉ cần gom lại.

## Việc cần làm

- [x] ~~Ring buffer nhỏ~~ — đọc kỹ hoá ra KHÔNG cần: đã có sẵn `_emitSkip(type, action, reason, {placement})` — 1 hàm centralized, ~54 call site trong toàn bộ 4 loại ad (T77, `AdSkipEvent`). Chỉ cần sửa ĐÚNG 1 hàm đó để ALSO lưu `_lastSkipByType[type] = event`, không đụng 54 call site nào — rủi ro thấp hơn nhiều so với ticket gốc hình dung.
- [x] `explainLastSkip(AdSlotType)` — đọc `_lastSkipByType`, format `'<type> <action> skipped: <reason humanized>'`. Dùng humanize tổng quát (thay `_`/`-` bằng space) thay vì bảng tra code→câu tay — tránh lệch pha khi có reason code mới thêm sau này. `null` nếu chưa từng skip. Deliberately KHÔNG reset ở `destroy()` (tránh đụng lại đúng lifecycle path đang có bug treo ở T102).
- [x] Test (`test/ad_manager_core_test.dart`, trong group "AdSkipEvent (T77)"): trigger skip qua VIP, xác nhận `explainLastSkip` phản ánh đúng; slot khác chưa từng skip trả `null`. Thêm test seam `debugResetLastSkip()` vì `_lastSkipByType` là state singleton process-wide, cần reset thủ công giữa test để tránh pollution thứ tự chạy (phát hiện được nhờ chạy full file, không chỉ file test mới).

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/explain_last_skip_test.dart` — trigger skip VIP qua `AdManager()` thật, gọi `explainLastSkip()`, xác nhận reason chứa 'vip'. Đã viết, `flutter analyze` sạch, CHƯA chạy trên thiết bị thật (cần emulator/device).
