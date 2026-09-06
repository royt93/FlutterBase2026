# Audit round 39 — `applovin_admob_sdk` 2.9.18

## Tóm tắt

Source ở commit `1af945e` có chất lượng cao: guard consent của round 38 còn nguyên ở cả `ConsentManager` và `AdManager`, các đường load/show đều có gate VIP/consent/connectivity/cap, và teardown đã quản lý timer/subscription/callback khá chặt. `flutter analyze` sạch và toàn bộ **1640/1640** unit/widget test pass. Audit vẫn xác nhận 3 giới hạn sản phẩm có hậu quả thực tế: trial và ledger VIP có thể bị reset trên Android khi reinstall không restore backup; một mã VIP có thể replay trên nhiều thiết bị; banner/MREC trong `IndexedStack` trần vẫn request/refresh khi tab bị ẩn.

## Findings

### MAJOR-1 — Trial 1 ngày có thể lấy lại vô hạn bằng reinstall trên Android khi Auto Backup không restore

- **Dẫn chứng:** `lib/src/vip/_first_install_guard.dart:27-47`, `lib/src/vip/_first_install_guard.dart:126-145`, `lib/src/core/ad_manager.dart:2593-2603`.
- **Lỗi:** `FirstInstallGuard.hasAlreadyGranted()` luôn trả `false` trên Android. Chống reinstall chỉ dựa vào `SharedPreferences` được Android Auto Backup khôi phục; đây không phải tín hiệu bền vững và không hoạt động khi người dùng tắt backup/sync, đổi Google account, thiết bị/OEM không restore đúng lúc, hoặc chủ động clear backup. Chính source cũng xác nhận trường hợp này là bypass (`_first_install_guard.dart:49-56`).
- **Kịch bản:** người dùng Android nhận `firstInstallVipGrace` 24 giờ → uninstall app → backup bị tắt/không restore → reinstall → `isFirstInstallGraceApplied()` lại false và guard Android lại trả false → `vip.addVip(... duration: 1 day)` chạy lần nữa. Có thể lặp để duy trì VIP không quảng cáo.
- **Hậu quả:** trial không còn là “một lần/thiết bị”; thất thoát doanh thu và không đáp ứng yêu cầu “không bypass dễ dàng bằng xoá app data/reinstall”. Đây là giới hạn kiến trúc local-only, không phải crash.
- **Đề xuất fix:** nếu yêu cầu thật sự là one-device/one-trial, cần backend/account entitlement hoặc Play Integrity + server-issued claim. Nếu bắt buộc offline, đổi đặc tả thành “best effort”, mặc định tắt trial trên Android, hoặc yêu cầu host tự cấp trial sau xác thực account. Không nên quảng bá Auto Backup như một anti-abuse guarantee.

### MAJOR-2 — Mã VIP offline chỉ one-time trên từng thiết bị, có thể chia sẻ/replay trên nhiều thiết bị

- **Dẫn chứng:** `lib/src/vip/vip_manager.dart:1237-1246`, `lib/src/vip/vip_manager.dart:1375-1406`, `lib/src/vip/_redeemed_key_ledger.dart:9-25`, `lib/src/vip/_redeemed_key_ledger.dart:79-99`.
- **Lỗi:** Ed25519 bảo vệ tính xác thực của payload tốt — public key nhúng trong app không giúp forge chữ ký — nhưng replay ledger hoàn toàn local. `kid` chỉ được kiểm tra trong prefs/Keychain của thiết bị hiện tại; không có global claim. Vì vậy cùng một code hợp lệ có thể redeem một lần trên mỗi thiết bị. Yêu cầu “có mạng” ở `redeemSignedKey()` không thay đổi điều này vì không có request claim tới server.
- **Kịch bản:** một khách hàng mua/nhận code AVP1/AVP2 rồi đăng code công khai; N thiết bị online nhập cùng code trước khi CRL mới được phát hành → cả N đều pass signature và local ledger → mỗi thiết bị nhận VIP. AVP2 chỉ khóa theo bundle ID, không khóa theo user/device. Trên Android, cùng một thiết bị còn có thể replay sau reinstall nếu prefs backup không restore vì durable ledger là iOS-only.
- **Hậu quả:** không thể bảo đảm code bán ra là single-use toàn hệ thống; revoke chỉ có tác dụng sau khi host tải được CRL và không thu hồi tức thời entitlement đã cấp (có grace window).
- **Đề xuất fix:** dùng backend atomic claim theo `kid`/account/device và trả signed entitlement ngắn hạn; giữ Ed25519 để verify entitlement offline sau claim. Nếu tuyệt đối không backend, phải ghi rõ “one use per local install/device, transferable code”, phát code thời hạn ngắn, refresh CRL bắt buộc trước redeem và chấp nhận replay là rủi ro không thể loại bỏ.

### MAJOR-3 — Banner/MREC vẫn refresh/request khi bị ẩn trong `IndexedStack` không có `TickerMode`

- **Dẫn chứng:** `lib/src/widget/banner_ad_widget.dart:30-38`, `lib/src/widget/banner_ad_widget.dart:93-110`, `lib/src/widget/banner_ad_widget.dart:202-210`, `lib/src/widget/mrec_ad_widget.dart:27-28`, `lib/src/widget/mrec_ad_widget.dart:56-59`.
- **Lỗi:** visibility detection chỉ dựa vào `RouteAware` và `TickerMode`. Một `IndexedStack` thông thường giữ các child mounted, không push/pop route và không tự đổi `TickerMode`; vì vậy `didPushNext()` không chạy. AppLovin platform view tiếp tục auto-refresh; AdMob object vẫn sống và có thể tiếp tục refresh dù tab không nhìn thấy. Source đã tự ghi nhận đây là policy risk, nhưng workaround chỉ nằm trong documentation và API không cưỡng chế được.
- **Kịch bản:** app có bottom navigation bằng `IndexedStack(index: selectedTab, children: [... BannerAdWidget() ...])`; user chuyển sang tab khác → banner/MREC cũ offstage nhưng không dispose/pause → provider tiếp tục request ad không visible trong suốt thời gian tab ẩn.
- **Hậu quả:** impression/request không gắn với viewability, tốn quota và có rủi ro vi phạm chính sách traffic chất lượng của cả AdMob/MAX; mức độ đáng kể vì `IndexedStack` là pattern Flutter phổ biến.
- **Đề xuất fix:** cung cấp visibility contract bắt buộc (`active`/`visible` parameter hoặc controller) và dispose/pause khi false; tích hợp `visibility_detector` nếu chấp nhận dependency; hoặc cung cấp widget tab wrapper chính thức. Ít nhất integration self-check/debug overlay nên cảnh báo khi ad platform view không paint nhưng vẫn active. Áp dụng đồng nhất cho banner và MREC.

## Các vùng đã kiểm chứng, không phát hiện regression mới

- **Provider/platform:** AdMob và AppLovin có adapter riêng cho app-open/interstitial/rewarded/banner; AppLovin không nhận COPPA runtime nhưng SDK fail-closed/không init provider đó cho child-directed session (`lib/src/adapters/applovin_adapter.dart:673-700`). Đây là thiếu capability upstream đã được xử lý an toàn, không phải đường âm thầm chạy sai.
- **Offline/retry:** connectivity watch có generation guard, timeout, cancel subscription/debounce khi teardown và chỉ refill trên offline→online; refill còn gate VIP/daily cap (`lib/src/core/ad_manager.dart:7588-7630`, `lib/src/core/ad_manager.dart:7632-7684`, `lib/src/core/ad_manager.dart:7687-7726`). Không thấy retry loop vô hạn hoặc tạo “loaded” giả.
- **Fullscreen lifecycle:** slot state chặn double-show; callback/timeout/dispose paths hiện có test regression cho late callback, dispose-while-showing và native teardown. Không phát hiện đường mới hiển thị sau host `State.dispose()` trong API `AdScreen`.
- **Consent:** epoch root ở `ConsentManager` bảo vệ `set/reset/apply` sau async gap (`lib/src/consent/consent_manager.dart:87-107`, `lib/src/consent/consent_manager.dart:202-209`, `lib/src/consent/consent_manager.dart:228-265`); epoch thứ hai ngay trước provider write ở `AdManager.setConsent()` vẫn còn (`lib/src/core/ad_manager.dart:3850-3869`, `lib/src/core/ad_manager.dart:4029-4037`). AdMob nhận COPPA/TFUA; AppLovin nhận consent/do-not-sell trước init; TCF/GPP được reconcile. Không thấy site provider-write mới thiếu guard ngoài caveat COPPA-flip đã document và tự lành qua re-init.
- **Policy khác:** không có code auto-click; fullscreen arbitration/caps tồn tại; test-device IDs được giữ khi thay `RequestConfiguration` (`lib/src/core/ad_consent.dart:177-209`). Privacy policy/options vẫn cần host cấu hình/publish UMP đúng app ID — package không thể tự bảo đảm cấu hình console của app tiêu thụ.

## Điểm tổng thể

**8.6/10**

## Kết luận production

**CÓ thể đưa SDK vào production app thông thường, nhưng KHÔNG nên tuyên bố trial/VIP code là chống abuse hoặc single-use toàn hệ thống ở trạng thái hiện tại.** Trước khi dùng code VIP như hàng hóa có giá trị hoặc trial 1 ngày là yêu cầu kinh doanh cứng, phải xử lý **MAJOR-1 và MAJOR-2 bằng server-side claim/account entitlement**, hoặc chính thức chấp nhận và công bố giới hạn offline. Với app dùng bottom navigation `IndexedStack`, phải xử lý **MAJOR-3** ở host (bọc `TickerMode`/`Visibility` hoặc truyền trạng thái active) trước production để tránh request quảng cáo khi tab ẩn.

## Kiểm chứng thực thi

- `flutter analyze`: **No issues found**.
- `flutter test`: **1640 tests passed**.
- Không chạy device integration trong round này; các kết luận platform-native ngoài phần đã có test cần được smoke lại trên Android/iOS thật khi nâng plugin/native SDK.
