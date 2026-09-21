# Audit Round 71 — Báo Cáo Độc Lập (Auditor: Gemini / Antigravity)

**Ngày:** 2026-09-21  
**Package:** `applovin_admob_sdk` (`packages/ad_sdk`)  
**Phiên bản audited:** `3.0.10` (trên Git `HEAD` commit `f4383da`)  
**Môi trường thử nghiệm:** Flutter SDK `>=3.27.0`, Dart `>=3.6.0`, macOS  
**Kết quả test suite:** **2218 / 2218 tests passing** (`flutter test`), `flutter analyze` 0 issues.

---

## Tóm tắt điều hành (Executive Summary)

Đây là đợt audit độc lập lần thứ 71 của SDK `applovin_admob_sdk`. Sau khi các round 68, 69 và 70 vá lỗ hổng debug seam trên `AdManager`, `AppLovinAdapter`, `AdMobAdapter`, `AdSafetyConfig`, và `IabStorage` (tổng cộng 44 seams), round 71 tiến hành rà soát toàn diện code thực tế (không dựa dẫm báo cáo cũ) qua 7 lĩnh vực trọng yếu theo yêu cầu:
1. **Dual-provider parity (AppLovin MAX vs AdMob)**
2. **Offline/online resilience (Khả năng chịu lỗi mạng và phục hồi kết nối)**
3. **Ad lifecycle, memory leak & policy compliance (Vòng đời quảng cáo và an toàn bộ nhớ)**
4. **Cơ chế dùng thử (1-day trial mode)**
5. **Cơ chế kích hoạt VIP offline không backend (Ed25519 signing/verification)**
6. **Sự tuân thủ đồng thuận toàn cầu (GDPR/UMP, CCPA/US States, UK, GPP, TCF)**
7. **Tuân thủ chính sách quảng cáo AdMob/AppLovin (COPPA, Test ID, Waterfall safety)**

### Bảng tổng kết phát hiện (Finding Counts):
- **BLOCKER:** 0
- **MAJOR:** 2 (Debug seam gap còn sót lại ở `VipManager` và `ump_consent.dart`)
- **MINOR:** 2 (Static barriers trên `AdManager` và debug reset trên `ConsentManager` / `AdSlot`)
- **NIT:** 1 (README test count lỗi thời)

---

## Chi tiết kết quả Audit theo 7 mảng

### 1. Dual-provider Parity (AppLovin MAX vs AdMob)
- **Banner & MREC:** Cả 2 provider đều tuân thủ kiến trúc đa instance theo widget key (`_bannerRegistry`, `_mrecRegistry`). AdMob tự động đo kích thước container qua `loadBannerIfNeeded(key, widthPx)` và `buildAdmobBannerView(key)`; AppLovin tải qua `preloadBanner(key)` kết hợp `appLovinBannerId` và `appLovinBannerAdViewId(key)`. Cả hai đều hỗ trợ làm ẩn tự động khi App Open hiển thị qua `InlineAdVisibility.setInlineAdsHidden`.
- **Interstitial & Rewarded:** Cả 2 provider đều có watchdog hiển thị (10s), kiểm tra trạng thái slot (`beginShow`, `markDismissed`, `markShowFailed`), bảo vệ chống cycle-race callback bằng local flags / quarantine window. Hỗ trợ Server-Side Verification (SSV) đồng bộ: AdMob dùng `ServerSideVerificationOptions` (`customData`, `userId`), AppLovin dùng `customData` trên `showRewardedAd`.
- **App Open:** Cả 2 provider đều có cơ chế tải và hiển thị tương đương. AdMob tự động kiểm tra hết hạn ad sau 4h (`isAdFresh`), trong khi AppLovin do giới hạn từ native SDK không cung cấp timestamp load nên cache được giữ nguyên theo slot (đã ghi rõ trong tài liệu).
- **Rewarded Interstitial:** AdMob hỗ trợ định dạng này (`rewardedInterstitialSlot`); AppLovin MAX không có định dạng tương đương nên triển khai no-op có chủ đích (`rewardedInterstitialSlot` giữ `idle`, trả về `RewardResult(earned: false, shown: false)`). Điều này hoàn toàn đúng thiết kế và đã được document rõ ràng trong `ad_provider_adapter.dart:307-317`.
- **Native Ad:** AdMob hỗ trợ preload template (`TemplateType.medium`, `TemplateType.small`), AppLovin sử dụng `MaxNativeAdView` render trực tiếp khi mount. Cả hai đều tham gia vào `InlineAdVisibility` khi App Open xuất hiện.
- **Đánh giá:** **ĐẠT CHUẨN PARITY**. Không có sai lệch logic ngoài các hạn chế nền tảng đã được công bố.

---

### 2. Offline / Online Resilience
- **Mất mạng khi load:** Mọi lệnh load fullscreen đều đi qua `_coalesceAdLoad` và được bảo vệ bởi watchdog timer (`armLoadWatchdog`), ngăn chặn tình trạng slot bị treo vĩnh viễn ở trạng thái `loading` nếu platform channel im lặng. Khi fail, slot chuyển sang `cooldown` kèm exponential backoff (`Backoff`).
- **Phục hồi khi có mạng:** SDK tích hợp `connection_notifier` (`ConnectionNotifierTools`), khởi chạy subscription có token thế hệ `_connectivityWatchGen` để tránh race condition khi reinit.
- **Xử lý mạng chập chờn (Flapping):** Chuyển trạng thái offline -> online được debounce qua `_reconnectDebounceTimer` (800ms). Nếu mạng ngắt trở lại trong lúc debounce, timer bị hủy ngay lập tức (`packages/ad_sdk/lib/src/core/ad_manager.dart:9092`), ngăn ngừa việc gửi request vô ích trong lúc offline.
- **Clear cooldown on reconnect:** Các slot cấu hình `AdRetryPolicy.resetOnConnectivityRestored` được xóa cooldown ngay khi mạng online (`clearCooldownOnReconnect`), cho phép nạp lại ad tức thì thay vì chờ hết chu kỳ backoff cũ.
- **Đánh giá:** **ĐẠT CHUẨN RESILIENCE**.

---

### 3. Ad Lifecycle, Memory Leaks & Policy Compliance
- **Giải phóng tài nguyên (Dispose & Leak-free):**
  - `BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget` hủy toàn bộ listener (`canRequestAdsListenable`, `personalisationRevision`), hủy debounce timer, tách `InlineAdController`, unsubscribe `adRouteObserver` và gọi `disposeInstance(this)` trên `AdManager`.
  - Không có hiện tượng giữ `BuildContext` qua async gap mà thiếu `if (!mounted) return;`.
- **Policy AdMob & AppLovin:**
  - **Không auto-click:** Không có cơ chế kích hoạt click giả lập. Thống kê click tuân thủ `AdSafetyConfig`, phát hiện click bất thường để kích hoạt tạm dừng invalid-traffic (30 phút).
  - **Không ép reward:** `RewardResult` chỉ cấp phần thưởng (`earned: true`) khi native callback thực sự xác nhận (`onUserEarnedReward` trên AdMob, `onAdRewardedCallback` trên AppLovin). Khi người dùng bỏ qua (skip), `earned: false`.
  - **Không đè lên dialog / popup / consent form:** Getter `_fullscreenBusyReason` (`packages/ad_sdk/lib/src/core/ad_manager.dart:2272-2322`) chặn hiển thị quảng cáo fullscreen nếu:
    1. Form UMP đang hiển thị (`umpFormOnScreen.value`).
    2. Overlay tuỳ biến của host đang mở (`customOverlayOnScreen.value`).
    3. Dialog route đang mở (`AdScreenRouteLogger.isDialogOnTop`).
    4. Ad loading buffer đang mở (`AdLoadingDialog.isShowing`).
    5. Một fullscreen ad khác đang hiển thị (`appOpenSlot`, `interstitialSlot`, `rewardedSlot`, `rewardedInterstitialSlot`).
  - **Không show ad khi app background:** `didChangeAppLifecycleState` gọi `ad.onAppPaused()`, làm ẩn banner/MREC/native và tắt auto-refresh. Không có ad nào được show khi app ở background.
- **Đánh giá:** **ĐẠT CHUẨN LIFECYCLE & POLICY**.

---

### 4. Trial Mode 1 Ngày (First-Install VIP Grace)
- **Thời lượng:** `FirstInstallVipGrace.auto` phân định chính xác: 24 giờ (`Duration(days: 1)`) trong release build, 30 giây trong debug build phục vụ QA.
- **Vị trí lưu cờ:**
  - `AdPreferences`: Lưu `_keyFirstInstallApplied` (`ad_sdk_first_install_grace_applied`) trong SharedPreferences.
  - `FirstInstallGuard`: Trên iOS, cờ `ad_sdk_first_install_granted_v1` được ghi vào iOS Keychain qua `FlutterSecureStorage` với quyền truy cập `KeychainAccessibility.first_unlock`. Cờ này tồn tại xuyên suốt các lần gỡ và cài đặt lại app (anti-uninstall-bypass).
  - Trên Android: Dựa trên Android Auto Backup (`FlutterSharedPreferences.xml`). Nếu Auto Backup bị tắt hoặc dữ liệu app bị xóa sạch qua Settings ("Clear Data"), người dùng có thể nhận lại trial. Đây là giới hạn kiến trúc đã được chấp nhận và ghi rõ trong tài liệu do yêu cầu không có server backend.
- **Thứ tự ghi cờ (Write Order):** Ghi cờ bền vững Keychain (`guard.markGranted()`) TRƯỚC KHI ghi SharedPreferences (`prefs.markFirstInstallGraceApplied()`). Nếu app bị kill giữa chừng, lần mở sau vẫn phát hiện được Keychain flag và không bị duplicate trial.
- **Chống gian lận giờ máy (Clock Tampering):**
  - Chỉnh lùi giờ: `_effectiveNow()` kẹp thời gian vào mức đỉnh cao nhất từng ghi nhận (`getVipMaxObservedClockMs`). Giờ lùi không thể làm sống lại trial đã hết hạn.
  - Chỉnh tiến giờ trước khi cài đặt: `_isLive` kiểm tra `DateTime.now().add(futureGrantSlack).isBefore(e.grantedAt)`, loại trừ các grant có thời điểm bắt đầu nằm ở tương lai so với đồng hồ thật.
- **Đánh giá:** **ĐẠT CHUẨN TRIAL INTEGRITY**.

---

### 5. VIP Activation by Code (Không có Server/Backend)
- **Cơ chế ký & xác thực:** Sử dụng mật mã học bất đối xứng Ed25519 qua thư viện `cryptography`. Khóa private mint offline (`tool/vip_mint.dart`), chỉ có khóa public nhúng vào client app. Không thể giả mạo (forge) code nếu không có private key.
- **Định dạng code:** Hỗ trợ `AVP1` và `AVP2` (`AVP2.<b64url(payload)>.<b64url(sig)>`). `AVP2` đóng gói:
  - `seconds`: Thời lượng VIP được cấp.
  - `kid`: Key ID duy nhất để chống dùng lại.
  - `expiresAtEpochSeconds`: Thời hạn hiệu lực của chính code đó (hết hạn thì không thể kích hoạt dù chưa dùng bao giờ).
  - `bundleId`: Ràng buộc code chỉ dùng được cho App ID chỉ định.
- **Chống Race Condition:**
  - `redeemSignedKey` kiểm tra đồng thời cả cờ đã lưu (`isVipKeyIdRedeemed`) và danh sách đang xử lý in-flight (`_signedKidsInFlight`). `_signedKidsInFlight.add(parsed.keyId)` được thực hiện đồng bộ (synchronously) trước mọi async gap, triệt tiêu race condition kích hoạt đồng thời trên cùng một máy.
- **Rủi ro Replay giữa nhiều máy (Multi-device Replay):**
  - **Bản chất kiến trúc:** Vì SDK hoạt động 100% offline không có server trung tâm ghi nhận sổ cái toàn cầu, một code hợp lệ về mặt kỹ thuật CÓ THỂ được nhập trên Máy A và tiếp tục nhập trên Máy B (nếu code chưa hết hạn `expiresAt`, khớp `bundleId` và máy B chưa từng nhập `kid` đó).
  - **Biện pháp giảm thiểu:** Tài liệu README và `signed_vip_key.dart` nêu rõ đặc tính này. SDK hỗ trợ cơ chế Certificate Revocation List offline (`refreshRevocationList` qua `VipRevocationProvider` / `vip_crl_mint.dart`) để thu hồi các `kid` bị lộ.
- **Lỗ hổng phát hiện:** Xem mục Finding 1 bên dưới (seam `clearRedeemedKeyLedgerForTest` chưa được guard trong release build).

---

### 6. Consent Toàn Cầu (GDPR/EEA, CCPA/US States, UK, GPP)
- **Thứ tự thực thi (EEA Pre-request Consent):** Khi `autoRequestUmpConsent: true` (mặc định), `AdManager.initialize()` đóng cổng `_updateCanRequestAds(false)` NGAY TRƯỚC KHI gọi UMP. Không có bất kỳ quảng cáo nào được tải trước khi UMP giải quyết xong.
- **Cảnh báo Footgun:** Nếu host tắt `autoRequestUmpConsent: false` mà không tự chạy UMP hay CMP nào khác, trong release mode SDK kích hoạt `_footgunBlocked = true`, khoá cứng `canRequestAds = false` nhằm tránh vi phạm pháp lý phục vụ quảng cáo không có đồng thuận ở EEA/UK.
- **TCF String:** `IabStorage` đọc trực tiếp từ SharedPreferences mặc định của hệ thống (`<packageName>_preferences` trên Android, `NSUserDefaults` trên iOS) và phân tích các bit Purpose 1, 2, 3, 4, 7, 9, 10.
- **GPP String (Fix 2-segment Round 56):** Đã kiểm tra lại `packages/ad_sdk/lib/src/core/iab_storage.dart:37`:
  ```dart
  _GppBitReader(String section) : _bits = _decode(section.split('.').first);
  ```
  Logic tách lấy `CoreSegment` đầu tiên và bỏ qua `.GPCSegment` hoạt động chuẩn xác, tương thích hoàn toàn với CMP tuân chuẩn IAB Tech Lab (`@iabgpp/cmpapi`). Test case hồi quy `usPrivacyOptedOut: a real two-segment GPP USNAT string...` trong `test/ad_manager_core_test.dart:4960` đã PASS.
- **Lỗ hổng phát hiện:** Xem mục Finding 2 bên dưới (biến override timeout UMP lộ ra public API mà không có guard release mode).

---

### 7. Tuân Thủ Chính Sách Khác (COPPA, Test Ads Leak, Mediation Waterfall)
- **COPPA & Trẻ em (TFUA / tagForChildDirectedTreatment):**
  - AdMob: `RequestConfiguration` được cập nhật đồng bộ cả `tagForChildDirectedTreatment: TagForChildDirectedTreatment.yes` và `tagForUnderAgeOfConsent: TagForUnderAgeOfConsent.yes` ngay khi `isAgeRestrictedUser == true`.
  - AppLovin: Do AppLovin MAX Flutter plugin v4.x không có runtime API để gắn cờ COPPA, `AppLovinAdapter.initialize` **HỦY KHỞI TẠO HOÀN TOÀN** (`_disabledForChildUser = true; return false;`). Toàn bộ surface của AppLovin bị vô hiệu hoá trong session, đảm bảo tuyệt đối không có dữ liệu trẻ em bị gửi sai quy định.
- **Chặn rò rỉ Test Ad Unit ID trong bản Release:**
  - Hàm `usesGoogleTestAdUnitIds(config)` kiểm tra tiền tố test của Google (`ca-app-pub-3940256099942544`) trên mọi ad type (Banner, Interstitial, Rewarded, Rewarded Interstitial, MREC, Native).
  - Trong bản release (`isActuallyRelease`), `_applyTestIdFootgunGuard` bật `_testIdFootgunBlocked = true`, khóa vĩnh viễn quyền tải quảng cáo trong suốt vòng đời tiến trình.
- **Mediation Waterfall:**
  - Hệ thống an toàn `AdSafetyConfig` áp dụng giới hạn hiển thị theo giờ/ngày/phiên, phát hiện click tặc (CTR > ngưỡng, > 5 click/phút kích hoạt pause 30 phút), phân rã anomaly doanh thu và theo dõi fill-rate baseline.
- **Đánh giá:** **ĐẠT CHUẨN POLICY COMPLIANCE**.

---

## Danh Sách Phát Hiện (Findings)

### Finding 1 — [MAJOR] `VipManager.clearRedeemedKeyLedgerForTest()` thiếu runtime guard `kReleaseMode` — cho phép xoá sổ cái Keychain chống dùng lại VIP key trong bản Release
- **File & Line:** [`packages/ad_sdk/lib/src/vip/vip_manager.dart:1791-1792`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/src/vip/vip_manager.dart#L1791-L1792)
- **Mô tả chi tiết:**
  `clearRedeemedKeyLedgerForTest()` là một public method trên `VipManager` (được export công khai qua `packages/ad_sdk/lib/applovin_admob_sdk.dart:102` và getter `AdManager().vip`), chỉ được gắn annotation `@visibleForTesting`. Như các vòng audit 68–70 đã chỉ rõ, `@visibleForTesting` chỉ là lint của static analyzer và hoàn toàn bị bỏ qua khi biên dịch release.
  Trong code hiện tại:
  ```dart
  @visibleForTesting
  Future<void> clearRedeemedKeyLedgerForTest() => _redeemedKeyLedger.erase();
  ```
  Không hề có bất kỳ kiểm tra runtime nào với `kReleaseMode` hay `isActuallyRelease()`. Bất kỳ code nào chạy trong cùng isolate của ứng dụng release (hoặc code can thiệp/reverse engineer) đều có thể gọi `await AdManager().vip?.clearRedeemedKeyLedgerForTest()`.
- **Rủi ro:**
  Lệnh này sẽ xóa trắng sổ cái `_redeemedKeyLedger` (vốn được lưu trong iOS Keychain để chống bypass). Sau khi xoá, một mã VIP một lần (one-time code) đã được đổi trước đó có thể được nhập và kích hoạt lại thành công trên cùng thiết bị, phá vỡ hoàn toàn cơ chế bảo vệ chống dùng lại mã VIP offline.
- **Đề xuất fix:**
  Bổ sung guard `isActuallyRelease` tương tự chuẩn đã áp dụng trên các file khác:
  ```dart
  @visibleForTesting
  Future<void> clearRedeemedKeyLedgerForTest() async {
    if (isActuallyRelease(_isRelease)) {
      SafeLogger.e(_tag, 'clearRedeemedKeyLedgerForTest ignored in a release build — test-only seam');
      return;
    }
    await _redeemedKeyLedger.erase();
  }
  ```

---

### Finding 2 — [MAJOR] Biến override timeout form UMP `debugFormDismissTimeoutOverride` được export công khai mà không có guard `kReleaseMode`
- **File & Line:** [`packages/ad_sdk/lib/src/core/ump_consent.dart:19`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/src/core/ump_consent.dart#L19) và export tại [`packages/ad_sdk/lib/applovin_admob_sdk.dart:52`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/applovin_admob_sdk.dart#L52)
- **Mô tả chi tiết:**
  `debugFormDismissTimeoutOverride` là một biến mutable ở cấp độ top-level dùng để rút ngắn thời gian timeout chờ đóng form UMP (`kFormDismissTimeout` = 180 giây). Biến này được export trực tiếp trong barrel file chính `applovin_admob_sdk.dart`.
  Tại vị trí đọc:
  ```dart
  Duration get _formDismissTimeout =>
      debugFormDismissTimeoutOverride ?? kFormDismissTimeout;
  ```
  Không hề có kiểm tra `kReleaseMode`. Nếu một lập trình viên tích hợp dùng biến này để chạy test nhanh và vô tình để sót trong build release (hoặc cấu hình nhầm), form UMP sẽ bị timeout chỉ sau vài giây trong khi người dùng thực tế tại châu Âu vẫn đang đọc điều khoản.
- **Rủi ro:**
  Form UMP bị coi là "abandoned" hoặc thất bại sớm, khiến trạng thái consent không được thu thập đầy đủ hoặc dẫn đến việc khóa hiển thị quảng cáo / vi phạm chính sách Google UMP & GDPR.
- **Đề xuất fix:**
  1. Loại bỏ việc export `debugFormDismissTimeoutOverride` khỏi barrel file `applovin_admob_sdk.dart` (hoặc chỉ cho phép truy cập nội bộ package).
  2. Bổ sung runtime guard tại vị trí đọc:
  ```dart
  Duration get _formDismissTimeout =>
      (kReleaseMode ? null : debugFormDismissTimeoutOverride) ?? kFormDismissTimeout;
  ```

---

### Finding 3 — [MINOR] Các static test barrier trên `AdManager` thiếu kiểm tra `_testSeamsBlocked` tại vị trí đọc
- **File & Line:** [`packages/ad_sdk/lib/src/core/ad_manager.dart:6182, 6187, 6197`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/src/core/ad_manager.dart#L6182)
- **Mô tả chi tiết:**
  Ba static field `debugConsentApplyBarrier`, `debugConsentWriteBarrier`, và `debugSetConsentTailWriteBarrier` là các `Future<void>?` công khai được gắn `@visibleForTesting`. Khác với `debugAdapterFactory` (đã được round 68 bổ sung kiểm tra `_testSeamsBlocked` tại điểm đọc), cả ba barrier này được đọc và `await` trực tiếp tại các dòng 5169, 6202, 6284 mà không kiểm tra `_testSeamsBlocked`.
- **Rủi ro:**
  Nếu bị gán một `Completer().future` không bao giờ complete trong môi trường release, các luồng `setConsent()` và cập nhật UMP sẽ bị treo (hang) vô thời hạn.
- **Đề xuất fix:**
  Thêm điều kiện `!_testSeamsBlocked` trước khi `await`:
  ```dart
  if (!_testSeamsBlocked && tailWriteBarrier != null) await tailWriteBarrier;
  ```

---

### Finding 4 — [MINOR] `ConsentManager.resetForTest()` và `AdSlot.debugFireLoadWatchdogNow()` thiếu runtime guard
- **File & Line:** [`packages/ad_sdk/lib/src/consent/consent_manager.dart:111`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/src/consent/consent_manager.dart#L111) và [`packages/ad_sdk/lib/src/state/ad_slot.dart:284`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/lib/src/state/ad_slot.dart#L284)
- **Mô tả chi tiết:**
  - `ConsentManager.resetForTest()` gọi `dispose()` trên các `ValueNotifier` đang hoạt động (`_settingsListenable`, `_fallbackListenable`) và gán `_instance = null`. Nếu bị gọi trong release, các widget đang lắng nghe sẽ gặp lỗi runtime exception khi rebuild.
  - `AdSlot.debugFireLoadWatchdogNow()` có thể bị gọi qua `AdManager().adapter?.interstitialSlot.debugFireLoadWatchdogNow()`, ép buộc slot nhảy vào cooldown ngay lập tức mà không có guard release.
- **Rủi ro:**
  Gây crash widget tree hoặc desync trạng thái slot nếu bị gọi ngoài ý muốn.
- **Đề xuất fix:**
  Bổ sung `kReleaseMode` guard cho cả hai method trên.

---

### Finding 5 — [NIT] Số lượng test trong README mục "Known limitations" bị lỗi thời
- **File & Line:** [`packages/ad_sdk/README.md:54`](file:///private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/d834202f-515f-4339-943c-dc0540ec6328/scratchpad/audit71/repo/packages/ad_sdk/README.md#L54)
- **Mô tả:**
  README ghi: *"This SDK has extensive automated coverage (500+ unit/widget tests...)"*. Thực tế test suite hiện tại đã đạt **2,218 tests** (tăng hơn 4 lần).
- **Đề xuất fix:** Cập nhật README thành "2,200+ unit/widget tests".

---

## Đối chiếu Tài liệu & Thực tế (README / CHANGELOG vs Code)
- **Tính năng mô tả:** Toàn bộ các API chính (`AdManager`, `BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget`, `VipManager`, `ConsentManager`, `AdSafetyConfig`, `InlineAdController`) khớp hoàn toàn với mô tả trong README.
- **Các giới hạn nền tảng:** README trình bày rất trung thực và chi tiết các hạn chế kiến trúc (Android VIP anti-bypass yếu hơn iOS, AppLovin không có ad-freshness timestamp, AppLovin consent platform write là fire-and-forget, `IndexedStack` cần gắn cờ `active` thủ công).

---

## Kết luận & Quyết định (Final Verdict)

### **VERDICT: CONDITIONAL (YES — Có điều kiện)**

### Lý do tóm tắt:
1. **Chất lượng cốt lõi xuất sắc:** Bộ code của `applovin_admob_sdk` 3.0.10 thể hiện độ hoàn thiện và kỷ luật lập trình cực kỳ cao. Toàn bộ 2,218 bài test vượt qua 100%, không có warning static analysis nào.
2. **Tuân thủ chính sách nghiêm ngặt:** Kiến trúc UMP-first, bảo vệ trẻ em theo COPPA, chặn test ID trong release, và mutex tránh hiển thị ad đè lên dialog/form đồng thuận đều hoạt động hoàn hảo.
3. **Điều kiện để đưa vào Production:**
   Trước khi gắn tag release tiếp theo (3.0.11), cần xử lý dứt điểm 2 finding **MAJOR** nêu trên:
   - Thêm guard `isActuallyRelease` vào `VipManager.clearRedeemedKeyLedgerForTest()` để khoá cứng khả năng xoá sổ cái Keychain chống dùng lại VIP key trong release.
   - Thêm guard `kReleaseMode` vào `debugFormDismissTimeoutOverride` (hoặc ẩn khỏi export barrel file) để bảo vệ tính toàn vẹn của thời gian chờ form UMP consent.
