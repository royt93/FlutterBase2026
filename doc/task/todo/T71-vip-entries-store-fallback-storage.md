# T71 — `VipEntriesStore` cần fallback lưu trữ khi secure storage không khả dụng (đi kèm T59)

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/vip/_vip_entries_store.dart:42-90`

## Vấn đề (Why)
Một số thiết bị Android giá rẻ/custom ROM có Keystore lỗi khiến `flutter_secure_storage` không đọc/ghi được. Sau khi T59 fix (không đánh dấu migrated sai), vẫn cần fallback thật để user hợp lệ không bị mất trạng thái VIP hoàn toàn trên thiết bị đó.

## Đề xuất
Tự động fallback ghi vào `AdPreferences` (kèm mã hoá/checksum nhẹ) khi `_writeSecure` fail liên tục, thay vì chỉ tránh đánh dấu sai (T59) mà không có nơi lưu thay thế.

## Acceptance criteria
- [ ] Test: `_writeSecure` fail liên tục → data VIP vẫn đọc lại đúng qua fallback.
- [ ] `flutter test` pass.
