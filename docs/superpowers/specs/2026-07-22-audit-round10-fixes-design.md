# Design: đóng các finding audit round 10 (`applovin_admob_sdk`, 8.8 → 10/10)

**Ngày:** 2026-07-22
**Nguồn:** `doc/audit/audit_claude.md` — Round 10 (2026-07-22)
**Ràng buộc cứng:** không thêm dependency mới (pub package hoặc native lib), không thêm backend/server.

## Mục tiêu

Đóng toàn bộ 8 finding còn mở của audit round 10, không phá vỡ 649 test hiện có, không đổi API public theo cách breaking (trừ khi finding yêu cầu).

## Fix 1 — R10-A (High): thứ tự init AppLovin trước UMP khi `autoRequestUmpConsent=true`

**Hiện trạng đã verify:** `packages/ad_sdk/lib/src/core/ad_manager.dart`, trong `initialize()`:
- Dòng 1088-1099: `adapter.initialize(...)` chạy trước.
- Dòng 1157-1172: khối `if (config.autoRequestUmpConsent) { await requestUmpConsent(...); }` chạy **sau**.

Docstring của `requestUmpConsent()` (dòng 1382-1394) tự xác nhận usage chuẩn là gọi **trước** `initialize()`, và cơ chế buffer `_pendingConsentSettings` (dòng 1141-1152, 1345-1357) đã tồn tại sẵn để xử lý đúng trường hợp consent được set trước khi `ConsentManager` bootstrap xong — nghĩa là hạ tầng buffer cần thiết cho việc đảo thứ tự đã có sẵn, không cần xây mới.

**Thay đổi:** trong `initialize()`, di chuyển khối `autoRequestUmpConsent` (dòng ~1154-1172) lên chạy **trước** khối `adapter.initialize()` (dòng ~1082-1105) — cụ thể là sau khi `consentMgr` bootstrap xong (dòng 1062-1067, cần giữ nguyên vị trí vì T40's `isAgeRestrictedUser` gate phụ thuộc nó) nhưng trước khi chọn/khởi tạo adapter.

**Error handling:** `requestUmpConsent()` nội bộ gọi `requestUmpConsentFlow()` — nếu form UMP treo hoặc lỗi, cần đảm bảo có timeout hợp lý (kiểm tra `requestUmpConsentFlow` có timeout chưa; nếu chưa, thêm `.timeout()` tương tự pattern dòng 1088-1099 để không làm treo cold-start cho user ngoài EEA — đa số không có form nên nhánh này phải trả về rất nhanh).

**Testing:** cập nhật/thêm 1 test xác nhận thứ tự gọi (mock adapter + mock UMP, assert UMP gọi trước `adapter.initialize`) trong `packages/ad_sdk/test/`.

## Fix 2 — R10-B (Medium): COPPA đổi giữa phiên không hard-stop AppLovin

**Hiện trạng đã verify:**
- `ad_consent.dart` dòng 82-105: `applyConsentToProviders()` — khi `c.isAgeRestrictedUser == true` và AppLovin đã init trước đó, chỉ `SafeLogger.w(...)`, không có hành động khác (comment dòng 85-101 tự xác nhận đây là gap có chủ đích, chưa xử lý).
- `ad_manager.dart` dòng 1327-1370: `setConsent()` là entry point duy nhất cho consent thay đổi giữa phiên (UMP result → dòng ~1425-1430, privacy-options → dòng ~1486-1491, hoặc host tự gọi `setConsent()` trực tiếp) — tất cả đều route qua `applyConsentToProviders` ở dòng 1363.

**Thay đổi:** trong `setConsent()` (`ad_manager.dart`), ngay sau lệnh `await applyConsentToProviders(consent, config: _config);` (dòng 1363), thêm: nếu `consent.isAgeRestrictedUser == true` và provider hiện tại là AppLovin (`!config.isAdMob`) và adapter đã init (`isInitialised`), set `_canRequestAds = false` ngay lập tức — dừng phát ad tức thì cho mọi provider (kể cả AdMob, dù AdMob đã nhận đúng tag qua `RequestConfiguration`, để nhất quán hành vi "trẻ em → không ad" thay vì chỉ nửa vời).

**Error handling:** không cần try/catch mới — chỉ là gán field bool, không có async/IO.

**Testing:** thêm test trong `ad_manager_test.dart` (hoặc file consent test tương ứng): set `isAgeRestrictedUser=false` lúc init, sau đó gọi `setConsent(isAgeRestrictedUser: true)` giữa phiên, assert `canRequestAds == false` ngay sau await.

## Fix 3 — VIP Android reinstall replay (Medium, giới hạn kiến trúc)

**Hiện trạng:** `_first_install_guard.dart` — Android không có ledger sống sót qua reinstall (SharedPreferences bị xoá khi uninstall), khác iOS (Keychain sống sót).

**Thay đổi (không thêm lib, không server):**
1. Thêm 1 file/marker riêng, tối giản (chỉ chứa hash SHA-256 của `keyId` đã redeem + timestamp — không chứa dữ liệu nhạy cảm), lưu qua `SharedPreferences` (đã có sẵn, không phải dependency mới) dưới 1 key riêng dễ include/exclude trong backup rule.
2. Bật Android Auto Backup cho đúng key/file này qua cấu hình native (`android:allowBackup="true"` + `android:dataExtractionRules`/`android:fullBackupContent` trỏ tới 1 XML include-rule chỉ định riêng key ledger này — không backup toàn bộ SharedPreferences để tránh lộ dữ liệu khác). Áp dụng ở cả `android/app/src/main/AndroidManifest.xml` (host) và `packages/ad_sdk/example/android/.../AndroidManifest.xml`.
3. `_first_install_guard.dart` đọc marker này lúc khởi động: nếu tồn tại (được Android tự restore sau reinstall cùng thiết bị+account) → coi như đã từng nhận trial trước đó, không cấp lại.

**Giới hạn phải document (không phải fix 100%):** không chặn được attacker cố ý (factory reset + đổi tài khoản Google, hoặc reinstall khi tắt sync/máy bay). Đây là mitigation tốt nhất khả thi trong ràng buộc "không backend/server/lib mới" — phải ghi rõ trong `doc/audit/audit_claude.md` Round 11.

**Testing:** unit test cho `_first_install_guard.dart` với mock `SharedPreferences` giả lập 2 kịch bản — (a) marker không tồn tại → cấp trial, (b) marker tồn tại (giả lập đã được Android restore) → không cấp lại.

## Fix 4 — R10-F (Medium): giữ test AdMob ID, thêm cảnh báo

**File:** `lib/mckimquyen/common/const/ad_keys.dart` (host), dòng 56-61 (test ID hiện tại).

**Thay đổi:** hai phần, cả hai đều làm (không phải một-trong-hai):
1. Thêm comment cảnh báo rõ ràng ngay phía trên field, dạng: `// CẢNH BÁO: đây là test ID của Google. Nếu bật lại AdMobConfig, PHẢI thay ID thật trước khi release.`
2. Thêm `assert()` debug-only tại nơi `AdConfig` được dựng lên trong `main.dart`/`splash_screen.dart` (chỗ set `provider: AdProvider.appLovin`): nếu `provider == AdProvider.admob`, assert ID trong `ad_keys.dart` không khớp chuỗi test-placeholder đã biết của Google (ví dụ `ca-app-pub-3940256099942544/...`). `assert()` bị strip ở release nên không chặn production, chỉ bắt sớm lúc dev nếu ai bật lại AdMob mà quên đổi ID.

## Fix 5 — R10-G (Low): `NSUserTrackingUsageDescription` chung chung

**File:** `ios/Runner/Info.plist` (host), dòng 56-57.

**Thay đổi:** viết lại cụ thể hơn, ví dụ: "Chúng tôi dùng dữ liệu này để cá nhân hoá quảng cáo bạn thấy trong app, giúp nội dung quảng cáo phù hợp với bạn hơn." (điều chỉnh văn phong theo tiếng Việt/locale mặc định của app).

## Fix 6 — R10-C (Low): `_retryRefillAds` không check `isConnected`

**File:** `ad_manager.dart`, hàm `_retryRefillAds` (audit round 10 ghi nhận ở khu vực dòng ~2525-2552).

**Thay đổi:** thêm `if (!isConnected) return;` ngay đầu hàm, trước khi gọi 3 hàm `load*`.

## Fix 7 — R10-D (Info): không có timeout cho `ConnectionNotifierTools.initialize()`

**File:** `ad_manager.dart`, `_startConnectivityWatch()` (audit round 10 ghi nhận ở khu vực dòng ~2480-2496).

**Thay đổi:** bọc lệnh gọi native `ConnectionNotifierTools.initialize()` bằng `.timeout(const Duration(seconds: N))` (N tham khảo pattern đã dùng ở dòng 1095 — 20s), giữ nguyên try/catch + fallback optimistic (`_lastConnected = true`) đã có khi timeout/lỗi xảy ra.

## Fix 8 — R10-E (Info): không thêm watchdog cho interstitial/rewarded

**File:** `applovin_adapter.dart`, khu vực comment dòng ~776-779.

**Thay đổi:** không đổi logic. Chỉ mở rộng comment hiện có để nêu rõ đây là quyết định có chủ đích (không phải thiếu sót): rewarded/interstitial load-time thường dài và biến động hơn App Open, thêm watchdog đối xứng có nguy cơ false-positive cao hơn lợi ích khi chưa có bằng chứng treo thực tế.

## Testing tổng thể

Sau khi áp dụng cả 8 fix: chạy lại toàn bộ `flutter test` trong `packages/ad_sdk/` (649+ test hiện có + test mới cho Fix 1/2/3), `flutter analyze` sạch ở cả `packages/ad_sdk` và root, và CI 4 job (`sdk`, `sdk-integration`, `sdk-integration-ios`, `host`) xanh trước khi coi fix hoàn tất.

## Cập nhật tài liệu

Sau khi fix xong, ghi "Round 11" vào `doc/audit/audit_claude.md` xác nhận từng finding đã đóng, giữ nguyên phần document rõ giới hạn còn lại của Fix 3 (VIP Android replay — không phải fix 100%).
