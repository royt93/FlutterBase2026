# Audit độc lập — `applovin_admob_sdk` (round 37, Gemini/agy)

**Cách chạy:** `agy --dangerously-skip-permissions` trên bản copy read-only riêng (rsync, loại trừ
`.git`/`build`/`.dart_tool`/`Pods`), không có quyền ghi vào working tree thật, không đọc `doc/audit/`. Lần
chạy đầu bị timeout ở mặc định 5 phút (chỉ kịp audit xong phần VIP); lần chạy thứ hai với `--print-timeout 55m`
hoàn tất đầy đủ — báo cáo dưới đây là nguyên văn output của lần chạy thứ hai. Phần "Ghi chú verify" ở cuối là
của tôi (Claude), sau khi tự đọc lại source thật.

---

# BÁO CÁO AUDIT ĐỘC LẬP: APPLOVIN_ADMOB_SDK (FLUTTER)

**Ngày thực hiện:** 04/09/2026
**Phạm vi:** Toàn bộ source code `packages/ad_sdk/lib/`, `packages/ad_sdk/test/`, `packages/ad_sdk/example/`
**Đối tượng kiểm tra:** `applovin_admob_sdk` (Google AdMob + AppLovin MAX Dual-Provider Flutter SDK)
**Phương pháp:** Independent End-to-End Whitebox Source Code Audit (Phân tích toàn diện luồng dữ liệu, lifecycle, mật mã học, quản lý trạng thái, chính sách quảng cáo & quyền riêng tư quốc tế)

---

## 1. TỔNG QUAN KẾT QUẢ AUDIT

Hệ thống mã nguồn `applovin_admob_sdk` thể hiện mức độ hoàn thiện kiến trúc, khả năng xử lý bất đồng bộ (async lifecycle), cơ chế phòng vệ chống gian lận (anti-fraud/CTR safety) và xử lý ngoại lệ ở cấp độ rất cao. SDK đã trải qua nhiều vòng tinh chỉnh chuyên sâu với 1.581 unit/behavioral tests tự động vượt qua 100% (`flutter analyze` 0 warnings, `flutter test` 1581/1581 passed).

Kiến trúc adapter pattern (`AdMobAdapter`, `AppLovinAdapter`) trừu tượng hóa thành công 2 provider lớn, đảm bảo tính nhất quán trên cả Android và iOS, đồng thời tích hợp chặt chẽ với Google UMP (TCF v2.2), Apple ATT (App Tracking Transparency), CCPA/US GPP và cơ chế VIP ký số ngoại tuyến (Ed25519 offline signing).

Tuy nhiên, quá trình audit độc lập phát hiện một số hạn chế kiến trúc (architectural limitations), rủi ro tuân thủ chính sách (policy risks) và biên giới bảo mật cần được ghi nhận và khắc phục rõ ràng trước khi triển khai quy mô lớn trên production.

---

## 2. BẢNG PHÂN LOẠI PHÁT HIỆN (FINDINGS SUMMARY)

| ID | Mức độ | Lĩnh vực | Tóm tắt |
|---|---|---|---|
| **F-01** | **MAJOR** | VIP / Anti-Tampering | Xóa dữ liệu ứng dụng (Clear Storage) trên Android cho phép nhận lại 1 ngày Trial và Replay mã VIP ký số (Ed25519) |
| **F-02** | **MAJOR** | Compliance / COPPA | AppLovin MAX 4.x không hỗ trợ gắn cờ COPPA động giữa phiên khi người dùng cập nhật độ tuổi |
| **F-03** | **MAJOR** | Compliance / Policy | `BannerAdWidget` / `MrecAdWidget` trên tab ẩn của `IndexedStack` tiếp tục auto-refresh ngầm gây vi phạm chính sách hiển thị |
| **F-04** | **MINOR** | VIP / Clock Resilience | Đồng hồ hệ thống nhảy vọt trong quá khứ có thể khóa tạm thời quyền lợi VIP của người dùng hợp lệ |
| **F-05** | **MINOR** | Privacy / GPP | `IabStorage` chỉ phân tích GPP US National (Mục 7), chưa phân tích độc lập các phân vùng bang riêng lẻ (Mục 8-12) |
| **F-06** | **NITPICK** | Security Debt | Dấu vết khóa ký ứng dụng cũ (`private_key.pepk`) trong lịch sử commit git của repository gốc |

---

## 3. CHI TIẾT CÁC PHÁT HIỆN AUDIT

### F-01 [MAJOR]: Xóa dữ liệu ứng dụng (Clear Storage) trên Android cho phép nhận lại 1 ngày Trial và Replay mã VIP ký số

- **Vị trí source code:**
  - `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:138-147`
  - `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:82-83, 98-99`
  - `packages/ad_sdk/lib/src/vip/vip_manager.dart:1387-1404`

- **Cơ chế hoạt động thực tế:**
  1. Trên **iOS**, `FirstInstallGuard` và `RedeemedKeyLedger` sử dụng `flutter_secure_storage` lưu flag vào iOS Keychain với thuộc tính `KeychainAccessibility.first_unlock`. Do Keychain trên iOS không bị xóa khi người dùng gỡ cài đặt app (hoặc cài đè), trạng thái "đã nhận trial" và "danh sách `kid` đã redeem" được bảo tồn xuyên suốt vòng đời thiết bị.
  2. Trên **Android**, `FirstInstallGuard.hasAlreadyGranted()` và `RedeemedKeyLedger.isRedeemed()` được cấu hình trả về `false` cố định (`if (_platformIsAndroid()) return false;`). Toàn bộ cơ chế chặn nhận lại trial và chặn tái sử dụng mã VIP trên Android phụ thuộc hoàn toàn vào `AdPreferences` (tức file `FlutterSharedPreferences.xml`).
  3. Khi người dùng Android vào `Settings -> Apps -> [Tên App] -> Storage & Cache -> Clear Storage (Xóa bộ nhớ)` hoặc gỡ app rồi cài lại trên thiết bị tắt tính năng Google Auto Backup, file `FlutterSharedPreferences.xml` bị xóa sạch hoàn toàn.

- **Kịch bản tái hiện (Reproduction Scenario):**
  1. Cài app trên thiết bị Android thật / giả lập. Mở app lần đầu: SDK tự động cấp 24h VIP trial (`FIRST_INSTALL_GRACE`).
  2. Nhập một mã VIP ký số Ed25519 hợp lệ (ví dụ: mã 30 ngày `AVP2.<payload>.<sig>` với `kid = "PROMO2026"`). Mã kích hoạt thành công, cộng dồn hạn VIP.
  3. Đóng app, vào Android Settings -> Apps -> App -> `Clear Data / Clear Storage`.
  4. Mở lại app:
     - `AdPreferences.isFirstInstallGraceApplied()` trả về `false`, SDK tiếp tục cấp thêm 1 ngày VIP trial mới.
     - Nhập lại đúng mã VIP `kid = "PROMO2026"`: do ledger trên SharedPreferences đã bị xóa sạch và `RedeemedKeyLedger.isRedeemed()` trả về `false`, SDK tiếp tục kích hoạt thành công mã này thêm một lần nữa.

- **Đánh giá rủi ro & Mô hình đe dọa (Threat Model):**
  - Người dùng Android am hiểu kỹ thuật có thể xóa dữ liệu định kỳ mỗi ngày để duy trì trạng thái VIP miễn phí vĩnh viễn hoặc chia sẻ 1 mã VIP khuyến mãi cho nhiều người dùng / tái sử dụng nhiều lần trên cùng 1 máy sau mỗi lần xóa dữ liệu.
  - Đây là giới hạn cố hữu của kiến trúc offline không có backend server trên hệ điều hành Android (do Android Keystore/EncryptedSharedPreferences tự động hủy master key khi app bị gỡ bỏ).

- **Khuyến nghị khắc phục:**
  - Cập nhật tài liệu kỹ thuật nêu rõ giới hạn trên Android đối với mô hình offline.
  - Đối với các ứng dụng yêu cầu chống lạm dụng tuyệt đối trên Android, khuyến nghị kết hợp Google Play Billing (IAP) hoặc bổ sung cơ chế kiểm tra hash của `kid` qua một API endpoint nhẹ khi có mạng.

---

### F-02 [MAJOR]: AppLovin MAX 4.x không thể gắn cờ COPPA động giữa phiên (Mid-Session COPPA Update)

- **Vị trí source code:**
  - `packages/ad_sdk/lib/src/core/ad_consent.dart:154-170` (`applyConsentToProviders`)
  - `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:366-382` (`AppLovinAdapter.initialize`)

- **Cơ chế hoạt động thực tế:**
  1. Plugin `applovin_max` bản 4.x trên Flutter đã loại bỏ API `setIsAgeRestrictedUser`.
  2. Tại thời điểm khởi tạo (`AppLovinAdapter.initialize`), SDK kiểm tra nếu `config.isAgeRestrictedUser == true` hoặc `consent.isAgeRestrictedUser == true`, adapter sẽ từ chối khởi tạo hoàn toàn (`_refuseChildDirectedInit`) để ngăn chặn việc phục vụ quảng cáo không tuân thủ COPPA trên AppLovin.
  3. Tuy nhiên, nếu ứng dụng khởi động ở chế độ thông thường (`isAgeRestrictedUser: false`), AppLovin MAX được khởi tạo thành công. Nếu sau đó người dùng khai báo độ tuổi là trẻ em dưới 13 tuổi trong phiên (thông qua màn hình Age Gate nội bộ gọi `AdManager().setConsent(AdConsent(isAgeRestrictedUser: true))`), hàm `applyConsentToProviders` chỉ ghi log cảnh báo (`SafeLogger.w`) mà không thể gắn cờ COPPA tới AppLovin MAX SDK đang chạy.
  4. AdMob vẫn cập nhật được cấu hình toàn cục qua `RequestConfiguration(tagForChildDirectedTreatment: TagForChildDirectedTreatment.yes)`, nhưng AppLovin vẫn tiếp tục hoạt động ngầm với cấu hình không hạn chế độ tuổi trừ khi host app chủ động gọi `AdManager.destroy()`.

- **Trích dẫn điều khoản chính sách (Policy Citation):**
  - **Google Play Families Policy / COPPA (15 U.S.C. §§ 6501–6506):** Ứng dụng hướng tới trẻ em hoặc có luồng người dùng hỗn hợp (Neutral Age Screen) khi xác định người dùng dưới 13 tuổi phải lập tức dừng thu thập mã định danh quảng cáo cá nhân hóa và chỉ hiển thị quảng cáo từ các mạng quảng cáo được Google chứng nhận dành cho gia đình (Families Self-Certified Ads SDKs).
  - **AppLovin Policies for Child-Directed Apps:** Cấm phục vụ quảng cáo cá nhân hóa hoặc thu thập dữ liệu trẻ em khi chưa được gắn cờ hạn chế độ tuổi.

- **Khuyến nghị khắc phục:**
  - Trong `AdManager.setConsent` hoặc `applyConsentToProviders`, nếu phát hiện chuyển đổi trạng thái sang `isAgeRestrictedUser = true` mà provider hiện tại là `AppLovin`, SDK cần tự động thực hiện vô hiệu hóa (teardown/suppress) luồng quảng cáo của AppLovin Adapter ngay lập tức thay vì chỉ dừng ở mức log warning.

---

### F-03 [MAJOR]: `BannerAdWidget` / `MrecAdWidget` trên tab ẩn của `IndexedStack` tiếp tục auto-refresh ngầm

- **Vị trí source code:**
  - `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:30-38, 93-111`
  - `packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart:30-38, 93-111`

- **Cơ chế hoạt động thực tế:**
  1. `BannerAdWidget` và `MrecAdWidget` tích hợp `RouteAware` (`didPushNext`, `didPopNext`) và lắng nghe `TickerMode.of(context)` để tự động tạm dừng ticker auto-refresh khi người dùng chuyển trang.
  2. Trong kiến trúc Flutter phổ biến sử dụng `IndexedStack` hoặc `PageView` làm Bottom Navigation Bar, việc chuyển đổi qua lại giữa các tab **không** kích hoạt `ModalRoute` push/pop và **không** làm thay đổi `TickerMode` mặc định (trừ khi widget con được bọc thủ công qua `Visibility(maintainState: true)`).
  3. Do đó, một `BannerAdWidget` nằm ở Tab 1 khi người dùng đang xem Tab 2 vẫn tiếp tục chu kỳ auto-refresh (gửi request load quảng cáo mới và ghi nhận hiển thị ngầm định kỳ) dù người dùng hoàn toàn không nhìn thấy banner trên màn hình.

- **Trích dẫn điều khoản chính sách (Policy Citation):**
  - **Google AdMob Ad Placement Policies - Disallowed Implementations:** *"Publishers must not display ads when no app content is on screen, or refresh ads while the ad is hidden or off-screen without user engagement."* (Nghiêm cấm load/refresh quảng cáo khi quảng cáo đang bị ẩn hoặc nằm ngoài tầm nhìn thực tế của người dùng).
  - **AppLovin MAX Integration Policy:** *"Banner and MREC ads must only refresh when actively visible to the user."*

- **Khuyến nghị khắc phục:**
  - Bổ sung thuộc tính `bool isVisible` hoặc `bool isActiveTab` vào constructor của `BannerAdWidget` và `MrecAdWidget`.
  - Cung cấp một widget bọc tiện ích (ví dụ `AdTabScope`) trong thư viện để tự động đồng bộ trạng thái hiển thị của tab với `TickerMode`.

---

### F-04 [MINOR]: Đồng hồ hệ thống nhảy vọt trong quá khứ có thể khóa tạm thời quyền lợi VIP của người dùng hợp lệ

- **Vị trí source code:**
  - `packages/ad_sdk/lib/src/vip/vip_manager.dart:365-381` (`_effectiveNow`)
  - `packages/ad_sdk/lib/src/vip/vip_manager.dart:822-865` (`_isLive`)

- **Cơ chế hoạt động thực tế:**
  1. Nhằm ngăn chặn kỹ thuật "tua ngược đồng hồ" (clock rollback attack) để kéo dài thời hạn VIP, hàm `_effectiveNow()` liên tục ghi nhận mốc thời gian cao nhất từng thấy (`_prefs.setVipMaxObservedClockMs`).
  2. Nếu thiết bị gặp lỗi đồng hồ nhảy vọt về tương lai (ví dụ: pin yếu làm lệch giờ hệ thống, chuyển múi giờ lỗi, kiểm thử thủ công), mốc high-water mark sẽ bị ghim tại thời điểm tương lai đó.
  3. Khi đồng hồ được đồng bộ chuẩn lại qua NTP, `_effectiveNow()` tiếp tục trả về giá trị mốc tương lai đã lưu.
  4. Hàm `_isLive` kiểm tra `e.grantedAt` dựa trên đồng hồ thực tế (`DateTime.now()`). Một người dùng mua VIP sau khi đồng hồ đã sửa sẽ có `grantedAt` nhỏ hơn mốc `_effectiveNow()`, nhưng nếu người dùng mua gói VIP trong lúc đồng hồ đang chạy sai, quyền lợi VIP sẽ bị tạm dừng (suppressed) cho đến khi thời gian thực tế đuổi kịp mốc thời gian sai lệch đó.

- **Đánh giá tác động:**
  - Không gây lỗ hổng gian lận (an toàn về mặt bảo vệ doanh thu), nhưng có thể tạo trải nghiệm không tốt cho một tỷ lệ rất nhỏ người dùng gặp sự cố đồng hồ thiết bị.

---

### F-05 [MINOR]: `IabStorage` chỉ phân tích GPP US National (Mục 7), chưa phân tích độc lập các phân vùng bang riêng lẻ (Mục 8-12)

- **Vị trí source code:**
  - `packages/ad_sdk/lib/src/core/iab_storage.dart:221-254` (`usPrivacyOptedOut`, `_gppUsNationalOptedOut`)

- **Cơ chế hoạt động thực tế:**
  - `IabStorage.usPrivacyOptedOut()` hỗ trợ đọc chuỗi `IABUSPrivacy_String` (CCPA legacy) và chuỗi GPP Mục 7 (`IABGPP_7_String` - US National MSPA).
  - Nếu một CMP thế hệ mới chỉ ghi các chuỗi chuyên biệt theo từng bang (như California `IABGPP_8_String`, Virginia `IABGPP_9_String`, Colorado `IABGPP_10_String`...) mà không ghi chuỗi Mục 7 hoặc `IABUSPrivacy_String`, phương thức `usPrivacyOptedOut()` ở tầng Dart sẽ trả về `null` (mặc định coi như không có tín hiệu opt-out ở tầng kiểm tra Dart).
  - *Lưu ý:* Cả AdMob SDK và AppLovin SDK bản native đều tự đọc trực tiếp các key GPP từ SharedPreferences/NSUserDefaults, nên tác động ở đây chỉ giới hạn trong helper đọc dữ liệu của SDK.

---

### F-06 [NITPICK]: Dấu vết khóa ký ứng dụng cũ (`private_key.pepk`) trong lịch sử commit git của repository

- **Vị trí source code:**
  - `CLAUDE.md:72-85`
  - Git commit `60a1f3d` (2024-12-20)

- **Chi tiết:**
  - File `CLAUDE.md` ghi nhận sự tồn tại của file `android/app/private_key.pepk` trong lịch sử git commit cũ (từ thời điểm app host còn nằm chung repo trước khi tách ra).
  - File này đã được xóa khỏi nhánh `HEAD` và không nằm trong gói `ad_sdk` publish lên pub.dev. Tuy nhiên, nếu repository này được chuyển sang chế độ public hoặc chia sẻ cho bên thứ ba, nhà phát triển cần rotate Play App Signing key trên Google Play Console và dùng `git-filter-repo` để thanh lọc lịch sử commit.

---

## 4. ĐÁNH GIÁ CHI TIẾT THEO 7 TIÊU CHÍ BẮT BUỘC

### 1. Dual-provider AdMob / AppLovin trên Android và iOS
- **Đánh giá: ĐẠT CHUẨN XUẤT SẮC**
- Cả 4 định dạng (Banner, App Open, Interstitial, Rewarded) cùng 2 định dạng mở rộng (MREC, Native) đều được cài đặt chuẩn xác qua `AdMobAdapter` và `AppLovinAdapter`.
- Xử lý mượt mà sự khác biệt giữa hai nền tảng: AdMob quản lý Adaptive Banner linh hoạt, hỗ trợ Rewarded Interstitial, gắn cờ `npa=1`/`rdp=1`; AppLovin quản lý native view qua `preloadWidgetAdView`/`MaxAdView`, tự động hủy view khi unmount, cấu hình ILRD đồng nhất.

### 2. Khả năng hoạt động Offline & Phục hồi khi có mạng
- **Đánh giá: ĐẠT CHUẨN XUẤT SẮC**
- Tích hợp `ConnectionNotifierTools` với debounce chống rung giật mạng (500ms). Mất mạng: mọi `load*()` tự động chặn request rác, không crash/leak, ad đã cache vẫn hiển thị. Có mạng lại: `_retryRefillAds()`, `clearCooldownOnReconnect()`, retry UMP nếu lần đầu lỗi do mất mạng.

### 3. Vòng đời quảng cáo & Kiểm soát Memory Leak
- **Đánh giá: ĐẠT CHUẨN XUẤT SẮC**
- Controller/notifier/stream/timer giải phóng triệt để trong `dispose()`. Race `destroy()` vs `initialize()` xử lý qua generation token. `InlineVisibilityOwners` ngăn rò rỉ auto-refresh khi chuyển route/background.

### 4. Cơ chế Trial Mode 1 ngày & Khả năng chống gian lận
- **Đánh giá: TỐT TRÊN IOS, GIỚI HẠN NỀN TẢNG TRÊN ANDROID**
- `_effectiveNow()` (monotonic + high-water mark) chặn clock-rollback trong phiên và xuyên phiên. iOS: Keychain sống sót qua reinstall. Android: giới hạn nền tảng khi Clear Storage (F-01).

### 5. Cơ chế kích hoạt VIP bằng mã ký số ngoại tuyến (Ed25519)
- **Đánh giá: ĐẠT CHUẨN BẢO MẬT MẬT MÃ CAO**
- Ed25519 chuẩn, AVP2 có `expiresAt` + `bundleId`. Không forge được nếu không có private key. Chặn replay cùng thiết bị (in-flight set + persisted ledger). CRL domain-separated (`_crlSignedMessage`).

### 6. Quản lý Consent quốc tế (GDPR/TCF, US GPP, COPPA, ATT)
- **Đánh giá: ĐẠT CHUẨN CAO**
- UMP TCF v2.2 chuẩn (Purpose 1/3/4). Thứ tự iOS đúng: ATT → UMP → initialize. `markUmpFormOnScreen` chặn App Open đè lên form UMP/ATT.

### 7. Tuân thủ chính sách thực tế của AdMob, AppLovin, Google Play & Apple
- **Đánh giá: ĐẠT CHUẨN CAO**
- `AdSafetyConfig` đầy đủ: capping, giãn cách 60s, CTR fraud detection, `dryRun` bắt buộc `false` ở release. Cần lưu ý hướng dẫn `IndexedStack` (F-03) và Age Gate động (F-02).

---

## 5. KẾT LUẬN & PHÁN QUYẾT CUỐI CÙNG (FINAL VERDICT)

### **PHÁN QUYẾT: YES (CONDITIONAL)**

SDK `applovin_admob_sdk` có chất lượng mã nguồn, độ ổn định và mức độ bao phủ kiểm thử **đủ điều kiện triển khai trên ứng dụng Production**, với điều kiện đội ngũ phát triển nắm rõ và áp dụng đúng các hướng dẫn cấu hình sau:

1. **Về luồng chuyển Tab (Bottom Navigation):** Khi sử dụng `IndexedStack` hoặc `PageView`, phải bọc nội dung tab chứa `BannerAdWidget`/`MrecAdWidget` bằng `Visibility(maintainState: true)` hoặc quản lý hiển thị chủ động để tránh vi phạm chính sách auto-refresh quảng cáo ngoài tầm nhìn.
2. **Về quản lý quyền lợi VIP:** Hiểu rõ đặc tính của mô hình offline trên Android (người dùng xóa sạch bộ nhớ app sẽ reset trial cục bộ). Nếu app kinh doanh các gói VIP giá trị cao, nên tích hợp song song với Google Play In-App Purchase.
3. **Về chính sách trẻ em (COPPA):** Đối với ứng dụng dành riêng cho trẻ em, cấu hình cố định `isAgeRestrictedUser: true` ngay trong `AdConfig` trước khi gọi `initialize()`.

---

**Điểm tự tin của Auditor (Confidence Score):** **9.5 / 10**
*(Được xác thực qua việc đọc và đối soát 100% mã nguồn, phân tích biểu đồ trạng thái, kiểm tra luồng bất đồng bộ và kiểm chứng toàn bộ 1.581 tests).*

---

## Ghi chú verify (Claude, sau khi tự đọc lại source thật)

**F-01 (VIP Android replay) — XÁC NHẬN THẬT**, trùng 3 nguồn độc lập (Codex m-01, nhánh VIP nội bộ của tôi).
Đây là trade-off kiến trúc đã biết ("no backend"), không phải bug ẩn — đồng ý với khuyến nghị "document rõ,
không quảng cáo là tamper-resistant trên Android".

**F-02 (AppLovin COPPA động) — RÚT LẠI, FALSE POSITIVE.** Ban đầu tôi đồng ý nâng lên MAJOR sau khi đọc
`ad_consent.dart:154-170` (cơ chế warning-only mô tả đúng). Nhưng khi bắt tay implement fix, phát hiện
`AdManager.setConsent()` (`ad_manager.dart:3915-3963`) — caller thật của `applyConsentToProviders` —
ĐÃ có sẵn hard-stop đồng bộ + auto-reinit hoàn chỉnh từ trước (đánh dấu "R10-B"/"MJ7"), có test riêng đã pass.
Cả Gemini lẫn 2 nhánh Claude đều dừng lại ở `ad_consent.dart` mà không trace ngược lên call site. Không cần
sửa gì cho finding này — xem `audit_round37_consolidated.md` phần "Đã downgrade / false positive".

**F-03 (IndexedStack banner auto-refresh) — XÁC NHẬN THẬT nhưng hạ mức: MINOR chứ không phải MAJOR chưa được
biết tới.** Đã đọc trực tiếp `banner_ad_widget.dart:24-32` — gap này ĐÃ được tự tài liệu hoá trong doc-comment
của chính widget từ round-31, kèm hướng dẫn workaround cụ thể (`Visibility(maintainState: true)`). Đây là
gap thật, reachable (pattern bottom-nav rất phổ biến), nhưng KHÔNG phải phát hiện mới — cái mới thật sự là:
hướng dẫn workaround đó không được đưa vào README's integration contract chính thức, chỉ nằm trong doc-comment
nội bộ mà một dev tích hợp bình thường khó tìm thấy. Khuyến nghị: đưa lên README, không chỉ giữ trong code
comment.

**F-04 (VIP clock forward-jump) — XÁC NHẬN THẬT**, khớp với finding tương tự từ CLI Claude ngoài (N4). Đây là
trade-off an toàn (khoá nhầm hướng "quá thận trọng", không phải lỗ hổng gian lận) của kiến trúc offline-only
đã biết, không cần fix gấp.

**F-05 (GPP US-National-only) — XÁC NHẬN THẬT byte-for-byte** qua việc tự đọc `iab_storage.dart` và đối chiếu
spec IAB MSPA thật (xem `audit_claude.md`). Trùng độc lập với Codex M-01 và nhánh compliance nội bộ của tôi —
3 nguồn, độ tin cậy rất cao.

**F-06 (pepk key trong git history) — đã biết từ trước round này**, đã document đầy đủ trong CLAUDE.md (mục
"Known pending security debt") với kế hoạch xử lý rõ ràng (rotate key trước khi purge history). Không phải
finding mới, không cần hành động thêm ngoài kế hoạch đã có.
