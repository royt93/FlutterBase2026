# Audit round 78 — Android + AdMob & pub.dev review

- **Ngày:** 2026-11-07 (implementation và verification bổ sung trong cùng audit)
- **Gói:** `applovin_admob_sdk` 3.6.8 (pub.dev archive) vs local `main` ban đầu `f8d6ddd`
- **Tập trung:** Android + Google AdMob, UMP consent / policy, offline VIP & first-install trial security.
- **Archive:** `applovin_admob_sdk-3.6.8.tar.gz`; SHA-256 `3e354e40da0156ba94c0dc9d9a4b6f175e316b6c4e29f2cad0bdc9c57231e2c1` (khớp pub.dev API).

---

## 1. Kết luận tóm tắt

1. **Release 3.6.8 và local hiện tại không giống nhau.** Pub.dev archive vẫn ghim `google_mobile_ads >=9.0.0 <9.1.0` và dùng API AdMob cũ `tagForChildDirectedTreatment` / `tagForUnderAgeOfConsent`. Local đã chuyển sang `google_mobile_ads >=9.2.0 <9.3.0`, `RequestConfiguration.ageRestrictedTreatment`, có UMP session-epoch guard và AppLovin Native refresh remount fix. Bằng chứng build/test local không được xem là bằng chứng rằng 3.6.8 trên pub.dev có các sửa đổi này.
2. **Hai vấn đề local đã được sửa trong vòng audit này:**
   - Banner AdMob vẫn có thể gửi request sau khi adaptive-size lookup hoàn tất dù watchdog đã timeout hoặc `canReload()` đã đóng giữa lúc chờ.
   - `ConsentSimulationResult` thêm tham số enum `required` làm hỏng source compatibility của các caller cũ; đã chuyển sang optional và suy ra từ cờ legacy khi bị bỏ qua.
3. **Đánh giá:** Local Android + AdMob có thể cân nhắc cho pilot có kiểm soát sau khi host app xác nhận cấu hình và nguồn SDK. Audit này **không** chứng minh mọi thị trường/pháp nhân tuân thủ, không thay publisher responsibility đối với UMP configuration, disclosures, app-ads.txt và ad placement; cũng không chứng minh native memory không rò rỉ.
4. **Không publish trong audit.** T256 vẫn chờ iPhone thật; T267 frame-presentation attribution vẫn chưa đạt; R76 AppLovin Native device QA chưa có key/creative hợp lệ.

## 2. Đối chiếu bản phát hành với local

| Mục | Pub.dev 3.6.8 | Local khi audit | Nhận định |
|---|---|---|---|
| Google Mobile Ads | `>=9.0.0 <9.1.0` | `>=9.2.0 <9.3.0` | Local có API tuổi mới; dependency delta có pinning/build evidence riêng. |
| Age treatment | Legacy COPPA/TFUA pair | `ageRestrictedTreatment` enum | Constructor mô phỏng public đã được khôi phục source-compatible trong thay đổi local chưa phát hành. |
| AppLovin Native refresh | Giữ nguyên widget state khi refresh | generation-key remount | Unit/widget test chứng minh thay `State`; chưa chứng minh native fill trên thiết bị, R76 vẫn mở. |
| UMP async session | Không có local epoch guard bổ sung | Session epoch ngăn kết quả cũ ghi vào session mới | Test suite cover; không thay thế consent matrix trên từng vùng pháp lý. |

## 3. Android + AdMob: consent, policy signals, lifecycle

- Mapping kiểm tra trong test/local implementation: COPPA **hoặc** TFUA -> `AgeRestrictedTreatment.child`; không có cờ -> `unspecified`. Regression mapping bao phủ bốn tổ hợp COPPA × TFUA; integration kiểm tra cấu hình gửi xuống Android.
- `testDeviceIds` được giữ khi consent re-apply; fixed QA fleet nằm trong release builds theo quyết định owner, không phải traffic production.
- UMP được chạy trước adapter initialization trong config bật auto UMP. `canRequestAds` là quyền được request ads, không tự nó chứng minh personalized ads được phép. Personalization/RDP flags vẫn là input riêng. EEA debug run trên Pixel hiển thị form và sau khi bấm Consent trả `status=obtained`, `canRequestAds=true`; chỉ chứng minh lượt debug trên thiết bị này.
- `_presentBlockedReason` kiểm tra consent, teardown, foreground lifecycle và mutex fullscreen. `_discardIfConsentStale` loại ad fullscreen nạp dưới consent đã bị thu hẹp. Freshness guard AdMob: App Open 4h, interstitial/rewarded 1h.
- AppLovin MAX 4.x không có API COPPA tương đương; local fail-closed init gate chỉ áp dụng khi child status đã biết lúc initialize. Không kết luận AppLovin COPPA parity.

## 4. Finding đã tái hiện và sửa trong local

### R78-01 — Banner async-size lookup gửi request sau timeout hoặc gate đóng

- **Vị trí ban đầu:** `lib/src/adapters/admob_adapter.dart`, `loadBannerIfNeeded`, await adaptive size và continuation trước `BannerAd(..)..load()` (khoảng dòng 2157–2178 trước fix).
- **Tái hiện:** MethodChannel mock giữ pending `AdSize#getAnchoredAdaptiveBannerAdSize`; sau đó hoặc kích hoạt watchdog, hoặc chuyển `canReload()` từ true sang false; khi trả adaptive size, code cũ vẫn gửi `loadBannerAd`. Positive-control với gate mở cũng gửi đúng request.
- **Sửa local:** Sau await, kiểm tra registry slot identity và `loadTimedOut`; sau đó recheck `canReload()`. Nếu gate vừa đóng, đưa slot sang cooldown và đánh dấu `needsRecovery` để reconnect/resume recovery có thể thử lại. Catch của lookup bỏ qua lỗi cũ nếu request timeout hoặc slot đã bị dispose.
- **Coverage:** `test/admob_widget_load_watchdog_test.dart` có timeout, gate-close, gate-reopen recovery, late lookup error và widget disposal cases. `example/integration_test/r78_banner_async_guard_test.dart` trên Pixel đã quan sát log timeout/gate abort và không phát sinh request native trước recovery; sau mở gate hai slot recovery được request lại.
- **Giới hạn:** Test Pixel giữ lời đáp size để điều khiển timing; đây là forced race, không phải xác suất race tự nhiên. Không đổi `canReload` background policy. MREC/Native không có await adaptive-size pre-creation tương tự.

### R78-02 — `ConsentSimulationResult` constructor public không tương thích source

- **Vị trí:** `lib/src/core/ad_consent.dart`, constructor `ConsentSimulationResult`.
- **Tái hiện:** lời gọi legacy 5 tham số bị analyzer từ chối vì `admobAgeRestrictedTreatment` mới bị khai báo required.
- **Sửa local:** enum parameter mới thành optional nullable; nếu bị bỏ qua thì suy ra `child` khi COPPA/TFUA legacy flag là `yes`, còn lại `unspecified`; explicit enum được giữ nguyên.
- **Coverage:** Test legacy 5-argument const construction (COPPA, TFUA, adult), explicit override và API golden mới. `test/ad_consent_test.dart` 15/15 pass; `api_golden_test.dart` pass.
- **SemVer:** Giữ field cũ `@Deprecated` và constructor call cũ compile được; không xóa field public.

## 5. Bảo mật VIP offline & first-install trial

- AVP2 dùng Ed25519; public key client-side không đủ để mint chữ ký mới. Payload chứa duration, key ID, expiry và bundle binding; CRL có domain prefix riêng. AVP1 bị từ chối mặc định, chỉ bật lại qua opt-in legacy.
- Activation signed key yêu cầu network để kiểm tra revocation; sau khi redeem, entitlement lưu cục bộ và chạy offline. Đây là thiết kế promotion code, không phải giấy phép globally single-use; không có backend để đảm bảo single-use xuyên thiết bị.
- Thời gian dùng wall-clock, monotonic `Stopwatch` anchor và high-water mark; rollback trong session có guard. Giới hạn đã ghi trong source: forward clock trước lần chạy đầu không thể phân biệt “giờ đúng”; restart/background resync giới hạn cửa sổ phát hiện. Không tuyên bố clock rollback chống được mọi tình huống.
- Android first-install grace dựa Android Auto Backup; nếu backup tắt/xoá dữ liệu thì trial có thể cấp lại sau reinstall. Đây là giới hạn owner-accepted, không phải finding mới.
- Không thấy implementation IAP trong package. IAP là host-owned; package chỉ cung cấp hook grant VIP cho host.

## 6. Verification matrix và giới hạn

| Tầng | Kết quả | Ý nghĩa và giới hạn |
|---|---|---|
| Targeted banner watchdog/race tests | Pass, 12 tests | Bao phủ mocked async lookup, timeout, gate close/reopen, dispose, late error/success; không mô phỏng timing native bất định. |
| Consent tests | Pass, 15 tests | Bao gồm legacy constructor + enum mapping. |
| API golden | Pass | Chữ ký public mới có optional enum parameter. |
| Banner widget tests | Pass | Flutter widget lifecycle; adapter channel race nằm ở unit/channel tests riêng. |
| Full SDK suite | 2,852 passed (final local run, concurrency 4) | Analyzer no issues; release-readiness gate passed in same command. Không phải toàn bộ tổ hợp thiết bị/provider/pháp nhân. |
| `flutter analyze lib/ test/ example/lib/` | No issues | Static analysis. |
| `./tool/release_readiness_gate.sh all` | Pass | Local release gate. |
| Pixel interruption integration | 1/1 pass | Flutter lifecycle simulation; không phải Android force-stop/OS reclaim. |
| Pixel network-conditioning integration | 1/1 pass | SDK connectivity seam; không thay thế radio/carrier chaos. |
| `r73_android_admob_fixes_test.dart` Pixel, ordinary integration run | 9 passed, 1 skipped | Case real Wi-Fi cut là opt-in và bị skip trong lượt này. |
| `r73_android_admob_fixes_test.dart` real-network banner recovery | 10/10 pass (earlier Pixel run) | Wi-Fi thực bị tắt/bật; mounted banner gặp native error, watcher reconnect, request lại và slot ready không cần app resume. |
| `r78_banner_async_guard_test.dart` Pixel | 1/1 pass (rerun after final full suite) | Channel handler giữ lời đáp adaptive-size để điều khiển timeout/gate; verifies no native request until recovery. Đây là forced race, không phải timing tự nhiên hoặc xác suất race ngoài thực tế. |
| `t212_memory_backpressure_test.dart` Pixel | 1/1 pass | 10k event delivery và 50 `initialize()`/`destroy()` cycles trên `_LeakDetectableAdapter`; kiểm tra listener của adapter giả, **không** native heap leak của Google Mobile Ads. |
| `./tool/check_pinning_wall.sh --with-builds` | Pass | `AppLovinSDK 13.6.3`; Android debug + iOS simulator build. Đây là build/pinning, không kiểm chứng mediation ad fill. |
| `dart pub publish --dry-run` | Exit 65; 3 dependency warnings | Open `shared_preferences_android` range and exact `wakelock_plus`/platform-interface pins are documented pinning-wall choices. Do not loosen pins casually; no upload was attempted. |
| Pixel ad-format smoke, AdMob test IDs | Banner, interstitial, rewarded, rewarded-interstitial, app-open observed working; test reward UI showed +10 coins | Một máy, một debug build; không phải production inventory, không cover mọi dismiss/no-fill/reinstall/market. |
| Pixel profiling & memory (Profile APK, 3 cold starts) | PSS ready: 368,582 / 362,556 / 365,382 KiB (360.0 / 354.1 / 356.8 MiB); sau report: 353,633 / 348,172 / 352,321 KiB (345.3 / 339.8 / 343.9 MiB) | Đo qua `dumpsys meminfo`; ba process khác nhau, không phải chuỗi mount/dispose trong cùng process, không có heap-retention analysis hoặc baseline trước fix. Không đủ kết luận không leak hay cải thiện memory. |
| Frame/jank | Not passed / unresolved | Pixel Android 17 Perfetto/SurfaceView traces chưa cung cấp layer attribution; `FrameTimingMetric` không chứng minh Flutter frame presentation. T267 giữ mở; không báo 60fps pass. |
| iOS device / AppLovin Native device QA | Not run | iPhone thật và AppLovin QA credentials/creative chưa sẵn sàng. T256/R76 giữ mở. |

### Profile engine timing — ba lượt Pixel, chỉ cửa sổ cuộn 2 giây

Các lượt đều có banner `ready=true`, real-ad result loaded/ready và terminal `T257_LIMIT`. Lọc `T257_FRAME` theo `[phase marker, phase marker + 2s)` để loại phần idle trong summary 3 giây của harness. Đơn vị timing: ms; percentile dùng nearest-rank theo index làm tròn của harness.

| Lượt | DOWN n | DOWN p95 / p99 / max `totalSpan` ms | DOWN >16.67 ms | RETURN n | RETURN p95 / p99 / max `totalSpan` ms | RETURN >16.67 ms |
|---|---:|---|---:|---:|---|---:|
| 1 | 230 | 6.179 / 9.393 / 32.400 | 2 | 240 | 5.057 / 6.687 / 7.459 | 0 |
| 2 | 231 | 7.906 / 10.884 / 64.990 | 1 | 239 | 5.652 / 7.203 / 9.290 | 0 |
| 3 | 232 | 5.879 / 8.352 / 46.923 | 2 | 239 | 5.977 / 7.516 / 11.476 | 0 |

Đây là Flutter engine `FrameTiming.totalSpan`, không phải physical fps, số frame present hay dropped-buffer count. Có outlier ở cả ba lượt DOWN; không chấm T257/T267 pass. Raw evidence local: `/tmp/admob-audit78.ZPPksh/pixel_profile_run{1,2,3}.log` và `.memory.txt`; file tạm không được đảm bảo tồn tại lâu dài. Lần capture thứ ba ban đầu không lấy được PID lúc startup; lượt thay thế đã chờ PID và hoàn tất, không xem lần lỗi capture là crash đã xác minh.

### Nguồn đối chiếu

- https://pub.dev/packages/applovin_admob_sdk
- https://pub.dev/api/packages/applovin_admob_sdk
- https://developers.google.com/admob/flutter/privacy
- https://perfetto.dev/docs/data-sources/frametimeline

## 7. Checklist Android + AdMob closed pilot (app host)

Trước khi cài closed-test APK/AAB từ host app, xác nhận:

- Dùng artifact/source đã được release owner phê duyệt. Fixes nằm trong `25e3b42`, release metadata draft `3.7.0` trong `55292fd`; pub.dev vẫn là 3.6.8. Không giả định consumer tải 3.6.8 đã nhận các fixes đó; không trỏ production app vào git dependency chưa qua quy trình release.
- Host Android đáp ứng Kotlin Gradle Plugin 2.3.0+, `minSdk >= 24`, Android manifest AdMob `APPLICATION_ID`, quyền/backup XML theo guide; release R8 rules và signing phải do host xác minh.
- AdMob App ID, Android ad-unit IDs, app-ads.txt và UMP messages/domain đều thuộc đúng app/publisher; tuyệt đối không đưa test IDs vào release build.
- UMP là consent owner duy nhất; `requestConsentInfoUpdate()` chạy mỗi app launch. Review riêng `canRequestAds`, personalization, COPPA/TFUA và CCPA/RDP; cung cấp Privacy Options entry point khi UMP yêu cầu. Consent/legal review theo thị trường do publisher chịu trách nhiệm.
- Giữ safety gate mặc định. Không dùng `bypassSafety` ngoài App Open splash được tài liệu hoá; không đặt interstitial gần thao tác thường xuyên. Reward chỉ cấp khi callback báo `earned=true`.
- Giai đoạn closed test: crash/ANR, AdMob request/error/fill/impression/reward, test consent withdrawal, foreground/background và Wi-Fi loss/reconnect. Bắt đầu với tester cohort nhỏ; có cách rollback package/version và tắt ad serving từ host/console.
- Thu thập telemetry tối thiểu cần thiết, không log GAID/ad-unit hoặc raw consent strings ngoài quy trình QA được duyệt. Không đánh giá native memory là “không leak” dựa trên ba `dumpsys meminfo` snapshot.
- Sau pilot, review Play policy status, crash/fill data và khiếu nại trước khi mở rộng. iOS/AppLovin không thuộc bằng chứng pilot Android + AdMob này.

## 8. Phán quyết & việc còn lại

- **Android + AdMob local:** Đủ cơ sở để cân nhắc closed pilot với fixes trong commit `25e3b42`; release metadata draft `3.7.0` nằm trong commit `55292fd` trên `origin/main`, chưa publish. Trước khi pilot, host app xác nhận cấu hình ở mục 7; theo dõi crash, fill, consent, ad serving và policy. Đây không phải duyệt production toàn diện.
- **Không phát hành/publish bởi audit này.** Tại thời điểm audit, pub.dev vẫn là 3.6.8 và chưa có GMA 9.2.0/R78 fixes. Draft local `3.7.0` (`55292fd`) chưa publish. `dart pub publish --dry-run` trả exit 65 với 3 warning: upper bound mở của `shared_preferences_android` và exact pins `wakelock_plus`/`wakelock_plus_platform_interface` đã được ghi nhận trong pinning-wall constraints; chưa upload. Public publish cần owner quyết định rõ và QA iOS/AppLovin còn deferred.
- **T256:** Chờ iPhone thật để ATT + UMP EEA + AdMob test ad smoke.
- **R76:** Chờ AppLovin QA key/units và thiết bị để kiểm chứng native Native refresh.
- **T267:** Giữ mở; cần nguồn frame presentation có attribution cho Flutter SurfaceView trên Pixel.
- **T87:** Bị chặn do GitHub Actions billing; không nằm trong phạm vi Android + AdMob runtime audit.
