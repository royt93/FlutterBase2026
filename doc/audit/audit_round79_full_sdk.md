# Audit round 79 — Full SDK + example, pub.dev 3.7.1

- **Ngày:** 2026-11-08
- **Phạm vi:** `packages/ad_sdk/` và `packages/ad_sdk/example/`; Android + iOS; AdMob + AppLovin MAX; consent, lifecycle, offline/reconnect, trial/VIP, memory, policy và release status.
- **Bản phát hành hiện tại:** `applovin_admob_sdk` 3.7.1 đã publish trên pub.dev ngày 2026-11-08. Đây là bản docs-only; không thay đổi runtime/API. Bản runtime đối chiếu của audit vẫn là 3.7.0.
- **Archive SHA-256 của 3.7.0:** `31cd1a6f0e698f103431d4fe44d59de7be5921c74e1f39e1d5818bf7740d83a0`.
- **Dependency resolution độc lập:** Consumer fixture resolve `applovin_admob_sdk 3.7.0` đúng SHA ở trên và `google_mobile_ads 9.2.0`; fixture lockfile được tạo bằng Flutter 3.41.9. Đây là xác nhận archive/dependency resolution, không phải build trên CI floor Flutter 3.38.1. 3.7.1 không đổi dependency/runtime payload.

---

## 1. Kết luận

1. **SDK 3.7.0 đã phát hành; audit round 78 còn chứa release wording đã lỗi thời.** Round 78 vẫn hữu ích làm bằng chứng chi tiết cho Android + AdMob, nhưng các dòng “draft/chưa publish” không còn là trạng thái hiện tại. Xem mục 8.
2. **Không tìm thấy lỗi runtime mới đã tái hiện trong phạm vi source được kiểm tra.** Round 78 đã xác nhận hai fix của 3.7.0: banner async-size race và source compatibility cho `ConsentSimulationResult`. Hướng dẫn publish trong `CHANGELOG.md` còn dán nhãn draft, là lỗi tài liệu.
3. **Android + AdMob:** Có thể chạy closed pilot nhỏ, có rollback và giám sát, theo checklist round 78 mục 7. Không coi đây là xác nhận production toàn diện hoặc bảo đảm tuân thủ của từng publisher.
4. **Toàn bộ Android+iOS × AdMob+AppLovin:** Chưa đủ bằng chứng để khuyến nghị rollout production rộng. Thiếu iPhone thật và xác minh provider-native AppLovin trên thiết bị; CI hiện bỏ qua iOS ATT/UMP và chọn AdMob. Đây là khoảng trống QA, không phải lỗi runtime đã chứng minh.
5. **Không thể kết luận “không có memory leak” hoặc “mọi quốc gia đều tuân thủ”.** Memory evidence là snapshot/adapter giả; legal compliance còn phụ thuộc publisher, UMP configuration, disclosures, ad placement, app-ads.txt, consent UX và policy của nền tảng.

## 2. Bản phát hành và dependency

- Pub.dev API xác nhận 3.7.0 đã publish ngày 2026-11-08. Archive digest trùng consumer fixture lockfile.
- Published constraints: Dart `>=3.10.0 <4.0.0`, Flutter `>=3.38.1`, `google_mobile_ads >=9.2.0 <9.3.0`, `applovin_max ^4.6.4`, cùng các constraints trong `packages/ad_sdk/pubspec.yaml`.
- SDK giữ exact pins `wakelock_plus 1.4.0` và `wakelock_plus_platform_interface 1.3.0`; `shared_preferences_android` có lower bound nhưng không upper bound có chủ đích. Round 78 ghi rõ dry-run exit 65 với ba dependency warnings. Không xem warnings này là solver/build failure; không đổi pins trong audit này.
- CI dùng Flutter 3.38.1; local toolchain trước đó là Flutter 3.41.9. Không tuyên bố dependency warning đã được giải quyết bằng CI-floor verification.

## 3. Runtime và kiểm thử đã có bằng chứng

### Android + AdMob

Round 78 (`audit_round78_android_admob.md`) ghi chi tiết:

- Adaptive banner async-size race đã có post-await guards, recovery debt khi gate đóng, và late-error protection. Unit/widget regression cases cùng Pixel 7 Pro forced-race integration đều pass.
- `ConsentSimulationResult` giữ caller cũ 5 tham số; enum tùy chọn suy ra child từ cờ COPPA/TFUA. Consent tests và API golden pass.
- UMP EEA debug form, AdMob test ad cho banner/interstitial/rewarded/rewarded-interstitial/app-open, real Wi-Fi banner recovery, interruption/network-conditioning, và pinning/build checks đã được ghi lại với giới hạn từng phép thử.
- Full SDK suite trong lần xác nhận round 78: 2,852 pass; analyzer và local release-readiness gate pass.
- Ba integration test trên Pixel 7 Pro thật (Android 17 / API 37, 2026-11-08) đều pass khi chạy example với `--dart-define=AD_PROVIDER_ADMOB=true`: `android_interruption_test.dart`, `android_network_conditioning_test.dart`, `t212_memory_backpressure_test.dart`. Giới hạn test: interruption test gọi `WidgetsBinding.handleAppLifecycleStateChanged` để giả lập pause/resume, không đưa app background bằng thao tác người dùng; network test bật/tắt `AdManager.debugConnectivityChanged`, không ngắt/kết nối Wi-Fi hoặc mạng di động thật; T212 bơm 10k synthetic events và chạy 50 init/destroy cycles qua fake adapter, không đo heap/native memory. Kết quả pass chỉ áp dụng cho assertion của các harness này.
- Lượt đầu chạy interruption test thiếu AdMob define, chọn AppLovin placeholder IDs và bị watchdog; lượt đó đã dừng, không tính vào kết quả. Lượt đúng provider AdMob pass. UMP trên Pixel báo `notRequired`; test này không xác minh EEA consent form hay publisher UMP setup.
- Pixel UI smoke (ADB input có screenshot/log, không phải người dùng tự chạm màn hình): mở example, tap **Banner ad**, screenshot hiển thị hai Google test banners có nhãn “Quảng cáo thử nghiệm”. Sau khi đưa app nền bằng Home rồi relaunch, screenshot hiển thị Google Ads fullscreen test creative; activity đứng đầu là `com.google.android.gms.ads.AdActivity`. Một lần Back chưa đóng được creative; Back lần hai đưa app về `MainActivity`. Không chạm creative, CTA hoặc nút cài đặt. Log xác nhận `provider=admob`, lifecycle `paused → resumed`, và SDK gọi nhánh app-open khi resume; không thấy `FATAL EXCEPTION` trong log được rà. Đây là tương tác ADB nhìn thấy được với test creative trên example/Pixel, không phải host app production. Lượt launch ban đầu có VIP active nên banner bị skip; sau đó banner test hiển thị. Pixel status `notRequired`, UMP EEA form chưa xác minh.
- Pixel Android + AdMob test-ad rerun, hai phiên capture riêng (ADB UI actions/screenshots, 2026-11-08; Google test IDs; không click creative/CTA): Banner và MREC được load; log có `loadBanner ✅`, `loadMrec ✅` và MREC impressions. Native screenshot hiển thị hai test creatives, validator báo `0 implementation issues found`; isolated rerun log `rerun3_native_full_logcat.txt` ghi ba `preloadNative ✅` và hai impression callbacks. Kết luận giới hạn ở example test ads trên Pixel, không phải host production. Interstitial log `✅ shown` rồi `dismissed` sau nút X. Rewarded log thứ nhất ghi `✅ shown` → `🏆 type=coins amount=10` → `onEarnedReward: result=true` → `dismissed (earned=true)`; screenshot UI `Coins: 10`, `Last: earned`. Rewarded Interstitial log ghi `✅ shown` → `🏆 type=Coins amount=10` → `onDone: shown=true earned=true` → `dismissed (earned=true)`; screenshot UI `shown=true earned=true`. App Open log ghi resume gate passed, `showAppOpen ✅ shown` và `dismissed`; screenshot có fullscreen test creative. Không thấy `FATAL EXCEPTION` trong hai log được kiểm.
- Evidence bundle: `doc/audit/evidence/round79_pixel/rerun_full_logcat.txt` (1.86 MB; Interstitial + Rewarded + Rewarded Interstitial) và `rerun2_inline_appopen_full_logcat.txt` (580 KB; Banner/MREC/Native/App Open); screenshot tương ứng bắt đầu bằng `rerun_` / `rerun2_` trong cùng thư mục. Rerun isolate thêm `rerun3_native_full_logcat.txt` và `rerun3_mrec_logcat.txt` kèm screenshot `rerun3_native.png`, `rerun3_mrec.png`: Native có ba `preloadNative ✅` và hai impressions; MREC có ba `loadMrec ✅` và hai impressions. SHA-256 của hai log đầu nằm trong `rerun_log_sha256.txt`; không có `FATAL EXCEPTION` trong các log được kiểm. App Open log capture có thao tác validator Help ngoài ý muốn trước lần mở ad; screenshot/log phân biệt validator với App Open. Test một lượt từng format, trên example app chứ không host/publisher production; không đo memory/FPS; UMP EEA không được kiểm trên Pixel (xem phần TECNO bên dưới).
- **TECNO KJ7 (Android 14) — Wi‑Fi off/on và UMP EEA test thật (2026-11-09):**
  - **Mạng thật:** Tắt Wi‑Fi qua ADB khiến `Active default network: none` và `wifi_on: 0`; mở lại khôi phục `Active default network: 101` và `wifi_on: 1`. Logcat SDK ghi nhận sự kiện `network back online → refilling ad slots + banners`. Raw logcat (`wifi_consent_logcat.txt`, 11 MB) và `post_decline_logcat.txt` (3.8 MB) chỉ lưu cục bộ trên máy kiểm thử, không nằm trong repo; các giá trị `wifi_on`/default-network là output adb trong lượt chạy và không có artifact commit kèm theo.
  - **UMP EEA Form:** Build example với `--dart-define=UMP_EEA_DEBUG=true` và `--dart-define=UMP_TEST_ID=2814A47071F0761D9F546B5DD3AB9EA8` (hash trích từ logcat UMP lần đầu). Form native "Welcome to Publisher Test Ads" xuất hiện với 3 lựa chọn (`Consent`, `Do not consent`, `Manage options`; ảnh `doc/audit/evidence/round79_tecno/ump_launch.png`).
  - **Nhánh Consent:** Chọn `Consent`; UMP ghi `IABTCF_gdprApplies: 1` và chuỗi `IABTCF_TCString` có vendor consents. SDK ghi nhận `status=obtained, formShown=true, canRequestAds=true`. AdMob áp dụng `nonPersonalizedAds=false` (ảnh `ump_accept_result.png`, log `ump_accept_logcat.txt`).
  - **Nhánh Do not consent:** Xóa dữ liệu example (`pm clear`), form xuất hiện lại. Chọn `Do not consent`; UMP ghi `IABTCF_gdprApplies: 1` và `IABTCF_VendorConsents` toàn bộ bit 0. SDK ghi nhận `status=obtained, formShown=true, canRequestAds=true`. AdMob áp dụng `nonPersonalizedAds=true` (NPA - quảng cáo không cá nhân hóa). Chưa kiểm chứng ad load/show hoặc response cụ thể sau khi từ chối trong lượt này (ảnh `ump_decline_result.png`, log `ump_decline_logcat.txt`).
  - **Privacy Options (thay đổi consent):** Sau khi đã từ chối, mở lại form qua nút "Privacy Options" trong màn hình settings. Form không được đóng trong 180 giây; SDK ghi `privacy options form dismiss timed out after 180s`, rồi sau 15 phút ghi `releasing the ad block after 15m`. Khi form vẫn đang hiển thị, thao tác `Consent` được ghi muộn tại 15:31: UMP ghi lại `IABTCF_gdprApplies: 1` và `IABTCF_TCString`, gửi dismiss `CONSENT_SIGNAL_SUFFICIENT`; SDK ghi `privacy options form dismissed AFTER our timeout` và AdMob cập nhật `nonPersonalizedAds=false (hasUserConsent=true)`. Kết quả chứng minh callback muộn vẫn cập nhật trạng thái; không chứng minh luồng Privacy Options hoàn tất trong thời hạn SDK 180 giây hay gate không được mở tạm bởi timeout. Ảnh `tecno_privacy_options_form.png`, `tecno_privacy_options_after_consent.png`; raw log `tecno_privacy_options_logcat.txt` (8.7 MB) lưu cục bộ trên máy test, không nằm trong repo.
  - **Regression "đã trả lời thì không hỏi lại" (2026-11-10):** Chạy `integration_test/ump_eea_consent_test.dart` trên TECNO KJ7 với `UMP_EEA_DEBUG=true` và hash test-device nêu trên, không xóa dữ liệu app. Kết quả: `All tests passed`; log thể hiện `consent status: obtained`, `formShown=false`, `canRequestAds=true`. Test này gọi trực tiếp luồng UMP, không mở UI full app và không tự tương tác với form native; chỉ xác nhận trạng thái consent đã lưu không làm form hiện lại. Output terminal, không có artifact commit kèm theo.
  - **Bằng chứng lưu:** Thư mục riêng `doc/audit/evidence/round79_tecno/` gồm 4 ảnh PNG (ump_launch, ump_accept_result, ump_decline_result, privacy_settings_screen), 2 file logcat chính (ump_accept, ump_decline) và file băm SHA-256 `tecno_sha256.txt`. Giới hạn: Đây là kết quả trên thiết bị TECNO KJ7 với test geography EEA và test ad unit, không đại diện cho toàn bộ tài khoản AdMob hay mọi thị trường pháp lý.

- Defensive unit/widget checks also pass for selected suites: `r73_admob_show_failure_real_path_test.dart`, `r73_admob_show_failure_reloads_immediately_test.dart`, `qc22_rewarded_consent_withdrawn_midload_test.dart`, `r23_rewarded_interstitial_disclosure_test.dart`, `interstitial_rewarded_watchdog_test.dart`. These test simulated platform failures and gates, not real network/consent changes on Pixel.
- **T267 TECNO KJ7 exploratory rerun (Android 14, 2026-11-09):** Existing Macrobenchmark `loadingScroll` ran 3 iterations; XML reports 1 test, 0 failures; Macrobenchmark emitted `frameCount` 32/35/36 and `frameDurationCpuMs` P95 10.29ms. This is the loading placeholder scenario only, not a real ad or presentation-attribution result. `realAdMobScroll` exploratory runs on TECNO confirmed AdMob banner `ready=true loaded=true` and both `real_scroll_end`/`real_return_end` markers. The prior run (2026-11-09) and rerun (2026-11-10; all 3 iterations reached ready + scroll markers) both **failed** with `IllegalStateException: Observed no renderthread slices in trace`; no valid FrameTiming metric was produced. The rerun's log/XML and 3 Perfetto traces are saved under `doc/audit/evidence/round79_tecno/t267_exploratory_2026-11-10/`; prior artifacts under `t267_exploratory/`. TraceProcessor unavailable on host during rerun. These TECNO runs are exploratory only; T267 Pixel 7 Pro acceptance remains open, no FPS/jank pass claimed. Pixel trace history still has no verified app-layer presentation linkage. Ba `dumpsys meminfo` snapshot ở process khởi chạy khác nhau không chứng minh leak hoặc không leak.

### iOS + AppLovin

- Không có lỗi runtime cụ thể được xác minh trong independent source reviews.
- AppLovin adapter tests dùng `FakeAppLovinBridge`/captured Dart listeners (`test/applovin_adapter_test.dart`); không xác minh native callback delivery trên iOS.
- CI iOS integration chọn `AD_PROVIDER_ADMOB=true`, `SKIP_ATT=true`, `SKIP_UMP=true` (`.github/workflows/test.yml:343-351`). Do đó CI không xác minh iOS ATT, UMP form, hay MAX native lifecycle.
- AppLovin fullscreen test-ad không có control dismiss có accessibility cho automation; một số show/dismiss scenarios cần kiểm tra thủ công (`packages/ad_sdk/CLAUDE.md`, `packages/ad_sdk/README.md`).
- iOS IAB consent-store path được mô tả là chưa chạy trên thiết bị (`lib/src/core/iab_storage.dart:98-101`).
- MAX consent writes là fire-and-forget; SDK không thể xác nhận write thành công (`README.md` phần Known limitations). MAX không cung cấp ad freshness timestamp; các giới hạn này đã được tài liệu hóa, không phải lỗi mới.

### Lifecycle và memory

- Independent source review không tìm thấy defect đã xác minh trong slot transitions/watchdogs/dispose (`lib/src/state/ad_slot.dart:171-477`), AdMob keyed callback/dispose (`lib/src/adapters/admob_adapter.dart:527-677, 846-949`), AppLovin teardown/retry/route-background ownership (`lib/src/adapters/applovin_adapter.dart:958-1173, 2734-2953`), hoặc cleanup của banner/MREC/native widgets (`lib/src/widget/banner_ad_widget.dart:843-857`, `mrec_ad_widget.dart:481-495`, `native_ad_widget.dart:605-624`). Đây là static review; không chạy lại suite trong lượt rà soát này.
- **Giới hạn bằng chứng:** fake bridge/unit tests không chứng minh native ad object/platform view được giải phóng trên Android/iOS, hoặc native plugin callback có thể tới sau dispose. AppLovin không có API đóng fullscreen ad đang hiển thị khi teardown (`lib/src/adapters/applovin_adapter.dart:1060-1084`); đây là giới hạn nền tảng đã ghi nhận, không phải leak mới được tái hiện. Rewarded Interstitial không hỗ trợ trên MAX là khác biệt provider được chủ ý (`lib/src/state/ad_slot.dart:17-22`, `lib/src/adapters/applovin_adapter.dart:2161-2174`).
- Pixel memory/backpressure results chỉ là kiểm tra listener của adapter giả và ba cold-start PSS snapshots; không đo same-process native heap retention. Không tuyên bố zero native leaks.

### Offline, VIP và trial

- Ad request khi offline không có inventory mới để tải; SDK có reconnect/recovery logic. Round 78 real Wi-Fi reconnect test chỉ xác minh mounted AdMob banner recovery trên Pixel, không phải mọi carrier/device/provider.
- Signed VIP verification dùng Ed25519; activation deliberately requires network (`vip_manager.dart:1275-1299, 1358-1369`). Sau activation, entitlement chạy offline. Không có backend nên code không thể globally single-use.
- Trial mặc định 24 giờ ở release (`ad_config.dart:32-55, 417`). iOS dùng Keychain; Android anti-reinstall chỉ best-effort theo host Auto Backup; clear-data/reinstall có thể cấp lại trial/key. Đây là owner-approved, no-backend product limitation (`packages/ad_sdk/CLAUDE.md`, `_first_install_guard.dart`), không phải finding mới.
- Không thấy implementation IAP trong SDK; purchase flow là host-owned.

## 4. Example — audit findings and fixes

### Findings at audit start (all corrected in `9c5fc51`)

1. **P2 — Signed VIP demo mislabeled redemption as offline.** `example/lib/main.dart` originally called signed keys “offline/no network”, but `redeemSignedKey` requires connectivity (`lib/src/vip/vip_manager.dart:1358-1369`). Offline users would tap and get rejected. Device test confirms expected offline rejection (`example/integration_test/t220_owner_decisions_device_test.dart:107-121`); README documents it (`README.md:1075-1078`). This was example copy, not an SDK defect.
2. **P2 — No durable Privacy Options entry in demo home.** Before the change, `showPrivacyOptions()` appeared only on `VipRedeemScreen`; README requires a durable, always-visible entry (`README.md:2224-2252`). This was demo UX, not evidence of a broken consent API.
3. **P3 — Privacy policy action did not open a policy.** The previous callback only called `debugPrint` in `example/lib/main.dart`. This was incomplete demo behavior.

### Current state and verification

Commit `9c5fc51` fixes all three: signed-key label states “offline verification; internet required to redeem”; home now exposes **Privacy settings** with Privacy Options and privacy policy; policy URL opens using `url_launcher`. Example suite: 74 tests pass; analyzer clean. Integration test passes on Pixel 7 Pro (AdMob) and iOS simulator. On Pixel, adb tap opened Chrome and the supplied Notion page loaded, showing “Term & Privacy Policy & Disclaimer”. iOS simulator verified the privacy settings screen only, not the external browser; no iPhone claim.

Consent form UMP là native UI. `ump_eea_consent_test.dart` yêu cầu device hash và một lần trả lời thủ công; test không tự tap form và có thể skip nếu chưa cấu hình (`example/integration_test/ump_eea_consent_test.dart:14-31, 55-100`). Đây là giới hạn kiểm thử cần nêu khi đánh giá EEA QA.

## 5. Policy và pháp lý

SDK chuyển tiếp một số tín hiệu consent/age/restriction và có UMP flow, nhưng không thể tự chứng nhận tuân thủ mọi quốc gia hoặc chính sách AdMob/AppLovin. Publisher phải đảm bảo UMP message/configuration đúng app và thị trường, khai báo Data Safety/privacy policy, app-ads.txt, ad placement, age audience, Privacy Options UX, và theo dõi policy status. `canRequestAds=true` không tự chứng minh personalization được phép. AppLovin consent-write success không thể được xác nhận qua API hiện tại.

## 6. Production recommendation

- **Closed pilot Android + AdMob:** Có thể sau khi host checklist ở `audit_round78_android_admob.md:105-116` được tick, tester cohort nhỏ, telemetry/crash/fill/consent monitoring, và có rollback/tắt ad serving. Partner guide và README đã được cập nhật trong 3.7.1 docs-only; host vẫn cần xác nhận cấu hình riêng, không thể suy ra từ example/device tests.
- **Public rollout hoặc toàn nền tảng/providers:** Chưa khuyến nghị dựa trên evidence hiện có. Trước đó cần iPhone thật: ATT → UMP EEA (accept/decline/privacy options) → AdMob; xác minh IAB strings và ad gate. Cần thiết bị/credentials AppLovin để kiểm tra load/show/click/reward/dismiss, banner/MREC pause-refresh-destroy, Native load-refresh, và consent behavior. Không tuyên bố CI thay thế những phép thử này.
- Trial 24h release default phải được chủ sản phẩm/pháp lý/thương mại chấp thuận; nếu không, host cấu hình `FirstInstallVipGrace.disabled`. VIP promotion code không nên được bán như license có cam kết single-use/bảo vệ chống gian lận toàn cầu nếu không có backend.

### Tiêu chí go/no-go cho closed pilot Android + AdMob

Chỉ mở pilot khi host app đã tick đủ checklist ở `audit_round78_android_admob.md:105-116`. Đề xuất ngưỡng (chủ sản phẩm có thể chỉnh; đây không phải tiêu chuẩn của AdMob hay Google):

- **Quy mô:** cohort nhỏ, kéo dài vài ngày trước khi mở rộng; ghi lại bản SDK `3.7.1` và hash archive đã dùng.
- **Dừng ngay (no-go)** nếu gặp bất kỳ: crash/ANR tăng rõ so với bản không có ad; quảng cáo hiện khi VIP/trial đang hoạt động; ad request khi chưa có consent hợp lệ ở thị trường cần UMP; cảnh báo policy hoặc invalid-traffic từ AdMob; click nhầm do vị trí đặt quảng cáo.
- **Theo dõi:** tỷ lệ fill, lỗi tải, doanh thu/impression, reward chỉ cấp khi `earned=true`, hành vi khi mất/có lại mạng, rút consent qua Privacy Options.
- **Chưa kiểm chứng bằng audit này:** host app thực tế. Repo đang audit không chứa host app dùng SDK, nên cấu hình AdMob App ID/ad unit/UMP/app-ads.txt của app thật phải được owner xác nhận riêng.
- **Rollback:** có đường lùi về bản package trước hoặc tắt ad serving từ host/console; pub.dev không thể rút bản đã publish.

## 7. Guideline và partner readiness

### Android + AdMob findings

> **Trạng thái sau 3.7.1:** ba finding tài liệu ngay dưới đây là phát hiện tại thời điểm audit và đã được xử lý bởi commits `4cb4a30` và release `3.7.1`; giữ nguyên để bảo toàn lịch sử audit.

- **HIGH — Partner guide release/dependency baseline is stale.** `packages/ad_sdk/doc/AD_PROMPT_FLUTTER.MD:10-15, 179-180, 360-375, 4053` still shows SDK 3.6.8 and Google Mobile Ads `>=9.0.0 <9.1.0`; current package metadata is SDK 3.7.0 and GMA `>=9.2.0 <9.3.0` (`packages/ad_sdk/pubspec.yaml:6, 54-68`). Integration snippets may therefore pin the wrong version/API; 3.7.0 uses `RequestConfiguration.ageRestrictedTreatment` (`CHANGELOG.md:13`).
- **HIGH — README Android setup omits Kotlin Gradle Plugin prerequisite.** `README.md:283-331` instructs App ID, permissions and minSdk 24 but does not mention Kotlin Gradle Plugin >=2.3.0 or migration away from `kotlinOptions`. Current example sets Kotlin 2.3.0 and `compilerOptions` (`example/android/settings.gradle.kts:22-25`, `example/android/app/build.gradle.kts:97-99`). Host following README alone can fail Kotlin compilation with GMA 9.2.x.
- **MEDIUM — README example uses Google test ad units without code-level debug/release split.** `README.md:537-544` puts public test IDs directly in a generic `AdConfig` snippet. Although the prose says replace before publishing, a host that copies it unchanged will have ad requests blocked in release by `_applyTestIdFootgunGuard` (`lib/src/core/ad_manager.dart:3036-3053`). The partner guide has a safer debug/release split at `doc/AD_PROMPT_FLUTTER.MD:574-625`.
- **Android Runtime:** This documentation review did not verify a new Android/AdMob runtime defect. The release guard blocking Google test IDs is present in source; it prevents serving test inventory in release, but does not make the copied production configuration useful.

### VIP/trial and partner pilot boundary

- **Accepted no-backend limitations:** signed promo keys are not globally single-use; Android reinstall/clear-data protection is best-effort; offline activation is deliberately refused; wall-clock checks cannot provide trusted server time. See `packages/ad_sdk/CLAUDE.md`, `README.md:60-76, 1067-1089`, `lib/src/vip/vip_manager.dart`, and `_first_install_guard.dart`. Do not market promotions as paid, single-use licenses. The 24h release trial is on by default in SDK config and partner guide says disable unless product/privacy/commercial owners approve.
- **Owner decision recorded (2026-11-08, after round-79 discussion):** the two Android VIP/trial edge cases below are accepted. An explicit entitlement erase may reset the Android first-install trial, and VIP promo codes remain promotions: a restored backup may retain the redeemed-key marker while the secure-storage grant is gone. No SDK, backup-policy, or documentation behavior change is requested from these two findings. Future audits should classify them as owner-accepted unless the product starts selling VIP as paid, restorable entitlement or the erase flow is exposed in a way that makes repeated trials commercially unacceptable.
- **MINOR — Android trial can be farmed via SDK entitlement erase, without reinstall.** `AdManager.clearSdkData(scope: allIncludingEntitlements, confirmedEntitlementErasure: true)` clears `_keyFirstInstallApplied` (`lib/src/core/ad_manager.dart:1659-1663`; `lib/src/utils/ad_preferences.dart:777-810`). The iOS Keychain marker is deliberately preserved, but `FirstInstallGuard` has no Android persistent marker (`ad_manager.dart:1691-1707`; `_first_install_guard.dart:147-155, 192-196`). Next `initialize()` therefore grants another 24h trial; repeat the explicit erase + initialize to repeat. This goes beyond the documented reinstall/clear-data limitation because no reinstall is needed. This may be intended as full entitlement erasure; however iOS specifically preserves its marker to prevent the same trial-renewal path, so platform behavior is asymmetric. Existing tests cover fresh grant and entitlement erase separately, not erase → reinitialize → regrant. Host mitigations: set `firstInstallVipGrace: FirstInstallVipGrace.disabled` unless approved; don't expose entitlement erasure as a routine user action if repeated grace is unacceptable. Confirm product intent before changing SDK behavior.
- **MEDIUM — Restored Android preferences may retain “redeemed” marker while losing the VIP grant.** Backup XML explicitly includes only `FlutterSharedPreferences.xml` (`example/android/app/src/main/res/xml/full_backup_content.xml`, `data_extraction_rules.xml`). Redeemed VIP key IDs are stored in SharedPreferences (`lib/src/utils/ad_preferences.dart:442-451`), but VIP entry data is stored via `flutter_secure_storage` (`lib/src/vip/_vip_entries_store.dart:67-80`) and secure-storage data is excluded from backup by the explicit include rules. After device transfer/reinstall restoring SharedPreferences but not device-bound secure storage, the user has no active VIP entry while `redeemSignedKey` rejects the same key as already used (`lib/src/vip/vip_manager.dart:1457-1461`). This is a code/config consequence; no actual device restore was run. Existing backup test checks XML coverage only, not entitlement/ledger consistency after restore. Before relying on VIP for legitimate grants, either exclude redemption ledger from backup (weakens replay guard), define recovery/support behavior, or use a server-backed entitlement. Confirm policy trade-off; do not silently change backup scope.
- **Closed pilot cannot run from this SDK-only repository.** The consuming host app is not present here, so its manifest, AdMob App ID/ad units, UMP console setup, app-ads.txt, placement, release signing/R8 and rollback controls are not verified. No production ad units were used. Host repo/path and publisher-approved configuration are required before pilot execution.
- When host is available, first verify Android Kotlin Gradle Plugin >=2.3.0, `minSdk >=24`, app-specific AdMob `APPLICATION_ID`, correct platform ad units, UMP message and Privacy Options entry. Start a small closed cohort with test IDs, then switch to publisher-approved units only in the approved release config. Keep safety gates enabled; monitor crash/ANR, consent withdrawal, requests/fill, rewards, VIP suppression and offline/reconnect; have rollback and remote ad-off ready. Treat cohort/monitoring time as product-selected, not a Google policy standard.

### Remaining non-Android work (out of current focus)

- T256: iPhone device ATT + UMP + AdMob.
- R76: AppLovin native refresh/device QA with key, units and creative.
- T267: Flutter SurfaceView frame-presentation attribution.
- T267: Flutter SurfaceView frame-presentation attribution remains open; Pixel acceptance has not been achieved.
- Recheck CI workflow/billing before relying on CI for future release validation.

## 8. Round 78 correction

`audit_round78_android_admob.md` là snapshot lịch sử 2026-11-07, khi 3.7.0 chưa publish. Các câu tại dòng 17, 109, 120-121 mô tả đúng trạng thái lúc đó nhưng đã lỗi thời sau publish ngày 2026-11-08. Không xóa/sửa lịch sử trong file đó; dùng báo cáo round 79 này làm trạng thái hiện tại. Bản 3.6.8 trên pub.dev không chứa các thay đổi 3.7.0; consumer nên resolve bản hosted 3.7.0, archive SHA nêu trên.

## Sources

- https://pub.dev/packages/applovin_admob_sdk
- https://pub.dev/api/packages/applovin_admob_sdk
- https://developers.google.com/admob/flutter/privacy
- https://perfetto.dev/docs/data-sources/frametimeline
