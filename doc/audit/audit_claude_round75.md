# Audit toàn diện SDK và example — Round 75

Ngày kiểm tra: 2026-10-10  
Package: `applovin_admob_sdk` **3.4.5**  
Baseline git: `02d0422a48e4d7c86785b76a226b35c6d163577a` (`main`)  
Phạm vi: SDK + example; Android/iOS; AdMob/AppLovin; consent, privacy, VIP/trial, quảng cáo/lifecycle, online/offline, policy và production readiness.

## Kết luận

**CHƯA DUYỆT ĐƯA VÀO PRODUCTION.** Đây là kết luận theo bằng chứng kiểm tra được hôm nay; không phải chứng nhận SDK hỏng toàn bộ. Có hai lỗ hổng thật ở consent và các khoảng trống đáng kể về iOS, AppLovin, memory, pháp lý/policy và full suite. Cần xử lý finding consent trước khi phát hành ứng dụng dùng các API liên quan.

Không đổi mã SDK, dependency, version, commit hay publish trong audit này. Không mở lại các lựa chọn sản phẩm đã được chủ dự án chấp thuận: VIP key activation cần mạng; VIP đã cấp hoạt động offline; key promotion có thể dùng trên nhiều thiết bị; Android trial chống cài lại chỉ best-effort; COPPA trên AppLovin là init-time; QA hashes vẫn bật; AVP1/AVP2 cùng hỗ trợ.

## Evidence thực hiện trong phiên

| Kiểm tra | Kết quả | Giới hạn |
|---|---|---|
| Pub.dev metadata | Latest `3.4.5`, phát hành `2026-10-09` | Metadata không tự chứng minh archive trùng source |
| Archive xác thực | SHA-256 archive bằng API pub.dev: `01a93f79b03a8ea50782a15fc050c6ac51ab919e3aef7b929eee71c35e1c2799`; 90 file thuộc `lib/`, `example/lib/`, `pubspec.yaml` đều trùng working tree | So sánh source/package metadata subset, không so toàn bộ archive |
| Analyze | `flutter analyze lib/ test/ example/lib/`: **No issues found** | Không xác minh native runtime hay policy |
| Release readiness | `./tool/release_readiness_gate.sh all`: **all passed** | Gate tĩnh/release hygiene, không là release approval |
| Pinning wall | `./tool/check_pinning_wall.sh`: exit 0 | Log hiển thị package tải và dependency notice; không chạy `--with-builds` |
| SDK full suite | **BLOCKED** — Dart MCP runner chuyển option không tồn tại `--pause-after-load` trước test discovery | Không có test nào chạy; pass/fail count không biết |
| Targeted consent tests | **61 PASS**, `All tests passed!` | Chỉ 6 file: provenance journal, consent manager, ad consent, config regression, COPPA race, COPPA init |
| VIP tests | **70 PASS**, exit 0 | 5 file: revocation, signed-key v2, dispose-mid-redeem, manager robustness, entries store. Không mô phỏng dispose trong durable-ledger lookup |
| Example widget tests | **67 PASS**, exit 0 | Không kiểm tra provider native thật |
| Android build | Example debug APK build thành công với `AD_PROVIDER_ADMOB=true`, `SKIP_ATT=true` | Flutter 3.41.9; test build, không phải release signing |
| Android online, TECNO KJ7 | UMP trả `notRequired`; AdMob initialize thành công; App Open, interstitial, rewarded-interstitial, rewarded báo load thành công; app tới home screen | Một device, AdMob test IDs; không xác minh tất cả ad surfaces/lifecycle |
| Android offline startup, TECNO KJ7 | UMP lỗi network; giữ consent đã lưu, init xong, app tới home screen, không thấy fatal exception | Chưa test offline ad-show, mất mạng mid-load hoặc reconnect native |
| Android integration `r73_android_admob_fixes_test.dart` | **7 PASS, 1 SKIP** (`RUN_REAL_NETWORK_TEST` opt-in), exit 0 | Native device TECNO KJ7; phần offline/reconnect skip; các ca không kiểm toàn bộ lifecycle |
| iOS simulator | Build/run **BLOCKED** bởi Flutter/Xcode: temporary `flutter_test_listener/.../listener.dart` bị thiếu; `kernel_snapshot_program` thất bại trước runtime | Không kết luận source iOS compile lỗi; không có runtime evidence |
| AppLovin native | Chưa chạy native với key/ad inventory thật | Không có bằng chứng runtime AppLovin Android/iOS |
| Memory | Chưa profile heap/native allocations | Không khẳng định không leak |

Các lệnh test bị lỗi runner không được tính là test fail cũng không được tính là pass. Một lượt đọc example hoàn tất sau khi lập báo cáo: không xác minh được bug cụ thể trong phạm vi đã đọc (`example/lib/main.dart`, native setup chọn lọc, README và một số test); chưa đọc toàn bộ test/native backup/privacy files và không chạy test. Những phần chưa kiểm tra vẫn là coverage gap, không phải “no findings”. Các nhánh audit khác bị API/stream timeout không trả evidence.

## Findings đã xác minh bằng source

### R75-01 — MAJOR — Public `ConsentManager.set()` né COPPA hard-stop/re-init của AppLovin

Vị trí: `lib/src/consent/consent_manager.dart:338-345`, `:323-325`; `lib/src/core/ad_manager.dart:5456-5626`; `lib/src/adapters/applovin_adapter.dart:1153-1159`.

**Trigger:** App dùng AppLovin, SDK đã initialize với `isAgeRestrictedUser == false`; host gọi public API `AdManager().consentManager!.set(settings.copyWith(isAgeRestrictedUser: true))`.

`ConsentManager.set()` chỉ persist state và gọi `applyConsentToProviders`. Provider listener `_syncConsentToAdapter` gọi `_adapter?.applyConsent(...)`, nhưng `AppLovinAdapter.applyConsent()` cố ý no-op; hàm này không gọi `AdManager.setConsent()`. AppLovin MAX 4.x không có API runtime age-restricted setter. Do đó đường public này không chạy nhánh trong `AdManager.setConsent()` vốn đóng `canRequestAds` và reinitialize AppLovin khi cờ COPPA thay đổi. Tình trạng runtime có thể tiếp tục request/show ad mà chưa truyền child-directed signal; AppLovin chỉ được gate cờ đó ở init.

**Guard/coverage:** Guard thực có trong `AdManager.setConsent()` và `AppLovinAdapter.initialize()`, nhưng cả hai bị bypass bởi setter trực tiếp. Các test COPPA hiện có exercise manager/init, chưa thấy test setter công khai trực tiếp sau init trên AppLovin. Đây là đường API hợp lệ vì setter được tài liệu mô tả cho consent setter của host.

**Impact:** Host tích hợp theo đường setter trực tiếp có thể gửi request không age-restricted sau khi consent state chuyển sang trẻ em. Không suy ra lỗi khi host dùng đúng wrapper `AdManager.setConsent()`.

### R75-02 — MAJOR — `ConsentManager.set()` không config làm mất test-device IDs và TFUA của AdMob

Vị trí: `lib/src/consent/consent_manager.dart:338-345`, `:323-325`; `lib/src/core/ad_consent.dart:193-223`.

**Trigger:** AdMob đã initialize bằng config có test-device IDs/QA fleet và `umpTagForUnderAgeOfConsent: true`; host gọi `AdManager().consentManager!.set(settings)` mà không truyền `config` (tham số mặc định `null`).

`_setInternal` chuyển `config: null` cho `applyConsentToProviders`. Hàm đó dựng mới `RequestConfiguration` với `testDeviceIds: []` và TFUA `unspecified` khi config null; native API thay thế toàn bộ config hiện tại. Kết quả xóa đăng ký thiết bị QA và under-age tag. Thiết bị QA có thể nhận quảng cáo thật; traffic test/click vô tình có thể gây invalid activity. Với app dùng TFUA, cập nhật consent có thể bỏ tag cho những request sau.

**Guard/coverage:** `AdManager.setDoNotSell()` đã truyền `_config ?? _lastKnownConfig`; Android integration `r73_android_admob_fixes_test.dart` chứng minh riêng đường đó giữ test-device IDs/TFUA. Guard ấy không bao phủ public `ConsentManager.set()` hoặc `applyToProviders()` khi caller bỏ config. Regression test hiện có kiểm tra riêng setter CCPA, không kiểm tra trực tiếp `ConsentManager.set()` không config sau init.

**Impact:** Rủi ro test traffic thành live traffic trên thiết bị QA; config age targeting mất hiệu lực trong session. Không khẳng định xảy ra nếu host truyền `config` đầy đủ trên mọi lần gọi.

### VIP teardown race — chưa xác nhận, không tính blocker

Một reviewer đề xuất kiểm tra dispose trong `RedeemedKeyLedger.isRedeemed()` tại `lib/src/vip/vip_manager.dart:1471-1511`. Đọc lại source cho thấy `_disposed` được kiểm tra sau `addVip()` tại `:1502`, trước khi ghi hai ledger. Do đó việc dispose trong lookup tự nó chưa chứng minh key bị burn: manager đã disposed trước check sẽ return. `vip_dispose_mid_redeem_test.dart` hiện có teardown tại connectivity và giữa grant/burn, nhưng không có test suspend durable-ledger lookup. Chưa có reproduction chứng minh cửa sổ sau guard gây mất entitlement; cần regression test nhắm chính xác interleaving trước khi báo finding.

### Finding không xác nhận — không đưa vào blocker

Có thể nghi ngờ `ConsentProvenanceJournal.clear()` chạy song song `append()`, `JourneyPrefetcher.notifySignal()` sau `dispose()`, hoặc `clearSdkData()` để observer lưu lại dữ liệu. Source có queue/dispose/gate ở một số observer; phiên này không hoàn tất reproduction hoặc xác minh toàn bộ writer. Không báo chúng là lỗi đã xác minh.

## Đánh giá theo yêu cầu

| Yêu cầu | Đánh giá hiện tại |
|---|---|
| AdMob Android/iOS | Source có adapter; Android AdMob đã smoke-test trên một TECNO thật. iOS build/runtime không có bằng chứng phiên này. |
| AppLovin Android/iOS | Source có adapter và init/privacy gates; không chạy native với khóa/ad inventory thật trên platform nào trong phiên này. |
| Online/offline | Android cold-start online và offline startup hoạt động ở smoke test. Native ad recovery/reconnect/captive portal chưa đủ. VIP grants đã cấp có đường đọc offline; signed-key activation chủ ý cần network. |
| Banner/App Open/rewarded/interstitial | Source có state machine, disposal, callback/watchdog/guard. Android test IDs tải được fullscreen formats; chưa hoàn tất lặp show/dismiss/reward/teardown trên Android+iOS và hai provider. AppLovin không hỗ trợ Rewarded Interstitial; API no-op được mô tả. |
| Memory/lifecycle | Có dispose paths trong source nhưng chưa heap/native profile; chưa tuyên bố zero leak. Route, nested Navigator, Overlay, hidden IndexedStack cần integration contract host tuân thủ. |
| Trial 1 ngày | Release config mặc định 24 giờ; debug 30 giây. Chưa chờ đủ 24 giờ hoặc kiểm toàn bộ reinstall/restore/clock/storage matrix thiết bị. |
| VIP code không backend | Ed25519, expiry/bundle binding, CRL và local ledger có implementation. Không chống được attacker kiểm soát device/storage; multi-device promotion là quyết định sản phẩm. Durable-ledger teardown interleaving chưa được test. |
| Consent/legal | Có UMP, ATT, TCF/IAB, GPP/US privacy, CCPA/RDP, COPPA/TFUA wiring; R75-01/02 là lỗ hổng cụ thể. Chưa test toàn bộ geography, provider dashboard, CMP/partner configuration, withdrawal/ATT trên iOS thật. SDK code không thể tự chứng minh tuân thủ pháp lý toàn cầu. |
| AdMob/AppLovin policy | Safety caps, throttle, fullscreen/modal guard, privacy/test-device mechanisms có trong source; policy phụ thuộc placement, reward disclosure, `app-ads.txt`, store/privacy declarations, network dashboard và cấu hình app. Chưa thể chứng nhận bằng source audit này. |

## Quyết định production

**Không dùng bản hiện tại làm release gate cho production.** Có thể tiếp tục tích hợp QA hoặc internal test với **AdMob test ads**, nhưng không coi smoke test này là chứng minh hai-provider compliance/lifecycle.

Trước production, tối thiểu:

1. Đóng R75-01/R75-02 bằng đường API nhất quán; thêm regression test AppLovin `ConsentManager.set(COPPA=true)` sau init và AdMob setter không config giữ test IDs + TFUA. Chạy full suite thật, không bỏ test discovery.
2. Bổ sung deterministic test chặn `isRedeemed()` tại await, dispose manager, rồi kiểm tra grant persistence lẫn local/durable redeemed ledgers; source hiện có guard sau grant nhưng interleaving này chưa được cover.
3. Chạy iOS build/integration lại trong toolchain ổn định; hoàn tất native consent withdraw/ATT/UMP, ad formats, callback dismiss/reward/teardown. Test AppLovin cần khóa và ad units QA hợp lệ; không dùng production traffic để test.
4. Chạy offline/reconnect thực trên device, gồm mất mạng lúc load, cold-start offline, restore mạng và lifecycle; kiểm tra cả banner/MREC/fullscreen và provider thật.
5. Profile native/Flutter memory qua lặp load/show/dismiss/route-dispose/reinitialize; đối chiếu policy placement/disclosure với cấu hình ứng dụng và tài khoản thực.

## Trạng thái khắc phục R75-01 & R75-02 (2026-10-10)

Cả hai finding đã được sửa và chứng minh qua toàn bộ kim tự tháp kiểm thử:

1. **R75-01 (AppLovin COPPA re-init via direct ConsentManager):** Đã bổ sung callback nội bộ `onPolicyMutation`/`onPolicyMutationApplied` giữa `ConsentManager` và `AdManager`. Khi cờ COPPA chuyển sang `true`, `AdManager` đóng gate `canRequestAds` đồng bộ trước async persist/apply, sau đó tự động kích hoạt `initialize(config: cfg)` để rebuild adapter mang cờ child-directed.
2. **R75-02 (AdMob config retention via direct ConsentManager):** `ConsentManager` lưu trữ ngữ cảnh `AdConfig` đã liên kết từ `AdManager.initialize()`/`applyToProviders()`. Khi gọi `set()` hoặc `reset()` không truyền `config`, SDK sử dụng lại config đã lưu thay vì `null`, giữ nguyên danh sách test device (QA fleet) và tag TFUA.
3. **Kim tự tháp kiểm thử:**
   - **Unit tests:** `consent_manager_test.dart` (19/19 pass), `ad_manager_coppa_recover_test.dart` (4/4 pass), `r73_set_do_not_sell_keeps_admob_request_config_test.dart` (5/5 pass), `init_post_success_throw_test.dart` (53/53 pass), `api_golden_test.dart` (2/2 pass, zero API breakage).
   - **Widget tests:** `r73_ccpa_toggle_keeps_test_devices_widget_test.dart` (3/3 pass, bao gồm programmatic `ConsentManager.set` kiểm tra đồng bộ switch và test devices).
   - **Integration tests:** `example/integration_test/r73_android_admob_fixes_test.dart` (8/8 pass trên thiết bị thật TECNO KJ7, kiểm tra cả test device retention khi gọi trực tiếp `ConsentManager.set`).
   - **Smoke test thiết bị thật:** Cài đặt APK trên TECNO KJ7, hiển thị và đóng App Open ad thành công, tải Interstitial/Rewarded/Rewarded Interstitial, 0 crash/fatal exception.

## Nguồn

- Pub.dev package/API: https://pub.dev/packages/applovin_admob_sdk, https://pub.dev/api/packages/applovin_admob_sdk
- Google UMP Flutter privacy guide: https://developers.google.com/admob/flutter/privacy
- Apple App Tracking Transparency: https://developer.apple.com/documentation/apptrackingtransparency/attrackingmanager/requesttrackingauthorization(completionhandler:)
- `packages/ad_sdk/doc/audit/audit_claude.md` — snapshot trước đó; kết luận cũ không được tính là lượt test mới.
- Source citations trong finding và test files nêu phía trên.
