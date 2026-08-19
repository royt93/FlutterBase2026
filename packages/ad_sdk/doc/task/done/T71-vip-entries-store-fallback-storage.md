# T71 — `VipEntriesStore` cần fallback lưu trữ khi secure storage không khả dụng (đi kèm T59)

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/vip/_vip_entries_store.dart:42-90`

## Vấn đề (Why)
Một số thiết bị Android giá rẻ/custom ROM có Keystore lỗi khiến `flutter_secure_storage` không đọc/ghi được. Sau khi T59 fix (không đánh dấu migrated sai), vẫn cần fallback thật để user hợp lệ không bị mất trạng thái VIP hoàn toàn trên thiết bị đó.

## Đề xuất
Tự động fallback ghi vào `AdPreferences` (kèm mã hoá/checksum nhẹ) khi `_writeSecure` fail liên tục, thay vì chỉ tránh đánh dấu sai (T59) mà không có nơi lưu thay thế.

## Acceptance criteria
- [x] Test: `_writeSecure` fail liên tục → data VIP vẫn đọc lại đúng qua fallback.
- [x] `flutter test` pass.

## Đã làm (2026-08-16)
Thêm 3 hàm mới trong `AdPreferences`: `setVipEntriesFallbackRaw`/`getVipEntriesFallbackRaw`/`clearVipEntriesFallbackRaw`, key riêng (`ad_sdk_vip_entries_fallback_v1`, KHÁC key legacy migration) — dùng chung hàm checksum `_vipEntriesChecksum` sẵn có, không phát minh format mới.

`VipEntriesStore.setRaw()`: khi `_writeSecure` fail → ghi vào fallback thay vì bỏ qua; khi thành công → clear fallback cũ (tránh đọc nhầm data cũ khi Keystore hồi phục). Áp dụng tương tự cho nhánh migration nội bộ trong `getRaw()` (write-fail path). `getRaw()`: check fallback TRƯỚC khi rơi vào logic legacy-migration một lần — vì thiết bị Keystore hỏng vĩnh viễn cũng sẽ không bao giờ hoàn tất migration đó.

**Quan trọng — giữ nguyên invariant T59:** KHÔNG set `markVipEntriesSecureMigrated()` trong nhánh fallback — verify bằng test riêng "fallback data is not marked as a completed secure migration". Nếu set nhầm sẽ phá lại đúng bug T59 đã fix (getRaw() short-circuit về null vĩnh viễn).

TDD: 3 test mới trong `vip_entries_store_test.dart` — (1) write fail liên tục → app "khởi động lại" (store instance mới) vẫn đọc đúng qua fallback, (2) fallback không đánh dấu migrated, (3) Keystore hồi phục → fallback cũ bị xoá, đọc lại secure storage thật.

`flutter test`: 732/732 pass, `flutter analyze` sạch.
