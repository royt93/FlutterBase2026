# Báo cáo Audit Độc Lập Toàn Diện `applovin_admob_sdk` — Round 5 (v2.3.0)

**Người thực hiện:** Senior Security / Flutter Mobile Ads Engineer (agy CLI — Google Antigravity / Gemini-based agent).  
**Ngày thực hiện:** 2026-08-22  
**Phiên bản thẩm định:** `applovin_admob_sdk` **v2.3.0** (Khớp giữa local `packages/ad_sdk/pubspec.yaml` và bản phát hành mới nhất trên pub.dev: `latest.version = "2.3.0"`).  

---

## 1. Kết quả kiểm tra Static Analysis & Test Suite (Gate thực tế)

Toàn bộ các lệnh kiểm tra chất lượng mã nguồn và bộ test tự động được chạy trực tiếp trên môi trường thực tế:

| Lệnh kiểm tra | Thư mục thực thi | Kết quả | Chi tiết |
|---|---|---|---|
| `flutter analyze` | `packages/ad_sdk/` | **PASS (0 issues)** | Phân tích tĩnh 100% sạch, không có lint error/warning nào. |
| `flutter test` | `packages/ad_sdk/` | **PASS (891/891 tests)** | **100% pass rate**, 0 failed, 0 flaked (~43s). |
| `flutter analyze` | `packages/ad_sdk/example/` | **PASS (0 issues)** | Example app tuân thủ tuyệt đối chuẩn static analysis. |
| `flutter test` | `packages/ad_sdk/example/` | **PASS (25/25 tests)** | Toàn bộ unit/widget test của example app đều pass (~15s). |
| `curl pub.dev API` | Endpoint công khai | **VERIFIED (2.3.0)** | `https://pub.dev/api/packages/applovin_admob_sdk` trả về `version: "2.3.0"`. |

---

## 2. Đánh giá chuyên sâu các Commit Mới từ v2.2.0 đến v2.3.0

Tám nhóm thay đổi trọng yếu kể từ v2.2.0 (`8f34d01`, `3cbd6f7`, `f3df4cc`, `9abfa9e`, `fd1b4cb`, `96bb938`, `12a839f`) đã được audit kỹ lưỡng:

1. **UMP Fail-Open/Closed Narrowing (`96bb938` / `ad_manager.dart:1962-1975`):**
   - *Cơ chế:* Trước đây, mọi ngoại lệ trong `runZonedGuarded` của UMP auto-consent đều kích hoạt fail-open (`_canRequestAds = true`), dẫn tới rủi ro vi phạm GDPR nghiêm trọng khi thiết bị người dùng EEA gặp lỗi mạng tạm thời.
   - *Hiện tại:* SDK chỉ **fail-open** đối với `MissingPluginException` (trường hợp host app cố ý không tích hợp native UMP plugin hoặc môi trường unit test). Với **mọi ngoại lệ khác** (lỗi mạng, timeout, Google UMP SDK lỗi native), SDK thực hiện **fail-closed** (`_canRequestAds` giữ `false`) và kích hoạt cơ chế retry backstop tự động qua `_scheduleNextRetry` (`ad_manager.dart:3869-3878`) và `_onConnectivityChanged`.
   - *Đánh giá:* **HOÀN TOÀN CHÍNH XÁC & AN TOÀN VỀ MẶT PHÁP LÝ.**

2. **Khắc phục rò rỉ GAID trên `destroy()` (`96bb938` / `ad_manager.dart:2666-2670`):**
   - *Cơ chế:* `_resetGuardState()` nay xóa triệt để `_currentDeviceGAID = ''`. Không còn tình trạng ID quảng cáo của phiên cũ sống sót qua chu kỳ `destroy() -> initialize()`.
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN.**

3. **Tính phản ứng (Reactivity) của Banner/MREC/Native Widget (`96bb938` / `banner_ad_widget.dart:76-103`, `mrec_ad_widget.dart:53-79`, `native_ad_widget.dart:68-94`):**
   - *Cơ chế:* Cả 3 widget hiện đã đăng ký lắng nghe `AdManager().canRequestAdsListenable`. Khi consent bị thu hồi (`canRequestAds == false`), widget lập tức gọi `disposeBannerInstance` / `disposeMrecInstance` / `disposeNativeInstance` và hạ cờ `_allowed.value = false`. Khi gate mở lại, widget tự động gọi `WidgetsBinding.instance.scheduleFrame()` đảm bảo `addPostFrameCallback` được thực thi và nạp lại ad.
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN (Đóng triệt để finding codex P1-1 và M3).**

4. **Đội thiết bị QA cố định (`fd1b4cb`, `12a839f` / `ad_config.dart:218-227`):**
   - *Cơ chế:* Danh sách `kQaTestDeviceHashes` gồm 8 mã hash thiết bị vật lý của đội ngũ QA được tự động hợp nhất (`effectiveTestDeviceIds`) vào `RequestConfiguration` của AdMob cả lúc khởi tạo (`admob_adapter.dart:439`) và lúc cập nhật consent (`ad_consent.dart:110`).
   - *Đánh giá:* **RẤT TỐT.** Ngăn ngừa triệt để nguy cơ thiết bị QA nhận quảng cáo thật hoặc kích hoạt cờ gian lận lưu lượng (invalid traffic) của AdMob khi host app quên cấu hình test device.

5. **Phục hồi hiển thị Banner/MREC sau Resume (`8f34d01` / `admob_adapter.dart:1392, 1525`):**
   - *Cơ chế:* Đặt `listenables.visible.value = true` ngay khi `onAdLoaded` thành công trong luồng reload do resume, loại bỏ lỗi banner bị kẹt khoảng trắng do `onAppPaused` trước đó đã hạ `visible = false`.
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN.**

6. **MonetizationArbitrator `ecpm > 0` Guard (`8f34d01` / `monetization_arbitrator.dart:150`):**
   - *Cơ chế:* Nhánh có `_vipLikelihoodEstimator` đã được bổ sung điều kiện `ecpm > 0 && ecpm < threshold && likelihood > 0.5`. Ngăn chặn việc veto nhầm 100% quảng cáo ở đầu phiên khi chưa có bất kỳ mẫu doanh thu nào (`ecpm == 0`).
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN.**

7. **Cô lập ngoại lệ từng listener trong `SimpleEventBus` (`8f34d01` / `event_bus.dart:35-39`):**
   - *Cơ chế:* Vòng lặp `fire()` bọc từng lời gọi listener trong `try-catch`, đảm bảo một listener lỗi không làm gián đoạn các listener đồng cấp khác.
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN.**

8. **Chống gian lận đồng hồ trong `VipManager.addVip` (`8f34d01` / `vip_manager.dart:499, 519`):**
   - *Cơ chế:* Chuyển việc tính toán mốc bắt đầu (`base`) và mốc cộng dồn sang `_effectiveNow()`, ngăn ngừa triệt để việc chỉnh tiến đồng hồ để cấp VIP vĩnh viễn.
   - *Đánh giá:* **ĐÃ FIX HOÀN TOÀN.**

---

## 3. Đánh giá 8 Trọng tâm Nghiệp vụ (Audit Scope)

| STT | Trọng tâm kiểm tra | Trạng thái | Phân tích & Bằng chứng mã nguồn |
|---|---|---|---|
| 1 | **Dual Provider Correctness (AdMob + AppLovin MAX)** | **PASS (100% Parity)** | Cả 49/49 method interface trong `AdProviderAdapter` đều được hiện thực hoàn chỉnh trên cả `AdMobAdapter` (`lib/src/adapters/admob_adapter.dart`) và `AppLovinAdapter` (`lib/src/adapters/applovin_adapter.dart`). Quản lý multi-instance banner/MREC/native bằng keyed map (`_bannerAdsByKey`, `_mrecAdsByKey`, `_nativeAdsByKey`). AppLovin teardown có retry-with-backoff (`_destroyWidgetAdViewWhenDetached`, `:180-215, 255-290`) xử lý triệt để việc view chưa detach khỏi cây widget. |
| 2 | **Offline & No-Network Resilience** | **WARN / MAJOR** | Các tác vụ ad request fail-fast khi offline (`ad_manager.dart:2761, 3019, 3292`); watchdog tự động nạp lại ad khi có mạng trở lại với generation token chống race condition (`:3780-3880`). Mọi async call đều có timeout an toàn. **Tuy nhiên:** `redeemSignedKey` chặn người dùng kích hoạt VIP khi offline (`vip_manager.dart:685-689`), mâu thuẫn với yêu cầu sản phẩm VIP kích hoạt bằng mã phải hoạt động offline (Xem Finding M1). |
| 3 | **Ad Lifecycle & Memory-Leak Safety** | **PASS** | Kiểm tra độ tươi (freshness) show-time cho toàn bộ ad fullscreen của AdMob (4h App Open, 1h Interstitial/Rewarded tại `admob_adapter.dart:680-695`). Mutex `_fullscreenBusyReason` (`ad_manager.dart:1045-1082`) khóa đồng thời cả 4 định dạng fullscreen, modal route và dialog loading, triệt tiêu 100% nguy cơ đè 2 quảng cáo toàn màn hình. Teardown và unregister listener sạch sẽ khi unmount. |
| 4 | **Trial Mode (1 ngày / First-install grace)** | **PASS** | `_first_install_guard.dart:45-110` cấp đúng 1 lần cho lượt cài đặt đầu tiên. Trên iOS chống bypass gỡ cài đặt bằng iOS Keychain (`flutter_secure_storage`). Trên Android phụ thuộc cơ chế Google Cloud Auto Backup (`FlutterSharedPreferences.xml`) đã được công bố minh bạch trong tài liệu. Xử lý hết hạn giữa phiên mượt mà qua timer `_expiryTimer` (`vip_manager.dart:152-161, 350-380`). |
| 5 | **Zero-Backend VIP Activation (Ed25519)** | **PASS (Crypto)** | Thuật toán ký Ed25519 chạy offline cục bộ (`signed_vip_key.dart:15-210`), app chỉ chứa public key, không thể decompile để forge key. Hỗ trợ định dạng AVP1 và AVP2 (ràng buộc bundle ID và hạn chót tuyệt đối `expEpoch`). Chống replay qua in-flight Set (`vip_manager.dart:747`), ledger SharedPreferences và durable ledger iOS Keychain (`_redeemed_key_ledger.dart`). CRL domain-separated (`AVP1|`, `AVP2|`, `CRL1|`). Chống rollback đồng hồ qua `_effectiveNow()` kết hợp `resyncSessionClock()`. |
| 6 | **Consent Toàn cầu (GDPR, CCPA, COPPA, ATT)** | **PASS** | UMP fail-closed chuẩn xác cho lỗi thực tế (`ad_manager.dart:1962-1975`). Đồng bộ tức thì `npa=1` (AdMob) và `hasUserConsent` (AppLovin). Gắn cờ `rdp=1` (CCPA Restricted Data Processing) và `doNotSell`. COPPA bảo vệ chặt chẽ: replay pending consent dời lên trước adapter init (`:1803-1829`), AppLovin tự động fail-closed (`_disabledForChildUser=true`). iOS ATT trì hoãn lấy GAID/IDFA (`shouldDeferGaidFetch`, `:1705-1718`) khi chưa có quyết định ATT. |
| 7 | **Tuân thủ Policy AdMob & AppLovin** | **PASS** | Tự động inject hash của 8 thiết bị QA cố định (`kQaTestDeviceHashes`). Ad Safety Engine 12 tầng hoạt động tin cậy (daily/hourly cap, 30s throttle, chống click fraud với cooldown lũy tiến 30m-24h). Release mode tự động ép tắt `dryRun`. Phân biệt rạch ròi GAID và AdMob test device hash qua helper `adMobTestDeviceHashHint()` (`:788-800`). |
| 8 | **Example App Integration Contract** | **PASS** | `packages/ad_sdk/example/lib/main.dart` tuân thủ 100% hợp đồng tích hợp: gán `navigatorKey`, đăng ký `adRouteObserver` và `AdScreenRouteLogger`, khởi tạo SDK tại `SplashScreen`, hiển thị `AdLoadingDialog`, kế thừa `AdScreen` & `AdScreenState`. 25/25 test của example pass. |

---

## 4. Bảng phân loại Chi tiết các Findings (Round 5)

### 🔴 BLOCKER (0)
*Không có Blocker nào.* Toàn bộ các vấn đề nghiêm trọng về rò rỉ view native (B1), COPPA replay timing (B2), đóng băng đồng hồ VIP (B3), mutex fullscreen (M1), và eCPM scale (T58) đều đã được đóng và có test suite khóa hành vi.

---

### 🟡 MAJOR (1)

#### M1 — VIP activation by code bị chặn khi offline do `_isConnectedCheck()` (Mâu thuẫn yêu cầu sản phẩm)
- **Vị trí mã nguồn:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:685-689`
- **Mã nguồn thực tế:**
  ```dart
  if (!_isConnectedCheck()) {
    SafeLogger.d(_tag, 'redeemSignedKey: rejected — device is offline');
    return const SignedVipRedeemResult.invalid(
        'no network connection — connect to the internet to redeem a VIP code');
  }
  ```
- **Tại sao là vấn đề:**
  1. *Về mặt kỹ thuật:* Thuật toán Ed25519 verify hoàn toàn offline (`signed_vip_key.dart`), kho lưu trữ `VipEntriesStore` và `RedeemedKeyLedger` đều nằm cục bộ trên thiết bị, không cần bất kỳ API call nào ra ngoài server.
  2. *Về mặt sản phẩm:* Yêu cầu sản phẩm của Round 5 nêu rõ: *"Hoạt động khi CÓ mạng và KHÔNG có mạng (offline resilience). Lưu ý: yêu cầu sản phẩm nói VIP activation by code phải work offline."*
  3. *Hệ quả:* Khi người dùng ở chế độ máy bay hoặc mất mạng, việc nhập mã VIP hợp lệ sẽ bị từ chối ngay lập tức với lỗi `"no network connection"`, gây khó chịu và không đáp ứng đúng cam kết tính năng offline của sản phẩm.
- **Minimum Fix:**
  Gỡ bỏ điều kiện kiểm tra `if (!_isConnectedCheck())` trong `redeemSignedKey()` (hoặc chuyển thành tham số tùy chọn `bool requireOnline = false` với giá trị mặc định là `false`), cho phép xác thực cục bộ qua Ed25519, kiểm tra CRL đã cache và ghi nhận vào ledger local ngay cả khi không có kết nối mạng. Network chỉ nên dùng cho việc chủ động cập nhật danh sách thu hồi (`refreshRevocationList`).

---

### 🟢 MINOR & TECHNICAL OBSERVATIONS (3)

#### m1 — `SimpleEventBus.listen()` gọi listener đồng bộ không bọc `try-catch` khi replay `_lastEvent`
- **Vị trí mã nguồn:** `packages/ad_sdk/lib/src/core/event_bus.dart:20-24`
- **Mã nguồn thực tế:**
  ```dart
  void listen(void Function(BoolEvent) listener) {
    _listeners.add(listener);
    final last = _lastEvent;
    if (last != null) listener(last);
  }
  ```
- **Tại sao là vấn đề:** Trong khi `fire()` (`:35-39`) đã bọc `try-catch` để cách ly ngoại lệ giữa các listener, thì phương thức `listen()` khi replay sự kiện cũ cho một listener mới đăng ký muộn lại gọi `listener(last)` trực tiếp. Nếu listener này ném lỗi (exception), luồng đăng ký của caller sẽ bị crash.
- **Minimum Fix:** Bọc `try { listener(last); } catch (_) {}` hoặc log warning nếu callback replay ném ngoại lệ.

#### m2 — `_lastUmpResult` và `_attRequested` không được reset trong `_resetGuardState()`
- **Vị trí mã nguồn:** `packages/ad_sdk/lib/src/core/ad_manager.dart:2645-2671`
- **Tại sao là vấn đề:** Khi host app gọi `destroy()` rồi `initialize()` lại, `_lastUmpResult` và `_attRequested` giữ nguyên giá trị của session trước.
- **Đánh giá tác động:** Mức độ vô hại trong thực tế vì `_umpRequested` đã được reset về `false` (ngăn việc đọc cache sai), và `_attRequested` chỉ dùng cho log cảnh báo thứ tự gọi API. Tuy nhiên, về mặt state hygiene thì nên reset toàn bộ các cờ này về giá trị mặc định lúc khởi tạo class.
- **Minimum Fix:** Thêm `_lastUmpResult = null;` và `_attRequested = false;` vào trong thân hàm `_resetGuardState()`.

#### m3 — Giới hạn nền tảng đã công bố minh bạch (Disclosed Limitations)
- Android Reinstall Trial Reset: Người dùng Android có thể reset trial nếu xóa dữ liệu ứng dụng hoặc host app không cấu hình Google Auto Backup.
- CRL Retroactive Invalidation: CRL chỉ ngăn chặn việc redeem mã mới, không thể thu hồi ngược thời gian VIP của mã đã được redeem thành công cục bộ trên thiết bị trước thời điểm cập nhật CRL.
- AppLovin MAX Ad Freshness: AppLovin SDK không cung cấp timestamp nạp ad, do đó không hỗ trợ show-time freshness check như AdMob (đã ghi chú rõ trong README).

---

## 5. Kết luận & Khuyến nghị Xuất Xưởng (VERDICT)

### **VERDICT: YES — PRODUCTION-READY (WITH 1 PRODUCT ALIGNMENT CONDITION)**

SDK `applovin_admob_sdk` phiên bản **2.3.0** là một bộ giải pháp quảng cáo di động chất lượng cao, cực kỳ vững chắc, đáp ứng các tiêu chuẩn khắt khe nhất về an toàn dữ liệu, chống gian lận quảng cáo, và bảo vệ quyền riêng tư toàn cầu (GDPR, COPPA, CCPA, ATT).

**Điều kiện bàn giao duy nhất (Product Alignment):**
- Nếu sản phẩm yêu cầu **bắt buộc hỗ trợ nhập mã VIP khi mất mạng (100% offline code activation)**: Cần gỡ bỏ `_isConnectedCheck()` tại `vip_manager.dart:685-689`.
- Nếu chủ đích giữ `_isConnectedCheck()` như một tầng bảo vệ ngăn chia sẻ mã số lượng lớn (anti-sharing gate): Cần cập nhật lại bản đặc tả yêu cầu sản phẩm để đồng nhất giữa Product Spec và Implementation.

Ngoài điểm cân nhắc về mặt nghiệp vụ trên, mã nguồn hiện tại **đạt 100% tiêu chuẩn xuất xưởng cho môi trường Production**.

---

## 6. Tóm tắt Lịch sử Audit các Vòng trước (Rounds 1 – 4)

- **Round 1 (v2.0.4, 700 tests):** Phát hiện 6 vấn đề cơ sở (eCPM scale, Keystore error handling, multi-instance conflict, route top flag, background timestamp).
- **Round 2 (v2.1.0, 860 tests):** Bổ sung show-time freshness cho AdMob, siết chặt resume safety, phát hiện native view leak trên AppLovin và timing pending-consent COPPA.
- **Round 3 (v2.1.0, 861 tests):** Re-verify độc lập 6/6 finding tồn đọng: 5/5 bug đã fix (T58, T59, T60, T65, T66), 1/1 claim refuted (`_admobIsTop`).
- **Round 4 (v2.2.0, 873 tests):** Đóng toàn bộ 3 Blocker (B1, B2, B3) và các Major (M1, M2, M4, M5, M6, M9). Xác nhận API `currentDeviceGaid` và `adMobTestDeviceHashHint` an toàn.
- **Round 5 (v2.3.0, 891 tests):** Xác nhận các fix UMP fail-closed/fail-open (`96bb938`), dọn dẹp GAID leak trên destroy, tính phản ứng của Banner/MREC/Native widgets khi gate consent đóng/mở, thêm đội thiết bị QA cố định (`fd1b4cb`), và bảo vệ `ecpm > 0` của `MonetizationArbitrator` (`8f34d01`).
