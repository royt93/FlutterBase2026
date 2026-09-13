# T200 — Scoped SDK data-erasure API (NEW)
Priority P1 · Status todo · Source `lib/src/utils/ad_preferences.dart:578` và SDK-owned keys.

`clearAllData()` gọi prefs.clear(), có thể xoá dữ liệu host; SDK thiếu erase scoped. Khuyến nghị `clearSdkData(scope: analytics|diagnostics|allIncludingEntitlements)` với key registry/versioning, explicit confirmation cho entitlement. Expose clearAllData nguy hiểm; không API không đáp ứng privacy.

Tests: unit registry/idempotency/failure; widget confirmation; integration erase→reload; device smoke host keys còn nguyên, SDK keys biến mất.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Kết quả (2026-09-13)

**Cố ý đơn giản hoá 3 mức "analytics|diagnostics|allIncludingEntitlements"
thành 2 mức** — sau khi liệt kê đầy đủ 32 key thật trong `AdPreferences`,
không tìm thấy ranh giới tự nhiên nào trong codebase phân biệt được
"analytics" với "diagnostics" (không có 2 namespace tách biệt cho 2 khái
niệm này) — ép buộc chia 3 mức sẽ là phân loại giả tạo, không phản ánh
đúng cấu trúc thật. Thay vào đó: `everythingExceptEntitlements` (mặc
định, gộp cả analytics lẫn diagnostics) và `allIncludingEntitlements`
(thêm VIP) — đúng ranh giới THẬT SỰ quan trọng mà mô tả gốc lo ngại
(bảo vệ dữ liệu người dùng đã trả tiền).

**Không dùng pattern-match tên key** (VD "chứa chữ Vip") để phân loại
entitlement — đã tự kiểm tra và phát hiện cách này BỎ SÓT
`_keyListGAID` (danh sách GAID VIP legacy 1.x) và
`_keyFirstInstallApplied`/`_keyFirstInstallAt` (cờ/mốc thời gian VIP
grace lần cài đầu) — cả 2 đều là dữ liệu VIP thật nhưng tên biến không
chứa "Vip". Dùng danh sách tường minh (đúng khuyến nghị "key registry"
trong mô tả gốc), liệt kê từng key 1 lần, dễ audit lại.

**Sweep bằng tiền tố `ad_sdk_`** (không phải registry cho MỌI key) cho
phần KHÔNG phải entitlement — tự động bao gồm key mới thêm sau này mà
không cần cập nhật danh sách, giảm rủi ro "quên đăng ký" (registry chỉ
cần cho 15 key entitlement, phần còn lại tự động).

**Kiến trúc 2 tầng lưu trữ**: `AdPreferences.clearSdkData()` (chỉ quét
SharedPreferences) + `AdManager.clearSdkData()` (điều phối thêm cả
`flutter_secure_storage` — nơi VIP entries/redeemed-key ledger/
first-install-grace flag thực sự nằm). Khi SDK đang chạy (`_vipManager`
khác null), dùng `VipManager.eraseAllEntitlementData()` (gọi
`revokeAll()` có sẵn — cập nhật ngay trạng thái reactive
`activeListenable`, không cần đợi restart). Khi SDK CHƯA khởi tạo, dùng
biến thể `static` tự tạo store tạm — đảm bảo request xoá dữ liệu vẫn
hoạt động dù host gọi trước `initialize()`.

Đổi tên 3 hàm `clearForTest()` (trước đây `@visibleForTesting`, "Production
callers should never invoke this") thành `erase()` — vì T200 chính là 1
lý do PRODUCTION THẬT hợp lệ để gọi thao tác này, không còn đúng để giữ
tên/cảnh báo cũ.

Xác minh không vô nghĩa: tạm bỏ từng khâu (scoping trong
`AdPreferences.clearSdkData`, gọi `_redeemedKeyLedger.erase()` trong
`eraseAllEntitlementData`, nhánh live-VipManager trong
`AdManager.clearSdkData`), xác nhận đúng test tương ứng fail, rồi khôi
phục.

**Bài học khi viết widget test**: nút "Xoá hết" gọi `clearSdkData` thật
(chạm tới `flutter_secure_storage` qua platform channel) — testWidgets
mặc định chạy trong fake-async, không cho phép công việc platform-channel
thật hoàn tất dù gọi `pumpAndSettle()` bao nhiêu lần (đã gặp lỗi y hệt ở
1 phiên trước, ghi trong memory) — sửa bằng cách bọc CẢ 2 lần tap
(mở dialog + xác nhận) VÀ 1 khoảng chờ thật (300ms) trong CÙNG 1 khối
`tester.runAsync()`.

Xác minh: `flutter analyze` sạch; SDK suite 2074 test xanh (từ 2064,
+10); example suite 52 file xanh (từ 47, +5: 1 test điều hướng tile mới
+ 4 test widget cho dialog xác nhận). Thêm 1 tile demo mới trong
`example/` (`ClearSdkDataDemoPage`) với dialog xác nhận thật trước khi
gọi scope nguy hiểm — không chỉ mô tả suông, đây CHÍNH LÀ luồng xác nhận
thật.

Device smoke thật trên **Pixel 7 Pro** (`2B051FDH3006MU`) qua
`example/integration_test/t200_clear_sdk_data_test.dart` — dùng
`SharedPreferences` VÀ `FlutterSecureStorage` THẬT (Android Keystore
thật): xác nhận key của "host app giả lập" sống sót qua MỌI scope, key
SDK thật biến mất sau scope mặc định, key VIP thật trong Keystore chỉ
biến mất sau khi gọi scope nguy hiểm CÓ xác nhận.

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng: kiểm tra thủ công từng key thật trong
codebase (không đoán), kỷ luật revert-để-xác-nhận-đỏ cho cả 3 tầng logic
(AdPreferences/VipManager/AdManager), và device smoke thật xác nhận cả
2 storage backend (SharedPreferences + secure storage) hoạt động đúng.
