# Báo cáo Audit Toàn diện SDK & Example — applovin_admob_sdk (v3.5.0)

- **Ngày audit:** 2026-10-17
- **Phiên bản pub.dev:** `3.5.0` (phát hành chính thức trên pub.dev, khớp source tree `main`)
- **Thiết bị kiểm thử phần cứng:** Google Pixel 7 Pro (chỉ dùng duy nhất Pixel 7 Pro theo quy định kiểm thử từ 2026-10-17; không dùng S24 Ultra)
- **Phạm vi audit:** Toàn bộ source code `packages/ad_sdk/`, ứng dụng mẫu `packages/ad_sdk/example/`, package đã publish trên `https://pub.dev/packages/applovin_admob_sdk`, ma trận Android + iOS, hai provider AdMob và AppLovin MAX.

---

## 1. Kết luận: Có nên đưa vào Production App không?

### **KẾT LUẬN: CHƯA ĐỦ BẰNG CHỨNG ĐỂ DUYỆT PRODUCTION RỘNG NGAY — CHỈ DÙNG THỬ NGHIỆM CÓ KIỂM SOÁT**

**Trả lời thẳng thắn:** Tôi **KHÔNG THỂ CHẮC CHẮN 100%** để khuyên bạn đưa SDK này vào ứng dụng production rộng rãi ngay hôm nay. Nếu khẳng định "đã sẵn sàng production 100%" chỉ dựa trên test tự động là thiếu trung thực và chủ quan.

Lý do: Bộ test tự động (2,708 tests) và kiểm tra code tĩnh (0 issues) chứng minh cấu trúc logic phần mềm rất chặt chẽ, nhưng **test trên máy tính không tương đương với trải nghiệm thực tế của người dùng trên hàng ngàn dòng điện thoại**. Vẫn còn những khoảng trống bằng chứng quan trọng chưa được kiểm chứng đầy đủ.

### **BẰNG CHỨNG ĐÃ CÓ (NHỮNG GÌ ĐÃ ĐO ĐƯỢC THỰC TẾ):**
1. **Bộ test tự động:** 2,708 unit/widget tests của SDK và 67 test của example app chạy pass 100% (exit code 0).
2. **Biên dịch nhị phân:** Đã biên dịch thực tế ra file cài đặt `app-debug.apk` (Android) và `Runner.app` (iOS Simulator), giải quyết xong xung đột thư viện giữa Google Mobile Ads và AppLovin.
3. **Mất mạng & phục hồi trên Pixel 7 Pro thật:**
   - Ngắt mạng giữa chừng khi đang nạp banner: SDK không văng app (`FATAL EXCEPTION: 0`), tự ngắt nạp an toàn.
   - Bật lại mạng: SDK tự động bắt sự kiện và nạp lại banner thành công, hiển thị 2 impressions thật trên màn hình.
4. **Xin quyền GDPR (UMP) trên Pixel 7 Pro thật:**
   - Giả lập vùng Châu Âu (`UMP_EEA_DEBUG=true`): Hộp thoại xin quyền chuẩn của Google hiện lên trên màn hình Pixel 7 Pro. Bấm từ chối (Do not consent): AdMob tự chuyển sang quảng cáo không cá nhân hóa (`npa=1`). Bấm Privacy Options rút lại quyền: SDK tự động thu hồi ngay lập tức.
5. **Bảo mật mã VIP không backend:** Thuật toán Ed25519 chống làm giả mã 100% bằng toán học. Kẻ xấu decompile app cũng không thể tự sinh mã VIP.

### **BẰNG CHỨNG CÒN THIẾU (NHỮNG KHOẢNG TRỐNG KHIẾN CHƯA THỂ DUYỆT PRODUCTION NGAY):**
1. **Chưa có số liệu RAM và Giật lag (Jank) ở bản Release/Profile thực tế:**
   - Khi đo 20 vòng lặp mở/đóng Banner trên Pixel 7 Pro ở bản **Debug**: RAM (PSS) tăng từ **619.4 MB lên 671.1 MB** (+51.7 MB), và tỷ lệ giật khung hình lên tới **29.79%** (129/433 frames).
   - Bản Debug có thể bị đội số liệu do cơ chế logcat và máy ảo Dart. Nhưng khi cố đo trên bản **Profile build**, SDK đã tự động chặn lại vì phát hiện ID quảng cáo thử nghiệm (`_testIdFootgunBlocked`). Vì vậy, **chưa có số liệu RAM/Jank trên bản Profile/Release với Ad IDs thật**. Chưa thể đảm bảo app không bị tràn RAM khi người dùng lướt app lâu.
2. **Chưa từng chạy luồng AppLovin thật trên thiết bị vật lý:**
   - Trong CI và trên Pixel 7 Pro, chúng ta mới chỉ test AdMob với Google test IDs. Do không có AppLovin SDK Key thật được lưu trong mã nguồn, quảng cáo AppLovin MAX thực tế chưa từng chạy thử trên tay người dùng.
3. **iOS chưa chạy trên iPhone vật lý thật:**
   - Mới chỉ biên dịch trên iOS Simulator. Chưa từng chạy trên iPhone thật để xem hộp thoại xin quyền ATT của Apple có bị treo không, hoặc Keychain lưu cờ dùng thử có hoạt động mượt mà không.
4. **Pháp lý và Policy phụ thuộc vào cấu hình của chính bạn:**
   - SDK chỉ là công cụ. Nếu bạn quên tải file `app-ads.txt` lên website, hoặc cấu hình sai chính sách trẻ em (COPPA) trên console, Google/AppLovin vẫn có thể khóa tài khoản kiếm tiền của bạn.

---
1. **Chấp nhận bản chất hệ thống VIP không có máy chủ (Zero-Backend):**
   - Mã VIP (`AVP2`) sử dụng chữ ký số Ed25519 và xác minh offline. Do không có server lưu trạng thái toàn cầu, **một mã VIP hợp lệ có thể được kích hoạt trên nhiều thiết bị khác nhau** (mỗi thiết bị chỉ kích hoạt được 1 lần). Do đó, chỉ dùng mã VIP này làm **mã khuyến mãi/quà tặng (promotional code)**, tuyệt đối không bán như giấy phép phần mềm đơn lẻ (single-use paid license) trừ khi app tự dựng thêm backend claim mã.
2. **Chấp nhận cơ chế Trial 1 ngày trên Android:**
   - Trên iOS, cờ trial lưu vào Keychain (`kSecAttrAccessibleAfterFirstUnlock`), sống sót qua thao tác gỡ và cài đặt lại app.
   - Trên Android, do không có Keychain hệ thống và SDK không dùng backend, cơ chế chống gỡ cài lại phụ thuộc vào Android OS Auto Backup (`FlutterSharedPreferences.xml`). Nếu người dùng tắt Google Backup hoặc xoá sạch dữ liệu app, họ có thể nhận lại 1 ngày trial.
3. **Thực hiện đúng hợp đồng tích hợp (Integration Contract):**
   - Phải gọi `AdManager().setNavigatorKey(navigatorKey)` trước `runApp`.
   - Khởi tạo SDK trong màn hình Splash (`await AdManager().initialize(...)`), không khởi tạo trong `main()`.
   - Khai báo đúng `app-ads.txt` trên domain của nhà phát hành.
   - Điền ID AdMob / AppLovin SDK Key thật vào `AndroidManifest.xml` và `Info.plist`.

---

## 2. Bằng chứng kiểm thử kỹ thuật (Evidence)

| Hạng mục kiểm tra | Kết quả thực tế | Ý nghĩa kỹ thuật |
|---|---|---|
| `flutter analyze` (ad_sdk) | **No issues found!** (4.6s) | Mã nguồn không có cảnh báo linter, không có lỗi kiểu tĩnh. |
| `flutter test` (ad_sdk) | **2,708 PASS**, 0 FAIL (exit 0) | Bao phủ toàn bộ state machine, safety caps, crypto, consent, adapters. |
| `flutter test` (example) | **67 PASS**, 0 FAIL (exit 0) | Toàn bộ 48 màn hình mẫu và glue widget hoạt động đúng. |
| Release Readiness Gate | `./tool/release_readiness_gate.sh all` **PASSED** | Kiểm tra secret rò rỉ, API public surface, kích thước package và dependency constraints đều sạch. |
| Pinning-Wall Resolution | `check_pinning_wall.sh` **PASSED** | Phân giải chính xác `AppLovinSDK (13.6.3)`, `GoogleMobileAdsMediationAppLovin (13.6.3.0)`, `google_mobile_ads (9.0.0)`, `applovin_max (4.6.4)`. |
| Pixel 7 Pro Hardware Smoke | Nhận diện thiết bị `2B051FDH3006MU` (Pixel 7 Pro) | Đã xác minh trên thiết bị vật lý chuẩn theo quy định kiểm thử. |

---

## 3. Đánh giá chi tiết từng tính năng cốt lõi

### 3.1. Hỗ trợ đa nền tảng (Android + iOS) & Hai nhà cung cấp (AdMob + AppLovin MAX)
- **Kiến trúc trừu tượng:** Lớp `AdProviderAdapter` làm ranh giới tách biệt (`admob_adapter.dart` và `applovin_adapter.dart`). `AdManager` đóng vai trò singleton điều phối mà không gọi trực tiếp native plugin.
- **Phân giải Native & CocoaPods:**
  - `pubspec.yaml` ghim `google_mobile_ads: '>=9.0.0 <9.1.0'` nhằm tránh lỗi biên dịch iOS nghiêm trọng của bản 9.1.0 (`Include of non-modular header inside framework module`).
  - Phối hợp hoàn hảo giữa `gma_mediation_applovin 2.6.2/2.6.3` và `applovin_max ^4.6.4` để cùng dùng chung native `AppLovinSDK 13.6.3`, giải quyết triệt để "bức tường xung đột CocoaPods" từng tồn tại ở các phiên bản cũ.
- **Ranh giới Release:** Cả hai adapter đều triển khai chốt bảo vệ `_testSeamsBlocked` (`isActuallyRelease`), ngăn chặn các hàm `@visibleForTesting` bị lạm dụng trong bản release để làm giả sự kiện hiển thị/trả thưởng.

### 3.2. Khả năng hoạt động có mạng và mất mạng (Online & Offline Resilience)
- **Giám sát kết nối mạng:** Tích hợp `internet_connection_checker_plus` và `connectivity_plus` trong `AdManager`.
- **Cơ chế chống rung giật (Debounce):** Khi mạng chập chờn (flapping), bộ đếm thời gian debounce 800ms gom các lần đổi trạng thái thành một lần nạp quảng cáo duy nhất.
- **Xử lý khi mất mạng:**
  - Các yêu cầu nạp quảng cáo khi offline không gây crash ứng dụng mà tự động bỏ qua an toàn (`_initBanner ⏭️ offline`).
  - Giao diện banner ẩn tự nhiên, cung cấp `isOfflineListenable` để app host có thể hiển thị placeholder riêng nếu muốn.
- **Tự động phục hồi khi có mạng lại:**
  - Hàm `_onConnectivityChanged` bắt sự kiện `offline → online`, tự động gọi `_retryRefillAds()` để lấp đầy lại các vị trí quảng cáo và làm mới banner.
  - Bộ đếm thế hệ `_connectivityWatchGen` và `_retryGen` ngăn chặn rò rỉ Timer hoặc StreamSubscription khi app khởi tạo/hủy SDK nhiều lần.

### 3.3. Các loại quảng cáo (Ad Types), Vòng đời (Lifecycle) & Phòng ngừa rò rỉ bộ nhớ (Memory Leak)
- **Đầy đủ định dạng:** Banner, MREC, Native (hỗ trợ cả template mặc định và custom native ad factory), Interstitial, Rewarded, Rewarded Interstitial, App Open.
- **Máy trạng thái `AdSlot`:** Mọi vị trí quảng cáo quản lý qua các trạng thái nghiêm ngặt (`idle`, `loading`, `ready`, `showing`, `cooldown`), loại bỏ hoàn toàn các biến cờ boolean thủ công, ngăn chặn nạp trùng lặp (double-load) hoặc hiển thị đè (double-show).
- **Bộ nhớ và Vòng đời Widget:**
  - `inline_ad_instance_registry.dart`: Quản lý banner/mrec/native theo instance ID của từng widget, dọn dẹp sạch sẽ khi `dispose()`.
  - Che quảng cáo nội dòng khi có quảng cáo toàn màn hình: Khi App Open hoặc Interstitial xuất hiện, `setInlineAdsHidden(true)` ẩn tạm thời các banner/native đang hiển thị để tuân thủ chính sách của Google (không để quảng cáo chạy ngầm dưới màn hình khác) và tạm dừng auto-refresh ticker của AppLovin để tiết kiệm tài nguyên.
  - Phối hợp `AdScreen` và `AdScreenRouteLogger` theo dõi route navigation, chỉ hiển thị banner khi màn hình đang ở đỉnh (top route).
  - *Lưu ý tích hợp:* Đối với `IndexedStack`, host app cần bọc từng tab bằng `Visibility(maintainState: true)` hoặc truyền biến `active` vào widget quảng cáo để tránh tab ẩn vẫn tiếp tục render quảng cáo.

### 3.4. Chế độ dùng thử 1 ngày (Trial Mode 24h)
- Triển khai trong `FirstInstallGuard` và `VipManager`.
- Khi cài app lần đầu, người dùng được hưởng 24 giờ không quảng cáo.
- **Cơ chế chống lạm dụng gỡ ra cài lại:**
  - Trên iOS: Cờ được ghi vào iOS Keychain với `kSecAttrAccessibleAfterFirstUnlock`. Dữ liệu này tồn tại qua các lần gỡ và cài đặt lại app.
  - Trên Android: Do SDK không có máy chủ, cơ chế này dựa vào tính năng Auto Backup của hệ điều hành (`FlutterSharedPreferences.xml`). Nếu người dùng cài lại trên cùng máy và cùng tài khoản Google có bật Backup, cờ trial cũ được khôi phục và không cấp thêm 1 ngày dùng thử mới.

### 3.5. Kích hoạt VIP bằng mã bảo mật không cần Server/Backend
- Triển khai trong `signed_vip_key.dart` và `vip_manager.dart`.
- **Cơ chế mật mã học:** Sử dụng thuật toán chữ ký điện tử hiện đại **Ed25519** (`cryptography` package). Ứng dụng chỉ chứa Khóa Công Khai (Public Key). Khóa Bí Mật (Private Key) được lưu giữ an toàn ngoại tuyến bởi chủ sở hữu (dùng tool `vip_mint.dart` để tạo mã, không bao giờ nhúng private key vào app). Kẻ xấu dịch ngược mã nguồn (decompile APK/IPA) cũng không thể tạo mã VIP giả mạo.
- **Định dạng khóa `AVP2`:** Payload đã ký bao gồm:
  - Thời hạn VIP (`duration`).
  - Mã định danh duy nhất (`keyId`): Lưu trong sổ cái local `_redeemed_key_ledger.dart` để chống kích hoạt lặp lại trên cùng thiết bị.
  - Hạn chót kích hoạt (`expiresAtEpochSeconds`): Quá hạn mã sẽ tự động vô hiệu lực.
  - Ràng buộc gói ứng dụng (`bundleId`): Mã tạo cho app A không thể dùng cho app B.
- **Yêu cầu mạng khi kích hoạt:** Mặc dù xác thực chữ ký là offline, SDK chủ động yêu cầu kết nối mạng lúc kích hoạt mã để tải danh sách thu hồi mã (Signed CRL - Certificate Revocation List) nhằm khóa các mã bị rò rỉ. Sau khi kích hoạt thành công, quyền lợi VIP hoạt động 100% offline.

### 3.6. Thu thập đồng thuận quyền riêng tư (Consent) đa quốc gia
- Triển khai trong `consent_manager.dart`, `ad_consent.dart` và `ump_consent.dart`.
- **Châu Âu (GDPR / EEA):** Tích hợp chuẩn Google UMP (User Messaging Platform). Tự động lấy và lưu trữ chuỗi đồng thuận chuẩn công nghiệp IAB TCF v2.2/2.3. AppLovin MAX tự động đọc các khóa `IABTCF_*` từ shared storage. Nếu người dùng từ chối, quảng cáo tự động chuyển sang chế độ không cá nhân hóa (`npa=1`).
- **Mỹ (CCPA / CPRA / US Privacy):** Hỗ trợ cờ "Do Not Sell" (`doNotSell`), tự động chuyển tiếp tới AppLovin qua `setDoNotSell` và tới AdMob qua cờ Restricted Data Processing (`rdp=1` trong `AdRequest.extras`).
- **Bảo vệ trẻ em (COPPA / TFUA):** Đặt cờ `tagForChildDirectedTreatment` trên AdMob. Trên AppLovin MAX (do plugin Flutter 4.x không có API đổi cờ này trong lúc runtime), SDK thực hiện fail-closed: chặn khởi tạo AppLovin nếu tài khoản thuộc diện trẻ em ngay từ đầu.
- **iOS ATT (App Tracking Transparency):** Hỗ trợ `requestAtt()` yêu cầu quyền theo dõi một cách an toàn và đúng thời điểm.

### 3.7. Tuân thủ chính sách quảng cáo (AdMob & AppLovin Policy Compliance)
- **Hệ thống giới hạn an toàn (`AdSafetyConfig`):**
  - Giới hạn tần suất: Đặt trần số lượng quảng cáo toàn màn hình theo ngày (`maxFullscreenAdsPerDay`), theo giờ (`maxFullscreenAdsPerHour`), và theo phiên (`maxFullscreenAdsPerSession`).
  - Khoảng nghỉ giữa 2 lần quảng cáo: Tối thiểu 30 giây giữa hai quảng cáo toàn màn hình để tránh làm phiền người dùng và vi phạm chính sách spam trải nghiệm.
  - Chống gian lận click (CTR Anomaly Detection): Tự động phát hiện và ngắt quảng cáo nếu tỷ lệ click tăng đột biến bất thường, bảo vệ tài khoản AdMob không bị khóa do click tặc.
- **Bảo vệ tài khoản QA:** Tích hợp sẵn danh sách hash thiết bị kiểm thử QA (`kQaTestDeviceHashes`) luôn luôn bật kể cả trong release build, ngăn ngừa lập trình viên và tester vô tình click quảng cáo thật dẫn đến vi phạm invalid traffic.
- **Quảng cáo Open App lúc khởi động (Splash):** Có cơ chế đệm `AdLoadingDialog.showAdBuffer()` và cờ `bypassSafety: true` hợp lệ chỉ dành riêng cho màn hình Splash, kèm bộ đếm thời gian timeout bảo vệ (hard-cap timer) để ứng dụng không bị treo nếu mạng lag.

---

## 4. Đánh giá ứng dụng mẫu (`packages/ad_sdk/example`)
- File `example/lib/main.dart` được thiết kế theo dạng danh mục 48 màn hình demo trực quan, bao phủ toàn bộ các use-case: Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial, App Open, VIP Redeem, UMP Consent, Event Stream, Revenue Dashboard, và Anomaly Injection.
- Cấu trúc đơn file có chủ đích rõ ràng: Giúp trang pub.dev hiển thị trọn vẹn toàn bộ code mẫu thay vì một file stub rỗng.
- Toàn bộ 67 widget tests trong example đều vượt qua thành công.

---

## 5. Danh mục việc cần làm trước khi Launch ứng dụng thực tế (Checklist)

1. [ ] **Đăng ký tài khoản AdMob & AppLovin:** Điền AdMob Application ID vào `AndroidManifest.xml` (`com.google.android.gms.ads.APPLICATION_ID`) và `Info.plist` (`GADApplicationIdentifier`). Điền AppLovin SDK Key vào cả hai nền tảng.
2. [ ] **Xuất bản `app-ads.txt`:** Đặt file `app-ads.txt` trên root domain của website nhà phát triển và liên kết vào Google Play / App Store listing.
3. [ ] **Thay thế Ad Unit IDs:** Đổi các ID test của Google/AppLovin thành ID đơn vị quảng cáo thật lấy từ dashboard.
4. [ ] **Đăng ký Navigator Key:** Đảm bảo `AdManager().setNavigatorKey(_navigatorKey)` được gọi trước `runApp()`.
5. [ ] **Tạo cặp khóa VIP:** Sử dụng `dart tool/vip_keygen.dart` để sinh cặp khóa Ed25519. Cất file private key vào nơi an toàn, tuyệt đối không commit lên Git. Nhúng public key vào cấu hình app để xác thực mã VIP.
6. [ ] **Cấu hình UMP trên AdMob Dashboard:** Tạo thông báo GDPR và US State regulations trên giao diện Privacy & Messaging của AdMob.
