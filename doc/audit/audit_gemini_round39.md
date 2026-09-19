# Báo cáo Audit toàn diện — applovin_admob_sdk (Round 39)
**Phiên bản:** `2.9.18` (commit `1af945e`)  
**Môi trường kiểm thử:** Flutter 3.x, Dart 3.x, macOS, phân tích tĩnh `flutter analyze` (0 cảnh báo) và bộ test tự động `1640/1640 test passed`.

---

## 1. Tóm tắt tổng quan (Executive Summary)
SDK `applovin_admob_sdk` ở phiên bản `2.9.18` đã đạt mức độ hoàn thiện và độ ổn định rất cao sau các vòng lặp refactor và hardening kỹ thuật từ Round 1 đến Round 38. Toàn bộ các cơ chế cốt lõi — bao gồm dual-provider abstraction (AdMob / AppLovin MAX), vòng đời quảng cáo gắn liền với Route/Widget, chính sách an toàn (AdSafety / CTR threshold / AdBuffer), xử lý mất mạng & backoff, consent đa quốc gia (GDPR/UMP, US-State GPP 21 bang, COPPA, ATT) với cơ chế epoch synchronization chống race condition 2 tầng, và kích hoạt VIP offline bằng mật mã học bất đối xứng Ed25519 — đều hoạt động chính xác, đồng bộ và phòng thủ vững chắc. Không phát hiện lỗi nghiêm trọng (BLOCKER hay MAJOR).

---

## 2. Đánh giá chi tiết theo 7 hạng mục yêu cầu

### Hạng mục 1: Tương thích Provider AdMob & AppLovin trên Android và iOS
- **Trạng thái:** ✅ **ĐẠT CHUẨN & ĐỒNG BỘ**
- **Dẫn chứng source code:**
  - `lib/src/adapters/admob_adapter.dart` và `lib/src/adapters/applovin_adapter.dart`.
  - Cả hai adapter đều tuân thủ interface `AdProviderAdapter` và `InlineAdVisibility`.
  - **Khác biệt nền tảng được xử lý triệt để:**
    - App Open ad lifecycle trên iOS hiển thị dưới dạng modal view controller trong ứng dụng (Flutter app giữ trạng thái `resumed`), trong khi trên Android thì app chuyển sang background/paused. `AppLovinAdapter` xử lý chính xác sự khác biệt này qua `foregroundMeansHung = defaultTargetPlatform != TargetPlatform.iOS` (`applovin_adapter.dart:1347`).
    - Định dạng `RewardedInterstitial`: AdMob hỗ trợ native (`gma_bridge.dart:320`), còn AppLovin MAX không có định dạng riêng tương đương (`applovin_adapter.dart:191`) → slot được giữ ở trạng thái idle an toàn, không gây crash hay deadlock.
    - Native Ad: AdMob hỗ trợ Native Template (`TemplateType.medium`/`small`), AppLovin MAX sử dụng `MaxNativeAdView` kèm nhãn huy hiệu "Ad" do SDK tự vẽ (`native_ad_widget.dart:371-392`) đảm bảo đúng quy chuẩn hiển thị.

### Hạng mục 2: Ứng xử khi có mạng / mất mạng (Online & Offline Resilience)
- **Trạng thái:** ✅ **ĐẠT CHUẨN AN TOÀN**
- **Dẫn chứng source code:**
  - `lib/src/state/backoff.dart:21-37`: Thuật toán Exponential Backoff `compute(consecutiveFailures)` có cơ chế chống tràn số nguyên 64-bit (`iterations <= 62` và loop doubling với `shifted < maxMs`), chặn đứng lỗi sụp đổ backoff về mức sàn khi số lần fail lớn (đã fix triệt để ở round 37).
  - `lib/src/state/ad_retry_policy.dart`: Cung cấp chính sách retry linh hoạt theo từng slot với jitter ngẫu nhiên để tránh hiện tượng dồn yêu cầu (thundering herd), cùng tùy chọn `resetOnConnectivityRestored` khi có mạng trở lại.
  - Khi offline, các yêu cầu load quảng cáo được chặn ngay từ lớp ngoài thông qua `if (!mgr.isConnected)` mà không kích hoạt gọi hàm platform channel gây crash hay ném unhandled network exception.

### Hạng mục 3: Vòng đời 4 loại quảng cáo (Banner, App Open, Rewarded, Interstitial) & Widget Lifecycle
- **Trạng thái:** ✅ **HOÀN THIỆN & KHÔNG LEAK**
- **Dẫn chứng source code:**
  - **Banner & MREC (`banner_ad_widget.dart`, `mrec_ad_widget.dart`):**
    - Tích hợp `RouteAware`: Khi màn hình bị che khuất bởi route khác, AdMob banner tự động dispose/hủy (do GMA không có API pause) và tải lại khi route quay lại; AppLovin banner tự động tạm dừng auto-refresh (`_holdAppLovinInline`).
    - Nhận biết `TickerMode` / `Visibility(maintainState: true)` để tạm dừng làm mới khi tab bị ẩn.
    - Xử lý thay đổi kích thước / xoay màn hình responsive qua `_admobWidthPx` trong `didChangeDependencies` (`banner_ad_widget.dart:75`).
  - **Native Ad (`native_ad_widget.dart`):**
    - Khắc phục triệt để lỗi Round 38 (MAJOR-1): Hàm `_onNativeErrorChanged` gọi `AdManager().disposeNativeInstance(this)` trước khi kích hoạt `_initNative()` sau 30 giây (`native_ad_widget.dart:144`), đảm bảo bundle lỗi cũ của AppLovin được dọn dẹp sạch sẽ, cho phép `MaxNativeAdView` tái tạo thành công.
  - **Fullscreen Ads (`AdScreen`, `AdManager`):**
    - Sử dụng `AdLoadingDialog.showAdBuffer` tạo khoảng đệm 500ms trước khi bung quảng cáo để chống click nhầm.
    - Kiểm tra nghiêm ngặt `mounted` và `_isDisposed` trước và sau các bước bất đồng bộ.
    - Cơ chế Delivery Guard đảm bảo callback kết quả quảng cáo (`onEarnedReward`, `onDoneFlow`) được gọi duy nhất 1 lần, kể cả khi callback của host ném ngoại lệ (`_delivered` tracking guard).

### Hạng mục 4: Trial mode 1 ngày (First-Install Grace)
- **Trạng thái:** ✅ **ĐẠT YÊU CẦU & BẢO VỆ CHẶT CHẼ**
- **Dẫn chứng source code:**
  - `lib/src/vip/_first_install_guard.dart:87-148`:
    - Trên **iOS**: Cờ `ad_sdk_first_install_granted_v1` được lưu trữ vào iOS Keychain thông qua `FlutterSecureStorage` với quyền `KeychainAccessibility.first_unlock`. Do Keychain trên iOS không bị xóa khi người dùng gỡ cài đặt ứng dụng, hành vi xóa app rồi cài lại để "farm" 24h miễn phí quảng cáo bị chặn hoàn toàn.
    - Trên **Android**: Dựa vào cơ chế Android Auto Backup (`FlutterSharedPreferences.xml`) để khôi phục cờ khi cài lại trên cùng tài khoản Google. (Việc xóa dữ liệu cục bộ không giữ được Keychain trên Android là giới hạn kiến trúc hệ điều hành đã được ghi nhận rõ ràng trong tài liệu kỹ thuật).
  - `lib/src/vip/vip_manager.dart:365-381` (`_effectiveNow`): Bảo vệ chống tua ngược đồng hồ thiết bị (clock rollback) bằng cách đối chiếu thời gian hệ thống với giá trị mốc cao nhất từng ghi nhận (`vipMaxObservedClockMs`) và `Stopwatch` monotonic trong phiên.

### Hạng mục 5: Kích hoạt VIP offline bằng mã ký (Ed25519) — Không cần Backend Server
- **Trạng thái:** ✅ **AN TOÀN MẬT MÃ CAO**
- **Dẫn chứng source code:**
  - `lib/src/vip/signed_vip_key.dart` và `lib/src/vip/vip_manager.dart`:
    - **Chống giả mạo chữ ký (Signature Forgery):** Sử dụng thuật toán bất đối xứng Ed25519 (`cryptography` package). Private key chỉ nằm ở công cụ sinh mã offline (`tool/vip_mint.dart`) và không bao giờ đóng gói vào ứng dụng. Client chỉ giữ public key 32-byte, do đó dù kẻ xấu decompile APK/IPA cũng không thể tạo ra mã VIP hợp lệ mới.
    - **Định dạng AVP2:** Payload ký bao gồm `<duration>|<keyId>|<expiresAtEpochSeconds>|<bundleId>` (`signed_vip_key.dart:89-98`). Việc ký kèm thời hạn hết hạn mã và `bundleId` giúp vô hiệu hóa việc mang mã sang ứng dụng khác hoặc dùng mã đã quá hạn.
    - **Chống tấn công Replay trên cùng thiết bị:** Lưu trữ danh sách `keyId` đã sử dụng vào `RedeemedKeyLedger` (lưu bền vững trong iOS Keychain và Android Secure Storage).
    - **Yêu cầu mạng khi kích hoạt:** Hàm `redeemSignedKey` yêu cầu kiểm tra có kết nối internet tại thời điểm nhập mã (`vip_manager.dart:63-69`) nhằm hạn chế việc chia sẻ mã hàng loạt ngoại tuyến.
    - **Cơ chế thu hồi (Revocation / CRL):** Hỗ trợ nạp danh sách thu hồi ký điện tử (`VipRevocationProvider`) kèm kiểm tra tính lũy tiến thời gian `issuedAt` và khóa công khai xác thực (`_revocationVerifiedUnder`), chống tấn công phát lại CRL cũ.

### Hạng mục 6: Quản lý Consent đa quốc gia (GDPR/UMP, US-State GPP, COPPA, ATT)
- **Trạng thái:** ✅ **HOÀN TOÀN TUÂN THỦ & ĐỒNG BỘ RỦI RO RACE CONDITION**
- **Dẫn chứng source code:**
  - `lib/src/core/iab_storage.dart:48-83, 150-180`: Đọc song song (`Future.wait`) chuỗi tín hiệu IAB TCF v2.3 và 21 bang Hoa Kỳ theo chuẩn GPP (California, Virginia, Colorado, Utah, Connecticut, Florida, Texas, v.v.), đảm bảo thứ tự ưu tiên chính xác.
  - `lib/src/core/ad_consent.dart:142-233` (`applyConsentToProviders`): Đồng bộ cờ consent cho cả AdMob (`RequestConfiguration`) và AppLovin (`AppLovinMAX.setHasUserConsent`, `setDoNotSell`).
  - **Bảo vệ chống Race Condition (Đã verify kỹ Round 38):**
    - `ConsentManager` sử dụng `_applyEpoch` bảo vệ độc lập toàn bộ các luồng `set()`, `reset()`, và `applyToProviders()` (`consent_manager.dart:101, 203, 229, 250`).
    - `AdManager.setConsent()` có thêm lớp guard `_consentIntentEpoch` ngay trước khi ghi xuống native provider (`ad_manager.dart:4031-4049`).
    - `_lastAppliedToProviders` chỉ được cập nhật khi **cả hai** provider áp dụng thành công mà không phát sinh ngoại lệ (`ad_consent.dart:230`).

### Hạng mục 7: Tuân thủ chính sách AdMob & AppLovin (Policy Compliance)
- **Trạng thái:** ✅ **TUÂN THỦ CHẶT CHẼ**
- **Dẫn chứng source code:**
  - **Frequency Capping & Tần suất an toàn:** `lib/src/core/ad_safety_config.dart` cấu hình mặc định mức sản xuất nghiêm ngặt (tối đa 6 ad/session, 3 ad/giờ, 5 ad/ngày, giãn cách tối thiểu 60s giữa các fullscreen ad, giới hạn rapid resume tối đa 3 lần/phút).
  - **Bảo vệ lưu lượng bất thường (Invalid Traffic):** Tự động đình chỉ hiển thị quảng cáo khi tỷ lệ nhấp chuột CTR vượt ngưỡng đáng ngờ (`suspiciousCtrThreshold = 30%`), hoặc phát hiện spam click (>3 click/phút).
  - **Tránh che khuất nội dung & hiển thị đè:** Tự động ẩn toàn bộ banner/MREC khi fullscreen ad xuất hiện thông qua `setInlineAdsHidden(true)` (`admob_adapter.dart:37`, `applovin_adapter.dart:52`).
  - **Bảo toàn Test Devices:** Hàm `applyConsentToProviders` luôn truyền kèm `testDeviceIds` khi gọi `MobileAds.instance.updateRequestConfiguration(cfg)` (`ad_consent.dart:180-183`), triệt tiêu rủi ro bị xóa whitelist thiết bị test dẫn đến vi phạm chính sách hiển thị ad thật trong môi trường phát triển.
  - **Release Guard:** `isActuallyRelease()` (`release_mode.dart:10`) ép buộc tắt cờ `dryRun` trong môi trường Release thực tế, ngăn ngừa việc vô tình bypass các lớp bảo vệ chính sách.

---

## 3. Danh sách các phát hiện & Quan sát kỹ thuật (Findings & Observations)

### Finding 1: Giới hạn tự nhiên của mô hình xác thực VIP hoàn toàn offline đối với Replay Attack đa thiết bị
- **Mức độ nghiêm trọng:** `MINOR` (Kiến trúc / Trade-off đã ghi nhận)
- **Vị trí file:** `lib/src/vip/signed_vip_key.dart:119-120`, `lib/src/vip/vip_manager.dart:63-69`
- **Mô tả chi tiết:**
  - Trong mô hình xác thực chữ ký offline không máy chủ (pure offline cryptography), một mã ký hợp lệ định dạng `AVP1` hoặc `AVP2` nếu bị chia sẻ công khai có thể được kích hoạt trên nhiều thiết bị vật lý khác nhau (mỗi thiết bị kích hoạt 1 lần do `RedeemedKeyLedger` chỉ lưu trữ cục bộ).
- **Kịch bản xảy ra:**
  - Người dùng A mua 1 mã VIP AVP1 (hoặc AVP2 chưa hết hạn `expiresAtEpochSeconds`), sau khi kích hoạt thành công trên máy A, chia sẻ chuỗi ký tự đó cho người dùng B trên máy khác; người dùng B vẫn có thể kích hoạt thành công trên máy B nếu máy B có kết nối mạng tại thời điểm bấm Redeem.
- **Đánh giá & Khuyến nghị:**
  - Đây là giới hạn toán học tất yếu của mọi hệ thống phi tập trung không có server trung tâm kiểm soát trạng thái giao dịch toàn cầu.
  - SDK đã giảm thiểu rủi ro này bằng các biện pháp tối ưu nhất có thể cho giải pháp offline:
    1. Chuẩn mã `AVP2` giới hạn thời hạn đổi mã (`expiresAtEpochSeconds`) và giới hạn theo định danh gói ứng dụng (`bundleId`).
    2. Cơ chế danh sách thu hồi mã CRL (`VipRevocationProvider`) cho phép ứng dụng cập nhật danh sách các key bị leak/hoàn tiền.
    3. Ràng buộc `isConnectedCheck` tại thời điểm đổi mã.
  - **Đề xuất:** Khuyến nghị các ứng dụng phát hành mã VIP nên luôn sử dụng định dạng `AVP2` với thời gian `expiresAtEpochSeconds` ngắn (ví dụ: mã có hiệu lực kích hoạt trong vòng 7-30 ngày kể từ ngày cấp phát).

### Finding 2: Giới hạn lưu trữ bền vững của Android đối với First-Install Grace khi xóa toàn bộ dữ liệu ứng dụng
- **Mức độ nghiêm trọng:** `MINOR` (Hạn chế nền tảng Android)
- **Vị trí file:** `lib/src/vip/_first_install_guard.dart:27-48`
- **Mô tả chi tiết:**
  - Trên hệ điều hành iOS, Keychain được giữ nguyên qua các lần gỡ và cài đặt lại app. Ngược lại, trên Android, không có vùng nhớ an toàn cấp ứng dụng nào tồn tại độc lập sau khi người dùng thực hiện thao tác "Clear Data / Xóa bộ nhớ" trong Cài đặt hệ thống (trừ khi can thiệp lấy Hardware/IMEI ID - hành vi vi phạm chính sách Google Play Privacy).
- **Kịch bản xảy ra:**
  - Người dùng Android vào *Cài đặt > Ứng dụng > Xóa toàn bộ dữ liệu*, hoặc gỡ cài đặt app trên thiết bị đã tắt tính năng Google Auto Backup; khi mở lại app, hệ thống sẽ cấp lại 24h dùng thử miễn phí.
- **Đánh giá & Khuyến nghị:**
  - SDK đã giải quyết bài toán theo hướng cân bằng hợp lý: ưu tiên bảo vệ trải nghiệm người dùng hợp pháp (fail-open) và tận dụng Android Auto Backup (`FlutterSharedPreferences.xml`). Giải pháp này hoàn toàn phù hợp với tiêu chuẩn phát triển ứng dụng di động hiện đại.

### Finding 3: Giới hạn API của AppLovin MAX đối với lệnh đóng quảng cáo cưỡng bức (Dismiss Ad) khi Teardown
- **Mức độ nghiêm trọng:** `NITPICK` (Giới hạn nền tảng bên thứ ba)
- **Vị trí file:** `lib/src/adapters/applovin_adapter.dart:895-909`
- **Mô tả chi tiết:**
  - Khi ứng dụng gọi `AdManager().destroy()` trong lúc một quảng cáo toàn màn hình của AppLovin đang được người dùng xem, SDK native của AppLovin MAX không cung cấp API đóng quảng cáo theo lệnh (programmatic dismiss).
- **Đánh giá & Khuyến nghị:**
  - SDK đã bổ sung log cảnh báo chi tiết và đảm bảo dọn dẹp an toàn các tài nguyên phía Dart mà không làm treo ứng dụng hay gây rò rỉ bộ nhớ. Không cần chỉnh sửa thêm.

---

## 4. Bảng tổng hợp đánh giá

| Tiêu chí Audit | Trọng số | Đánh giá | Ghi chú |
|---|---|---|---|
| **Dual-Provider Parity (Android/iOS)** | 15% | 10/10 | Đồng bộ tuyệt đối, xử lý đúng các khác biệt kiến trúc |
| **Online / Offline Resilience** | 15% | 10/10 | Backoff chống tràn số, không lặp vô hạn, không crash |
| **4 Ad Types & Lifecycle** | 20% | 9.8/10 | RouteAware, TickerMode, dọn dẹp Native Ad chuẩn Round 38 |
| **1-Day Trial Mode** | 10% | 9.5/10 | iOS Keychain anti-bypass, chống rollback giờ máy |
| **Offline VIP (Ed25519)** | 15% | 9.5/10 | Chữ ký bất đối xứng, AVP2 bundle & expiry binding, CRL |
| **Consent & Privacy Compliance** | 15% | 9.8/10 | 2-layer epoch guard chống race condition, GPP 21 bang |
| **AdMob/AppLovin Policies** | 10% | 10/10 | Safety buffer, CTR suspension, hide inline ad khi fullscreen |

---

## 5. Điểm số tổng thể: **9.7 / 10**

---

## 6. Kết luận & Khuyến nghị triển khai (Production Readiness Verdict)

### **KẾT LUẬN: CÓ — ĐỦ ĐIỀU KIỆN SẴN SÀNG TRIỂN KHAI CHO PRODUCTION TRÊN QUY MÔ LỚN (READY FOR PRODUCTION)**

**Lý do:**
1. **Không có lỗi BLOCKER hay MAJOR nào.** Codebase ở trạng thái cực kỳ ổn định, `flutter analyze` sạch 100%, toàn bộ **1640/1640 tests** chạy hoàn hảo.
2. Các bản vá quan trọng từ Round 38 (dọn dẹp bundle lỗi của AppLovin Native Ad và cơ chế đồng bộ 2 tầng `_applyEpoch` / `_consentIntentEpoch` cho luồng Consent) hoạt động chuẩn xác và đã được kiểm chứng tính toàn vẹn.
3. Kiến trúc bảo vệ tài khoản quảng cáo (AdMob & AppLovin safety) và cơ chế kích hoạt VIP offline đáp ứng đầy đủ các tiêu chuẩn bảo mật và tuân thủ chính sách nghiêm ngặt nhất.

**Khuyến nghị cho ứng dụng tích hợp (Host App):**
- Khi sinh mã VIP offline cho người dùng, luôn ưu tiên sử dụng định dạng **`AVP2`** với `bundleId` và hạn dùng `expiresAtEpochSeconds` hợp lý.
- Đối với giao diện điều hướng sử dụng `IndexedStack`, khuyến nghị bọc nội dung các tab bằng `Visibility(maintainState: true)` để widget Banner/MREC có thể nhận biết tín hiệu ẩn/hiện thông qua `TickerMode` một cách tối ưu nhất.

---

## Vòng 2 (cùng ngày) — review độc lập chính diff của 8 fix round 39 (không phải audit toàn SDK)

Dispatch lại agy, lần này chỉ review `git diff` của 8 fix vừa code xong (không audit lại toàn bộ SDK). Adversarial, tìm bug trong chính các fix.

**Điểm: 8.0/10** (trước khi fix các finding dưới đây).

**Finding 1 [MAJOR]** — `BannerAdWidget`/`MrecAdWidget`: `active: false` bị bỏ qua hoàn toàn ở lần mount đầu tiên (`initState`/`didChangeDependencies` không kiểm tra `widget.active`; `VisibilityDetector` early-return khi `active != null`; `didUpdateWidget` không chạy ở build đầu). Đúng use-case chính (IndexedStack tab != 0 từ đầu) vẫn tự load ad ẩn. Kèm bug nối tiếp: khi active flip true→ lần đầu, `didPopNext()` bị bỏ qua vì `last == null`.

**Finding 2 [MINOR]** — `ad_manager.dart`: lời gọi `initialize()` ở nhánh COPPA re-init nằm NGOÀI epoch guard, khiến 1 lệnh đã bị supersede vẫn có thể trigger re-init toàn SDK thừa thãi.

**Finding 3 [NITPICK]** — `ConsentManager.resetForTest()` thiếu reset `debugPersistDelay`/`debugApplyBarrier`.

**Đã fix cả 3** (xem `audit_round39_consolidated.md` mục "Vòng 2" để biết chi tiết cách sửa + test). Finding 1 khi sửa lộ thêm việc CÓ TỚI 3 nhánh init độc lập trong `BannerAdWidget`/2 nhánh reinit theo listener consent/VIP đều không biết về `active` — phải sửa tổng cộng 5 điểm/widget, không chỉ 1 chỗ như đề xuất ban đầu của agy.
