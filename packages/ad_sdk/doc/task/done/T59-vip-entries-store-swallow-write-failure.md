# T59 — `VipEntriesStore.setRaw()` nuốt lỗi ghi secure storage, đánh dấu migrated dù ghi thất bại

- **REQ:** audit round mới 2026-08-15 (agy, đã verify độc lập — CONFIRMED)
- **Priority:** P1 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/vip/_vip_entries_store.dart`, `packages/ad_sdk/test/vip_entries_store_test.dart`

## Vấn đề (Why)
`_writeSecure(json)` bắt mọi exception Keystore/Keychain, trả `false` khi lỗi. Nhưng `setRaw()` bỏ qua giá trị trả về này, luôn gọi `_legacyPrefs.markVipEntriesSecureMigrated()`. Trên thiết bị Android Keystore lỗi (máy giá rẻ/custom ROM/emulator): data VIP mới không ghi được, cờ migrate vẫn set `true` → `getRaw()` trả `null` vĩnh viễn, mất VIP đã kích hoạt của user thật.

**Phát hiện thêm khi debug (root cause rộng hơn mô tả gốc):** `getRaw()`'s chính migration path (đọc legacy → thử ghi sang secure) CŨNG dính đúng lỗi này — không phải đã đúng như ticket gốc giả định ("khác với getRaw() đã check wrote trước khi xoá legacy"). `getRaw()` có check `wrote` trước khi **xoá** legacy value, nhưng lại **mark migrated KHÔNG điều kiện** (trước cả khi biết `wrote`) — nên khi write thất bại, legacy value tuy còn nguyên trong prefs nhưng vĩnh viễn không đọc lại được nữa (dòng early-return theo cờ migrated chặn trước khi tới bước đọc legacy). Cùng 1 root cause (mark migrated không kiểm tra kết quả ghi), xuất hiện ở cả 2 nơi trong cùng file — sửa chung 1 lần.

## Đã làm (2026-08-15, TDD)
Cả `setRaw()` và nhánh migration của `getRaw()`: chỉ `markVipEntriesSecureMigrated()` khi `_writeSecure()`/ghi thật sự trả `true` (hoặc không có gì để migrate). Viết 2 test trước (RED, `Expected: false, Actual: true` cho cả 2 nhánh), fix, GREEN. `flutter test`: 706/706 pass, `flutter analyze` sạch.

**Giới hạn còn lại (không thuộc scope ticket này):** fix này chỉ ngừng đánh dấu "xong" sai sự thật, cho phép retry ở lần gọi `setRaw()`/`getRaw()` tiếp theo khi Keystore hồi phục. Nếu Keystore hỏng VĨNH VIỄN trên thiết bị đó và app bị kill trước khi retry thành công, VIP grant vẫn mất — vì `setRaw()` hiện KHÔNG có nơi ghi dự phòng nào khác ngoài secure storage (API ghi legacy checksummed đã bị gỡ khi migrate sang secure-storage-only). Đây đúng là scope của **T71** (fallback storage) — không mở rộng ticket này để né scope creep.

## Acceptance criteria
- [x] Test giả lập `_writeSecure` throw/false → `setRaw` không set cờ migrated.
- [x] Test tương tự cho nhánh migration của `getRaw()` (phát hiện thêm, cùng root cause).
- [x] Test xác nhận retry thành công sau khi Keystore hồi phục vẫn đọc lại được data.
- [x] `flutter test` pass (706/706).
