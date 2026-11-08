# Audit round 79 — Full SDK + example, pub.dev 3.7.0

- **Ngày:** 2026-11-08
- **Phạm vi:** `packages/ad_sdk/` và `packages/ad_sdk/example/`; Android + iOS; AdMob + AppLovin MAX; consent, lifecycle, offline/reconnect, trial/VIP, memory, policy và release status.
- **Bản phát hành đối chiếu:** `applovin_admob_sdk` 3.7.0 trên pub.dev; published `2026-11-08T06:52:35.860011Z`.
- **Archive SHA-256:** `31cd1a6f0e698f103431d4fe44d59de7be5921c74e1f39e1d5818bf7740d83a0`.
- **Dependency resolution độc lập:** Consumer fixture resolve `applovin_admob_sdk 3.7.0` đúng SHA ở trên và `google_mobile_ads 9.2.0`; fixture lockfile được tạo bằng Flutter 3.41.9. Đây là xác nhận archive/dependency resolution, không phải build trên CI floor Flutter 3.38.1.

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
- `FrameTiming.totalSpan` không phải physical presentation/fps; T267 vẫn chưa chứng minh 60fps. Ba `dumpsys meminfo` snapshot ở process khởi chạy khác nhau không chứng minh leak hoặc không leak.

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

## 4. Example — verified documentation/UX issues

1. **P2 — Signed VIP demo gọi redemption là offline, nhưng offline redemption bị từ chối.** `example/lib/main.dart:4137-4144, 4364-4374` gọi signed keys “offline/no network”; `redeemSignedKey` đòi connectivity (`lib/src/vip/vip_manager.dart:1358-1369`). Device offline nên người thử bấm key nhưng nhận lỗi. Regression coverage xác nhận hành vi từ chối ở `example/integration_test/t220_owner_decisions_device_test.dart:107-121`; README giải thích đúng ở `README.md:1075-1078`. **Phân loại:** sai nhãn trong example, không phải lỗi SDK. Nên nói “offline signature verification; internet required to redeem”.
2. **P2 — Example không có durable/always-visible Privacy Options entry.** Home menu có consent demo, nhưng `AdManager().showPrivacyOptions()` chỉ được nối vào `VipRedeemScreen` tại `example/lib/main.dart:623-637`; không thấy entry cố định ở Settings/home. README yêu cầu entry lâu dài, luôn dễ tìm cho người dùng tại `README.md:2224-2252`. **Phân loại:** thiếu sót UX của demo; không chứng minh consent API hỏng. Host app vẫn phải tự cung cấp entry.
3. **P3 — Privacy policy action trong VIP demo không mở policy.** Callback chỉ `debugPrint` tại `example/lib/main.dart:631-635`. Người dùng thử demo không thể mở policy từ nút đó. **Phân loại:** demo UX chưa hoàn chỉnh, không phải SDK runtime defect.

Consent form UMP là native UI. `ump_eea_consent_test.dart` yêu cầu device hash và một lần trả lời thủ công; test không tự tap form và có thể skip nếu chưa cấu hình (`example/integration_test/ump_eea_consent_test.dart:14-31, 55-100`). Đây là giới hạn kiểm thử cần nêu khi đánh giá EEA QA.

## 5. Policy và pháp lý

SDK chuyển tiếp một số tín hiệu consent/age/restriction và có UMP flow, nhưng không thể tự chứng nhận tuân thủ mọi quốc gia hoặc chính sách AdMob/AppLovin. Publisher phải đảm bảo UMP message/configuration đúng app và thị trường, khai báo Data Safety/privacy policy, app-ads.txt, ad placement, age audience, Privacy Options UX, và theo dõi policy status. `canRequestAds=true` không tự chứng minh personalization được phép. AppLovin consent-write success không thể được xác nhận qua API hiện tại.

## 6. Production recommendation

- **Closed pilot Android + AdMob:** Có thể, với host checklist ở `audit_round78_android_admob.md:105-116`, tester cohort nhỏ, real AdMob account/test configuration được rà soát, telemetry/crash/fill/consent monitoring, và khả năng rollback/tắt ad serving.
- **Public rollout hoặc toàn nền tảng/providers:** Chưa khuyến nghị dựa trên evidence hiện có. Trước đó cần iPhone thật: ATT → UMP EEA (accept/decline/privacy options) → AdMob; xác minh IAB strings và ad gate. Cần thiết bị/credentials AppLovin để kiểm tra load/show/click/reward/dismiss, banner/MREC pause-refresh-destroy, Native load-refresh, và consent behavior. Không tuyên bố CI thay thế những phép thử này.
- Trial 24h release default phải được chủ sản phẩm/pháp lý/thương mại chấp thuận; nếu không, host cấu hình `FirstInstallVipGrace.disabled`. VIP promotion code không nên được bán như license có cam kết single-use/bảo vệ chống gian lận toàn cầu nếu không có backend.

## 7. Việc tiếp theo

- Sửa `CHANGELOG.md` release heading/QA wording để phản ánh 3.7.0 đã publish.
- Sửa nhãn VIP trong example, thêm Privacy Options entry cố định, và quyết định policy URL thực hay ẩn action trong demo.
- T256: iPhone thật, ATT + UMP + AdMob.
- R76: AppLovin native refresh/device QA với key, units, creative hợp lệ.
- T267: attribution Flutter SurfaceView frame presentation.
- Recheck CI workflow/billing trước khi dựa vào CI xanh cho release tương lai.

## 8. Round 78 correction

`audit_round78_android_admob.md` là snapshot lịch sử 2026-11-07, khi 3.7.0 chưa publish. Các câu tại dòng 17, 109, 120-121 mô tả đúng trạng thái lúc đó nhưng đã lỗi thời sau publish ngày 2026-11-08. Không xóa/sửa lịch sử trong file đó; dùng báo cáo round 79 này làm trạng thái hiện tại. Bản 3.6.8 trên pub.dev không chứa các thay đổi 3.7.0; consumer nên resolve bản hosted 3.7.0, archive SHA nêu trên.

## Sources

- https://pub.dev/packages/applovin_admob_sdk
- https://pub.dev/api/packages/applovin_admob_sdk
- https://developers.google.com/admob/flutter/privacy
- https://perfetto.dev/docs/data-sources/frametimeline
