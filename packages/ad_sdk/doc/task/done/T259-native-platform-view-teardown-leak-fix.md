# T259 — Vá Rò Rỉ Native Platform View Khi NativeAdWidget Unmount Giữa Lúc Nạp

- **Loại:** Bug Fix / Memory Leak Hardening
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (KẾT LUẬN: REFUTED / FALSE POSITIVE — ĐÃ CÓ BẢO VỆ ĐẦY ĐỦ TRONG SOURCE)

## Bối cảnh & Kết quả Rà soát Mã nguồn Thực tế (2026-10-17)

Giả định ban đầu cho rằng: *Khi NativeAdWidget unmount giữa chừng lúc đang nạp, native platform view bị rò rỉ vì callback onNativeAdLoaded không gọi dispose().*

**KẾT LUẬN: GIẢ THUYẾT NÀY LÀ FALSE POSITIVE. MÃ NGUỒN HIỆN TẠI ĐÃ BẢO VỆ CHẶT CHẼ:**

1. **Phía Google AdMob (`lib/src/adapters/admob_adapter.dart`):**
   - Khi `NativeAdWidget` unmount, `disposeNativeInstance(key)` chạy ngay lập tức:
     `_nativeAdsByKey.remove(key)?.dispose();`
   - Đối tượng `NativeAd` được khởi tạo và lưu vào `_nativeAdsByKey[key]` ngay trước khi gọi `nativeAd.load()`. Do đó khi widget unmount, đối tượng này **ĐÃ ĐƯỢC GỌI `.dispose()` NGAY LẬP TỨC** tại thời điểm unmount, không phải chờ đến khi callback hoàn tất.
   - Thêm vào đó, `_nativeRegistry.removeKey(key)` hủy liên kết slot; khi callback muộn trả về, `!_nativeRegistry.isCurrent(key, slot)` bảo vệ không gán đè hay kích hoạt state trên widget đã chết.
2. **Phía AppLovin MAX (`lib/src/adapters/applovin_adapter.dart`):**
   - Đã có cơ chế `_disposedNativeKeys` (Bounded LinkedHashSet tombstone) từ audit round 26:
   - Khi `disposeNativeInstance(key)` chạy, key được đưa vào danh sách tombstone. Nếu `MaxNativeAdView` bắn callback muộn sau khi widget bị dispose, adapter phát hiện tombstone và lập tức từ chối tạo mới hay giữ lại `BannerListenables` mồ côi.
   - `preloadNative` trên AppLovin là no-op có chủ đích (MaxNativeAdView tự quản lý vòng đời view theo cây widget Flutter).
3. **Quyết định kỹ thuật:**
   - Đóng task dưới dạng **REFUTED / FALSE POSITIVE**. Không thêm code/cờ `isDisposed` dư thừa vào `InlineAdInstanceRegistry` để tránh over-engineering và tuân thủ nguyên tắc YAGNI.

## Acceptance Criteria

- [x] Rà soát và chứng minh cơ chế hủy platform view hiện tại của AdMob và AppLovin đã hoạt động đúng.
- [x] Không phát sinh thêm code trừu tượng thừa.
- [x] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.
