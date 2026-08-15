# T59 — `VipEntriesStore.setRaw()` nuốt lỗi ghi secure storage, đánh dấu migrated dù ghi thất bại

- **REQ:** audit round mới 2026-08-15 (agy, đã verify độc lập — CONFIRMED)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/vip/_vip_entries_store.dart:66-90`

## Vấn đề (Why)
`_writeSecure(json)` bắt mọi exception Keystore/Keychain, trả `false` khi lỗi. Nhưng `setRaw()` bỏ qua giá trị trả về này, luôn gọi `_legacyPrefs.markVipEntriesSecureMigrated()`. Trên thiết bị Android Keystore lỗi (máy giá rẻ/custom ROM/emulator): data VIP mới không ghi được, cờ migrate vẫn set `true` → `getRaw()` sau khi restart trả `null` vĩnh viễn, mất VIP đã kích hoạt của user thật. Khác với `getRaw()` (dòng 55-60) đã check `wrote` trước khi xoá legacy.

## Đề xuất
Chỉ gọi `markVipEntriesSecureMigrated()` khi `_writeSecure()` trả `true`. Nếu `false`, giữ nguyên fallback ghi vào legacy `SharedPreferences` (đối xứng logic đã có ở `getRaw()`).

## Acceptance criteria
- [ ] Test giả lập `_writeSecure` throw/false → `setRaw` không set cờ migrated.
- [ ] Test xác nhận data vẫn đọc lại được từ legacy prefs sau restart khi write secure thất bại.
- [ ] `flutter test` pass.
