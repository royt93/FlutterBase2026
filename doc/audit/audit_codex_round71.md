# Audit độc lập — Codex — 2026-09-21

**Scope.** Đọc source package `packages/ad_sdk` (pubspec `3.0.10`), example,
README/CHANGELOG và lịch sử `doc/audit/`; không sửa source. Tôi tự kiểm tra lại
các sửa trước đây thay vì coi chúng là đúng. `flutter test` trong
`packages/ad_sdk` hoàn tất thành công: **2,218 tests passed**.

## Tóm tắt kiểm tra không phát hiện lỗi mới

- Hai adapter đều có banner, interstitial, rewarded và app-open; các đường
  load/show đều đi qua gate chung (`canRequestAds`, VIP, connectivity). Retry
  có generation guard; `destroy()` hủy connectivity subscription và debounce
  timer tại `lib/src/core/ad_manager.dart:9023-9075`. Không thấy auto-click,
  ép reward, hoặc app-open được show khi có dialog: ownership/visibility được
  kiểm tra trong manager và test suite lifecycle phủ cả hai adapter.
- Offline/reconnect được xử lý fail-safe: load inline bỏ qua khi offline
  (`ad_manager.dart:8616-8640`), reconnect được debounce và chỉ refill khi
  online (`:9077-9169`); UMP network failure giữ gate đóng và retry hữu hạn
  (`:3814-3845`, `:8933-9026`).
- Fix GPP hai segment của round 56 vẫn đúng: toàn bộ parser GPP tạo
  `_GppBitReader`, và constructor lấy Core Segment trước dấu chấm
  (`lib/src/core/iab_storage.dart:21-37`). Vì vậy GPC segment không còn làm
  mất US opt-out. TCF/GPP/US Privacy được hợp nhất theo hướng opt-out thắng.
- Ed25519 kiểm chữ ký đúng; chống double-tap cùng process là atomic nhờ
  `_signedKidsInFlight` (`lib/src/vip/vip_manager.dart:1421-1429`). Đây không
  phải lỗi forge mới. COPPA AdMob được đặt trước native init
  (`lib/src/adapters/admob_adapter.dart:462-481`); MAX fail-closed khi đã biết
  child-directed state. Các giới hạn sản phẩm còn lại được nêu trong README.

## Findings

### MAJOR — Auto-UMP không thật sự hoàn tất trước khi native provider khởi tạo

**Vị trí:** `lib/src/core/ad_manager.dart:3718-3792,3850-3865`;
`lib/src/adapters/applovin_adapter.dart:819-891`;
`lib/src/adapters/admob_adapter.dart:462-481`; tài liệu trái với hành vi tại
`README.md:513-517`.

Khi `autoRequestUmpConsent` (mặc định `true`), manager đóng gate ad rồi cố ý
không `await requestUmpConsent()`. Ngay sau khi spawn flow, nó gọi
`adapter.initialize()`. Do đó MAX `initialize` và AdMob `MobileAds.initialize`
(cùng mediation init/config) có thể chạy khi UMP form còn đang chờ người dùng,
trái với log/comment "before adapter init" và README "before touching either
ad provider". Gate chỉ ngăn `load/show` do SDK gọi sau đó; nó không chứng minh
native SDK init không có traffic/thu thập dữ liệu, nhất là mediation adapters.
Test hiện tại chỉ chứng minh *lời gọi* UMP được khởi phát trước native init
(`test/consent_persistence_on_init_test.dart:109-119`), không giữ Future UMP
pending để chứng minh thứ tự completion.

Rủi ro là EEA/UK user có thể bị khởi tạo provider trước khi CMP có quyết định
và ghi TCF string. Đây là rủi ro compliance đáng kể, dù request ad thông thường
đã được gate tốt.

**Đề xuất:** nếu SDK tuyên bố UMP-owned consent trước provider, tách trạng thái
"initializing / waiting for consent" và chỉ initialize adapter sau khi UMP
hoàn tất (hoặc thay đổi tài liệu để yêu cầu host await UMP trước `initialize`
và không tự đưa ra bảo đảm này). Thêm test với UMP completer chưa hoàn thành và
assert native bridge `initialize` chưa bị gọi. Không nên giải quyết bằng
fail-open khi UMP/network lỗi.

### MAJOR — Trial 24 giờ mặc định dễ nhận lại trên Android sau reinstall/data clear

**Vị trí:** `lib/src/vip/_first_install_guard.dart:137-155,168-196`;
`lib/src/core/ad_manager.dart:3523-3547`.

Trong release Android, `hasAlreadyGranted()` luôn trả `false` và `markGranted()`
luôn no-op. Manager vì thế cấp lại `FirstInstallVipGrace.auto` (24 giờ) ở mỗi
reinstall khi SharedPreferences đã mất; clear app data cũng có cùng bản chất.
High-water local chỉ giảm clock rollback sau khi đã có state, không tạo được
identity/timestamp đáng tin cậy sau reinstall. Code và README thừa nhận đây là
chủ đích, nhưng nó không đáp ứng yêu cầu trial "không bypass dễ dàng".

**Đề xuất:** với trial mang giá trị kinh tế, dùng entitlement/claim server-side
(hoặc Play Integrity + backend) và một định danh install/entitlement phía
server; nếu phải offline hoàn toàn, vô hiệu hóa trial Android hoặc công khai nó
chỉ là grace per-install, không phải one-day trial chống abuse. Không có
SharedPreferences/Auto Backup thuần client nào bảo đảm được mục tiêu này.

### MAJOR — VIP code là bearer credential replay được vô hạn giữa thiết bị; expiry cũng không có nguồn thời gian tin cậy

**Vị trí:** `lib/src/vip/vip_manager.dart:1246-1265,1286-1304,1306-1391`;
`lib/src/vip/signed_vip_key.dart:88-100,118-120,218-222`;
`tool/vip_mint.dart:24-25,70-80`.

Ed25519 ngăn forge nếu private key an toàn, nhưng một AVP2 hợp lệ có thể được
redeem một lần trên *mỗi* thiết bị; connectivity gate chỉ là boolean cục bộ,
không hề claim `kid` với server. AVP1 vẫn được mint/accept và không expiry,
không app binding. Với AVP2, `expiresAt` được so với `_effectiveNow()` từ clock
thiết bị; trên máy mới/reinstall chưa có high-water, đổi clock về trước expiry
rồi kết nối mạng vẫn vượt expiry. CRL chỉ có tác dụng khi host phân phối CRL
mới và thiết bị nhận/kiểm được nó, không thể thu hồi tức thời hay one-time use
toàn cục.

Đây là giới hạn được tài liệu hóa nhưng là MAJOR nếu code VIP bán/giá trị cao:
một mã rò rỉ có thể cấp entitlement cho không giới hạn máy, không phải lỗi race
trong một process.

**Đề xuất:** redeem/claim `kid` tại backend nguyên tử, bind vào account/device
theo chính sách, và dùng server time cho expiry/revocation. Nếu giữ offline,
bỏ tuyên bố one-time/global expiry, ngừng phát hành AVP1 (chỉ giữ verifier có
deadline migration), dùng AVP2 bundle-bound lifetime ngắn và coi mã là coupon
bearer có thể bị chia sẻ.

### MINOR — Release AdMob luôn ép 17 hash thiết bị của maintainer thành test device; MAX chỉ làm vậy ở debug

**Vị trí:** `lib/src/config/ad_config.dart:213-255,305-309`;
`lib/src/adapters/admob_adapter.dart:471-485`; đối chiếu
`lib/src/adapters/applovin_adapter.dart:882-889`.

`effectiveTestDeviceIds` luôn union `kQaTestDeviceHashes`; AdMob truyền chúng
vào request configuration trong release. Vì vậy người sở hữu những device/build
hash này sẽ luôn nhận test ads và tạo zero monetization trong mọi app consumer,
không có opt-out từ cấu hình host. MAX ngược lại chỉ register test device trong
`kDebugMode`, nên đây cũng là khác biệt dual-provider. README mô tả đây là lựa
chọn chủ đích, nên không phải documentation mismatch, nhưng vẫn là test-ad
leak có chủ đích trong production artifact và làm publisher mất quyền kiểm soát
targeting.

**Đề xuất:** để danh sách mặc định rỗng trong release và chỉ dùng
`AdMobConfig.testDeviceIds` host opt-in; nếu QA release là bắt buộc, cung cấp
một flag explicit/allowlist do app owner cấu hình và cảnh báo build-time. Đồng
bộ chính sách này với MAX.

## README/CHANGELOG đối chiếu

Phần lớn mô tả khớp source, gồm GPP Core Segment fix, QA test-device always-on,
giới hạn Android trial và replay offline VIP. Riêng lời hứa auto-UMP "before
touching either ad provider" không khớp do concurrency ở finding đầu tiên.

## Verdict: CONDITIONAL

**Chưa nên đưa nguyên trạng vào production** cho app có EEA/UK traffic mà dựa
vào auto-UMP, trial cần chống abuse, hoặc VIP code có giá trị thương mại. Chỉ
chấp nhận sau khi host tự await UMP trước provider (hoặc SDK sửa thứ tự native
init), chấp nhận/loại bỏ Android per-install trial, và dùng backend nếu VIP cần
one-time/replay-proof. Ngoài ra app owner cần quyết định rõ có chấp nhận 17
AdMob production test devices hay không.
