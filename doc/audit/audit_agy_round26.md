# Báo Cáo Audit Bảo Mật & Compliance — Round 26 (Antigravity Reviewer)

**Package:** `applovin_admob_sdk` (Flutter SDK dual-provider AdMob + AppLovin MAX)  
**Phiên bản audit:** `2.4.0` (Khớp HEAD commit `1680214` và bản live trên pub.dev)  
**Ngày thực hiện:** 2026-08-31  
**Phạm vi audit:** Toàn bộ `packages/ad_sdk/lib/`, `test/`, `example/`, `README.md`, `CHANGELOG.md`, live metadata trên `pub.dev`, và toàn bộ lịch sử Git liên quan.  
**Nguyên tắc audit:** Độc lập, chỉ đọc (Read-only, không can thiệp sửa code), re-verify 2 lần trực tiếp trên source code thật.

---

## 1. Kết Luận Nhanh (Executive Summary)

| Hạng mục | Trạng thái | Đánh giá / Ghi chú |
|---|---|---|
| **Trạng thái phê duyệt Production** | 🛑 **BLOCKED (Tạm thời không duyệt)** | Bị chặn bởi **BLOCKER R26-B1** (Lộ credential production trong Git history). |
| **Chất lượng mã nguồn & Logic** | ✅ **RẤT TỐT (9.5/10)** | 1.336/1.336 tests pass, `flutter analyze` 0 issues. Các cơ chế mutex, caps, lifecycle, offline gate, VIP offline Ed25519 cực kỳ vững chắc. |
| **Pub.dev Score (v2.4.0)** | ℹ️ **150 / 160 điểm** | Mất 10 điểm ở mục *Dependency freshness* do pin `google_mobile_ads: ^7.0.0` (bản mới nhất 9.1.0) và `package_info_plus: ^9.0.0` (bản mới nhất 10.2.1) để giữ tương thích Flutter. |
| **Baseline Verification (Round 23–25)** | ✅ **ĐÃ XÁC NHẬN** | Tất cả các fix trước đó (MJ1, MJ2, MJ9, DisplayConfirmation, Footgun logger, Teardown decoupling) hoạt động chính xác. Không có regression. |

---

## 2. Phát Hiện Mới (Findings)

### 🔴 Finding R26-B1 — Credential AppLovin Production và AdMob ID bị lộ trong lịch sử Git

- **Mức độ nghiêm trọng:** **BLOCKER (Bảo mật & Account Policy)**
- **Vị trí phát hiện:**
  1. `packages/ad_sdk/doc/archive/AD.MD` tại commit `2433578` (release 2.4.0), dòng 98–106: Chứa AppLovin SDK Key (86 ký tự), 8 MAX Ad Unit IDs (4 Android, 4 iOS) và AdMob App ID production (`ca-app-pub-3612191981543807~9731053733`).
  2. `packages/ad_sdk/example/lib/splash_screen.dart` tại các commit lịch sử (ví dụ commit `86ca1b5`): Chứa hardcode AppLovin SDK key và Ad Unit IDs thật.
  3. `packages/ad_sdk/README.md:1893`: Khẳng định `“...nothing real is committed to source”` — tuyên bố này mâu thuẫn với lịch sử Git của repository.
  4. `packages/ad_sdk/.pubignore:44-51`: Thư mục `doc/*` bị loại khỏi package publish nên file không bị lộ trên tarball pub.dev 2.4.0. Tuy nhiên, bất kỳ ai có quyền truy cập repo git đều đọc được đầy đủ secret.

- **Mô tả chi tiết:**
  Ở commit HEAD, commit `0f503ba` đã thực hiện xóa file `packages/ad_sdk/doc/archive/AD.MD` với message `"security(ad_sdk): remove doc/archive/AD.MD (leaked real AppLovin SDK key)"`. Tuy nhiên, trong mô hình bảo mật của Git, việc thực hiện commit xóa file trong working tree **KHÔNG** hề thu hồi hay xóa blob khỏi lịch sử repository. Lệnh `git show 2433578:packages/ad_sdk/doc/archive/AD.MD` vẫn trích xuất nguyên văn toàn bộ key và ad unit ID thật.

- **Kịch bản rủi ro:**
  - **Tấn công lạm dụng Key / Click Fraud / Traffic Bất hợp lệ:** Kẻ xấu lấy AppLovin SDK key và ad unit ID để cấu hình vào ứng dụng rác hoặc spam request tự động nhằm phá hoại điểm tín nhiệm hoặc kích hoạt cờ gian lận (invalid traffic) từ AppLovin.
  - **Trừng phạt tài khoản (Account Suspension / Ban):** Khi phát hiện traffic bất thường từ nguồn không xác định gắn với SDK key / ad units này, AppLovin có thể đình chỉ tài khoản mạng quảng cáo của publisher.
  - **Sai lệch doanh thu & Analytics:** Doanh thu và số liệu phân tích của ứng dụng thật bị ô nhiễm.

- **Re-verify (Đã xác minh 2 lần độc lập):**
  - *Lần 1:* Kiểm tra commit `0f503ba` xác nhận diff xóa file `AD.MD`.
  - *Lần 2:* Thực hiện `git log -p -S` trên repository và `git show 2433578:packages/ad_sdk/doc/archive/AD.MD` xác nhận blob chứa SDK Key 86 ký tự và 8 Ad Unit ID cùng SHA-256 `0f4ee01e050436fbf9118dfbcc53b30e4d542c143e100039289303ed2e29c2ad`.

- **Điều kiện khắc phục để đóng finding:**
  1. **Bắt buộc:** Truy cập AppLovin Dashboard (`dash.applovin.com`), thực hiện **Rotate / Revoke** AppLovin SDK Key và toàn bộ 8 Ad Unit ID đã bị lộ; tạo bộ key mới cho production app.
  2. Cập nhật production app với bộ credential mới được cấp qua biến môi trường (`--dart-define`) hoặc server config bảo mật, tuyệt đối không đưa vào source/doc.
  3. Nếu repo là public hoặc từng share ra ngoài: Cần thực hiện quy trình Git filter-repo / BFG Repo-Cleaner để loại bỏ hoàn toàn blob khỏi lịch sử Git (lưu ý: việc này bổ trợ cho việc dọn repo, nhưng không thay thế được việc Rotate Key trên dashboard).
  4. Điều chỉnh câu văn tại `README.md:1893` cho chính xác và thiết lập pre-commit hook / git-secrets scanning.

---

## 3. Đánh Giá Chi Tiết 7 Yêu Cầu Sản Phẩm

### Yêu cầu 1: Dual Provider AdMob + AppLovin, chạy đúng cả Android và iOS
- **Mã nguồn kiểm tra:** `lib/src/adapters/admob_adapter.dart`, `lib/src/adapters/applovin_adapter.dart`, `lib/src/core/ad_manager.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - Tách biệt rõ ràng giữa AdMob (`google_mobile_ads`) và AppLovin MAX (`applovin_max`).
  - Hỗ trợ switch provider thông qua cấu hình `AdConfig.provider` (`AdProvider.admob` hoặc `AdProvider.appLovin`) hoặc A/B test cohort bằng `pickProviderCohort()`.
  - Xử lý platform-specific chính xác:
    - Android: Hỗ trợ GAID, auto-backup rules, platform views.
    - iOS: Tích hợp ATT (`app_tracking_transparency`) trước khi init, SKAdNetwork items, xử lý timeout watchdog phù hợp với lifecycle iOS (không nhầm trạng thái `resumed` của iOS thành hang).

### Yêu cầu 2: Hành vi đúng cả khi có mạng và KHÔNG có mạng
- **Mã nguồn kiểm tra:** `lib/src/core/ad_manager.dart`, `lib/src/state/backoff.dart`, `lib/src/consent/consent_manager.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - **Khi mất mạng:**
    - Mọi lệnh `load*` và `show*` được chặn an toàn qua `_isConnectedCheck` / `isConnected`, phát `AdSkipEvent(..., reason: 'offline')`, không gây unhandled exception hay crash.
    - `BannerAdWidget`, `MrecAdWidget` xử lý offline êm ái, ẩn view và không spam reload.
    - Consent UMP offline: Cơ chế fail-closed giữ nguyên giá trị consent đã lưu trước đó thay vì hạ cấp (downgrade) gây mất quyền load ad.
  - **Khi có mạng trở lại:**
    - `_onConnectivityChanged` có debounce (`800ms`) chống flapping, tự động kích hoạt nạp lại (`refill`) cho các slot quảng cáo và banner widget một cách trật tự.

### Yêu cầu 3: Cả 4 loại ad (banner / app open / rewarded / interstitial) đúng pháp lý, đúng vòng đời, không memory leak
- **Mã nguồn kiểm tra:** `lib/src/adapters/`, `lib/src/widget/`, `lib/src/core/ad_route_observer.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - **Chống chồng chéo (No-stacking):** Cơ chế `fullscreenBusy` và `_fullscreenBusyReason` ngăn chặn triệt để việc mở 2 quảng cáo toàn màn hình cùng lúc (ví dụ App Open đè lên Interstitial hay Rewarded).
  - **Ẩn banner/MREC khi hiện quảng cáo toàn màn hình (Fix 6):** Cả `AdMobAdapter` và `AppLovinAdapter` đều triển khai `InlineAdVisibility`, tự động ẩn / tạm dừng auto-refresh của banner/MREC trong suốt thời gian App Open / Interstitial hiển thị, tránh vi phạm policy của Google/AppLovin.
  - **Vòng đời Route-Aware:** `BannerAdWidget` và `MrecAdWidget` tích hợp `RouteAware`, tự động pause auto-refresh khi route bị che khuất và resume khi quay lại màn hình chính.
  - **Memory Leak:** Mọi `AdSlot`, `ValueNotifier`, `Timer`, `StreamController`, `StreamSubscription` và native platform views (`_destroyWidgetAdViewWhenDetached`) đều được dọn dẹp kỹ lưỡng trong các phương thức `dispose()` và `destroy()`.
  - **Display Confirmation:** `RewardResult.shown` được neo vào `AdSlot.displayConfirmed` (tín hiệu ad thực sự lên màn hình), không phụ thuộc vào kết quả đóng hay nhận thưởng.

### Yêu cầu 4: Chế độ dùng thử 1 ngày (1-Day Trial Mode)
- **Mã nguồn kiểm tra:** `lib/src/vip/_first_install_guard.dart`, `lib/src/vip/vip_manager.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - Mặc định cấp 24 giờ VIP ad-free trên bản release (`FirstInstallVipGrace.day` / `.auto`) ngay lần đầu khởi chạy.
  - Lưu trữ bền vững chống bypass: Trên iOS dùng Keychain (tồn tại qua cả chu kỳ xóa và cài lại app). Trên Android dùng SharedPreferences (hỗ trợ Auto Backup).
  - **Grace Nudge Threshold Clamp:** Ngưỡng nhắc sắp hết hạn VIP (`graceNudgeThreshold`) được tự động giới hạn ở mức 50% thời lượng cấp phát (tối đa 12h cho gói 24h), tránh việc người dùng mới cài app bị hiện popup cảnh báo hết hạn ngay trong phiên đầu tiên.

### Yêu cầu 5: Kích hoạt VIP bằng code, bảo mật mà KHÔNG có server/backend nào
- **Mã nguồn kiểm tra:** `lib/src/vip/vip_manager.dart`, `lib/src/vip/signed_vip_key.dart`, `lib/src/vip/_redeemed_key_ledger.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - **Xác thực chữ ký Offline:** Sử dụng thuật toán Ed25519 (`cryptography` package). Chỉ có Public Key được đóng gói trong app; Private Key giữ bí mật offline để mint code.
  - **Định dạng AVP2:** Nhúng trực tiếp thời hạn hết hạn mã (`expiresAt`) và ràng buộc Bundle ID (`bundleId`) vào payload có chữ ký, ngăn chặn việc tái sử dụng key của app khác hoặc key đã quá hạn mint.
  - **Chống Replay (One-Time-Use Ledger):** Mỗi mã có `keyId` duy nhất, được lưu vào `RedeemedKeyLedger` (KeyChain trên iOS) ngăn chặn redeem lại nhiều lần trên cùng thiết bị.
  - **Chống lùi đồng hồ (Anti-Rollback Clock):** Sử dụng `_effectiveNow()` duy trì High-Water Mark thời gian đã ghi nhận.
  - **Chống tua đồng hồ tới tương lai (MJ9 Fix):** Hàm `_isLive()` kết hợp kiểm tra 2 điều kiện độc lập: vừa không quá hạn so với High-Water Mark (`isActiveAt(now)`), vừa phải đã bắt đầu theo đồng hồ thực tế của thiết bị (`DateTime.now() + 1h >= grantedAt`).
  - **Danh sách thu hồi mã (Signed CRL):** Hỗ trợ nạp CRL có chữ ký (phân định miền `CRL1|`) để thu hồi các key bị rò rỉ mà không cần xoay Public Key.

### Yêu cầu 6: Consent cho mọi quốc gia (GDPR/EEA, US Privacy, COPPA...)
- **Mã nguồn kiểm tra:** `lib/src/consent/`, `lib/src/core/ump_consent.dart`, `lib/src/core/ad_consent.dart`, `lib/src/core/iab_storage.dart`.
- **Kết quả:** **ĐẠT (PASS)**
  - **GDPR / EEA:** Tích hợp Google UMP SDK, đọc/ghi chuỗi IAB TCF v2.3 (`IABTCF_TCString`). Tự động truyền cờ `hasUserConsent` tới AppLovin và AdMob `npa=1` nếu không có đồng ý.
  - **US State Privacy / CCPA:** Cờ `doNotSell` được truyền tới `AppLovinMAX.setDoNotSell(true)` và AdMob Restricted Data Processing (`extras: {'rdp': '1'}`).
  - **COPPA (Trẻ em):** Cờ `isAgeRestrictedUser` truyền tới AdMob `tagForChildDirectedTreatment`. Đối với AppLovin (MAX 4.x không có runtime COPPA API), `AppLovinAdapter` chủ động từ chối khởi tạo nếu phát hiện user là trẻ em (T40 - init gate).
  - **TFUA:** Hỗ trợ `tagForUnderAgeOfConsent` trên AdMob RequestConfiguration.
  - **iOS ATT:** Cung cấp helper `AdManager().requestAtt()` gọi trước UMP/AdMob init theo đúng khuyến nghị của Apple và Google.

### Yêu cầu 7: Tuân thủ Policy AdMob/AppLovin (Bảo vệ tài khoản publisher)
- **Mã nguồn kiểm tra:** `lib/src/core/ad_safety_config.dart`, `lib/src/adapters/`.
- **Kết quả:** **ĐẠT (PASS - Ngoại trừ việc cần rotate key ở R26-B1)**
  - **12 lớp bảo vệ Anti-Fraud:**
    - Giới hạn tần suất: Min time giữa các ad toàn màn hình (`60s`), warmup đầu session (`10s`), min time background trước khi hiện App Open on resume (`5s`).
    - Giới hạn số lượng (Caps): Session cap (`6`), Hourly cap (`3`), Daily cap (`5` - lưu SharedPreferences).
    - Giới hạn CTR & Click Spam: Tự động pause quảng cáo từ 30 phút đến 24 giờ nếu CTR vượt quá 30% (sau tối thiểu 5 impressions) hoặc click quá 3 lần/phút.
  - **Bảo vệ thiết bị QA:** `kQaTestDeviceHashes` luôn được tự động merge vào AdMob `testDeviceIds` để máy test nội bộ không bao giờ tạo real impression vi phạm policy.

---

## 4. Tình Trạng Pub.dev & Kiểm Tra Tài Liệu

- **Pub.dev Package:** `https://pub.dev/packages/applovin_admob_sdk`
- **Phiên bản mới nhất:** `2.4.0` (Publish lúc `2026-08-30T17:38:09Z`).
- **Pub Points:** **150 / 160**
  - Follow Dart file conventions: **30 / 30**
  - Provide documentation: **20 / 20** (60.4% API elements có dartdoc)
  - Platform support: **20 / 20** (Hỗ trợ Android, iOS)
  - Pass static analysis: **50 / 50** (0 warnings, 0 lints)
  - Support up-to-date dependencies: **30 / 40** (Mất 10 điểm do pin `google_mobile_ads: ^7.0.0` và `package_info_plus: ^9.0.0` để tương thích Flutter floor `3.27.0`).
- **So khớp README "Known limitations" với Source code:**
  - Mục Known Limitations trong README mô tả trung thực và chính xác các giới hạn: cơ chế Android clear-data, AppLovin không có load timestamp cho ad-freshness, giới hạn test creative upstream của Google, và phạm vi không có RouteAware cho Native ads.
  - **Điểm không khớp duy nhất:** Dòng `README.md:1893` tuyên bố "nothing real is committed to source" cần được cập nhật sau khi xử lý finding R26-B1.

---

## 5. Kết Quả Kiểm Thử Tự Động (Automated Verification)

- **Static Analysis:**
  ```bash
  flutter analyze
  # Kết quả: No issues found! (0 errors, 0 warnings, 0 lints)
  ```
- **Unit & Widget Test Suite:**
  ```bash
  flutter test
  # Kết quả: 01:13 +1336: All tests passed! (1336/1336 tests green)
  ```

---

## 6. Phán Quyết Cuối Cùng (Production Verdict)

### 🛑 KẾT LUẬN: TẠM THỜI KHÔNG DUYỆT (BLOCKED)

**Lý do:** SDK đạt chất lượng kỹ thuật rất cao (1.336 tests green, kiến trúc phân tách sạch sẽ, xử lý race-condition và compliance cực kỳ chặt chẽ), nhưng **Finding BLOCKER R26-B1** (AppLovin SDK Key và Ad Unit IDs thật bị lộ trong lịch sử Git) mang lại rủi ro trực tiếp về tài khoản và an toàn doanh thu.

### 📋 ĐIỀU KIỆN ĐỂ DUYỆT VÀO PRODUCTION APP THẬT:

1. **Rotate Credential:** Thực hiện Rotate/Revoke toàn bộ AppLovin SDK Key và 8 Ad Unit IDs trên AppLovin Dashboard.
2. **Cập nhật App Config:** Đảm bảo production app chỉ nhận SDK Key và Ad Unit IDs mới thông qua cấu hình an toàn (runtime `--dart-define` trong CI/CD build hoặc remote backend config), không lưu cứng trong git.
3. **Smoke Test Thực Tế:** Trước khi rollout diện rộng, thực hiện smoke test trên tối thiểu 1 thiết bị Android và 1 thiết bị iOS với bộ key mới cho đủ 4 format quảng cáo, kiểm tra luồng UMP consent và kiểm tra ngắt/kết nối mạng.
4. **Theo dõi Dashboard:** Giám sát dashboard AdMob & AppLovin trong giai đoạn rollout 5%–10% người dùng đầu tiên để xác nhận fill-rate và không có cảnh báo vi phạm chính sách.

*Sau khi điều kiện (1) và (2) được hoàn thành, SDK hoàn toàn đủ tiêu chuẩn chất lượng cao để đưa vào Production.*
