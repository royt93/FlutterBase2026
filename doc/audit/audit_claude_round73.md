# Audit Claude round 73

Ngày khảo sát ban đầu: 2026-10-06. Cập nhật kết quả: 2026-10-08. Phiên bản khảo sát: pub.dev 3.4.3 và source tại `10fc11b`; các commit local: `698c879`, `885dab4`, `4e33bff`, `c719d9e`, `b6c91bc`.

**CHƯA DUYỆT PRODUCTION. Phạm vi hiện tại: Android + Google AdMob; iOS tạm hoãn theo quyết định người dùng.** Lượt full suite TECNO mới nhất đã chạy đủ 135 file trong một lượt liền mạch: **134 PASS, 1 all-skipped, 0 FAIL, 0 retry, real exit 0**. Lượt này gồm hai test sửa ở `b6c91bc` và test TFUA/refresh bổ sung chưa commit; không chỉ gộp rerun từ lượt 132 PASS trước đó. Các ca opt-in và 6 file chủ ý loại vẫn chưa thuộc bằng chứng suite này. Tên commit có chữ `complete/finalize` không có nghĩa audit hoàn tất. Không tuyên bố full-case PASS, không memory leak hoặc đã đủ điều kiện production. Bản local đã sửa không phải bản mới đã phát hành lên pub.dev; phiên này chưa push/publish.

## 1. Môi trường và baseline

| Kiểm tra | Bằng chứng và giới hạn |
|---|---|
| pub.dev metadata lấy ngày 2026-10-05 | Latest lúc lấy là 3.4.3, published `2026-10-05T15:13:04.164180Z`; chưa truy vấn lại để khẳng định latest sau đó |
| So tarball 3.4.3 với source trước fix | `lib/`, `pubspec.yaml`, `example/lib/` khớp, trừ `.DS_Store` local. Không chứng minh toàn bộ archive/dependency không có rủi ro |
| Analyze SDK/example sau các fix Android + AdMob | `flutter analyze` SDK và example: `No issues found`. Analyze riêng hai test sửa cuối: `No errors`; chưa chạy lại full analyze sau `b6c91bc` |
| Unit/widget trước fix ban đầu | 2.578 PASS, 1 FAIL: `verify_adproof_tool_test.dart:223`, expected exit 1, actual 0 |
| Unit/widget sau các fix Android + AdMob | **2.622 PASS**, log `unit_all3.txt` có `All tests passed!`, không có ca đỏ. Chạy trước sửa cuối hai integration test ở `b6c91bc`; không đồng nghĩa full native matrix PASS |
| API golden | Trước fix: ca chạy riêng timeout. Sau tăng timeout lên 2 phút/test: cả 2 ca PASS trong 20s. Chưa xác định nguyên nhân timeout cũ |
| Example iOS-ID test | `test/admob_ios_test_ids_test.dart` PASS sau sửa |
| Android ban đầu | S24 Ultra SM-S928B, Android 16/API 36, USB |
| Android kiểm chứng bổ sung | Pixel 7 Pro; TECNO KJ7, Android 14/API 34. Full suite cuối và hai file chạy lại trên TECNO, không tính là full suite Pixel |
| iOS | Simulator iPhone 16, iOS 18.6; chỉ chạy một phần, chưa có kết quả iPhone vật lý; hiện ngoài phạm vi quyết định Android + AdMob |

## 2. Findings và fix

### R73-01 — MINOR: public-key corruption test đôi khi không đổi khóa

`packages/ad_sdk/test/verify_adproof_tool_test.dart:212` dùng `pub.endsWith('A')` trên base64 có padding `=`, nên luôn chọn ký tự `A`. Khi ký tự dữ liệu cuối vốn là `A`, khóa không đổi nhưng test yêu cầu INVALID. Đây là lỗi test, không phải bằng chứng Ed25519 nhận khóa giả.

Fix: decode, XOR byte đầu, encode lại. Ca riêng PASS; full SDK suite sau fix 2.579 PASS. Chưa thay verifier production.

### R73-02 — lỗi cấu hình example: iOS App Open test ID sai format

`packages/ad_sdk/example/lib/main.dart:290` dùng `/5662855259`. Plugin thật báo `code=1`, `Ad unit doesn't match format`. Google công bố `/5575463023` tại https://developers.google.com/admob/ios/test-ads .

Fix local: đổi ID và cập nhật assertion trong example test. Sau fix, iOS tải thành công, resume lần đầu bị cold-start guard chặn, lần tiếp theo có `shown` và `impression`. **Chưa xác minh đóng thành công:** log kết thúc bằng watchdog `HARD CAP — no dismiss callback (displayed=true)`; không dùng watchdog làm bằng chứng user đã đóng ad. Thao tác UI không thành công, chưa phân loại đây là lỗi callback của plugin.

### R73-03 — thiếu assertion: test hai chu kỳ có thể PASS khi show lần hai bị chặn

`interstitial_ad_test.dart` và `rewarded_ad_test.dart` chỉ chờ slot hết showing; nếu show bị throttle chặn, kiểm tra vẫn qua. Log Android xác nhận ca thứ hai bị throttle, test vẫn PASS.

Fix local đã commit: `_showAndConfirm` chờ public `canShow...` gate và bắt buộc slot có `isShowing && displayConfirmed` cho mỗi lần. Analyze sạch, **chưa xác minh test mới hoàn tất trên thiết bị**. Lần strict iOS bị dừng, exit 144; file log lúc kiểm tra chỉ có một lần shown, chưa có dismissed. Có thông báo Monitor trái với file log; không dùng thông báo đó để tính PASS. Log strict bị xóa trong quá trình thao tác; đây là thiếu sót giữ bằng chứng.

`QA_AD_STRESS=true` **không tắt throttle**: preset vẫn 2.000ms. Không sửa safety production.

### R73-04 — integration FAIL: MREC đếm widget sai phạm vi

MREC ban đầu đòi đúng 2 `MrecAdWidget` nhưng runtime có thêm widget House Ad `T240_house_ad_demo_*`. Test đã loại đúng widget phụ trong `4e33bff`.

Trong full suite TECNO sau đó, phần Native vẫn FAIL hai lần: expected 2, actual 1. Hai placement T65 bị card T228 ngăn cách trong `ListView`; trên viewport nhỏ, placement thứ hai chưa được dựng. Fix `b6c91bc`: đặt viewport 1080×4000, devicePixelRatio=1 riêng cho ca Native và reset bằng teardown; loại đúng ba key demo T154/T228, không lọc mọi key `T<số>_`. Không đổi SDK hay trang demo. File chạy lại trên TECNO: 3 ca PASS, gồm banner/MREC/Native.

### R73-05 — integration FAIL: native watchdog bị trial VIP chặn load

Log xác nhận `preloadNative` bị gate VIP chặn khi test bấm mô phỏng watchdog; chưa có request/loading watchdog để chuyển sang `hasError=true`. Fix `4e33bff`: `vip.revokeAll()` trước khi chạy ca. Test đã PASS riêng trên S24 và trong full suite TECNO cuối; không sửa watchdog production.

### R73-06 — MAJOR: CCPA toggle làm mất cấu hình AdMob test devices và TFUA

`AdManager.setDoNotSell()` sau init gọi `ConsentManager.set()` thiếu `config`. `applyConsentToProviders` thay toàn bộ `RequestConfiguration`, nên gửi test-device list rỗng và bỏ tag under-age đã cấu hình. Finding từ hai reviewer được gộp thành một.

Fix `c719d9e`: truyền `_config ?? _lastKnownConfig`. Unit và widget CCPA toggle đỏ khi bỏ fix, xanh khi có. Ca Pixel qua log sink đỏ khi bỏ fix (expected 17, actual 0), xanh khi có. **Không có native readback:** `MobileAds.getRequestConfiguration()` trên Android plugin đang dùng ném lỗi codec, nên ca device dựa vào record SDK sau khi gửi cấu hình. Bổ sung mới: unit kiểm TFUA yes/unspecified khi under-age true/false và CCPA bật/tắt; widget công tắc kiểm TFUA yes cùng test-device list. Hai file unit/widget PASS 6 ca. Integration TECNO quan sát payload `MobileAds#updateRequestConfiguration`, chuyển tiếp nguyên message tới messenger native thật và kiểm response trước khi ghi kết quả. TFUA và QA hashes đều đúng qua các toggle, PASS riêng và trong full suite mới. Đây là kiểm payload gửi native + response thành công, không phải native readback; cấu hình TFUA true/false được đổi bằng `debugConfig` trong test và khôi phục ở teardown.

### R73-07 — MAJOR: refresh no-fill hủy banner/MREC đang hiển thị

Handler `onAdFailedToLoad` trước đây dọn cả ad đã ở trạng thái ready khi callback đến từ auto-refresh. Fix `c719d9e`: giữ ad khi `slot.isReady && isLoaded`, vẫn dọn lỗi lần load đầu. Unit banner/MREC và widget banner đã đỏ khi bỏ guard, xanh khi có.

**Coverage device mới:** thay ca chỉ quan sát fill bằng hai ca banner/MREC. Mỗi ca bắt buộc ad thật tải ready, lấy chính `BannerAd` đang cached, phát callback `onAdFailedToLoad` code 3 qua listener của adapter, rồi kiểm slot vẫn ready, isLoaded=true, hasError=false, needsRecovery=false và ad object còn nguyên identity. Hai ca PASS riêng TECNO và trong full suite mới. Lỗi refresh được mô phỏng bằng callback trên ad thật, không phải auto-refresh no-fill tự nhiên; chưa mutation bỏ guard trên bản integration mới để xác nhận đỏ. Giới hạn cũ `kept == 0` có thể PASS đã được loại.

### R73-08 — MINOR sau verify: inline AdMob không phục hồi khi reconnect

Banner/MREC lỗi giữa request mất mạng vẫn giữ widget `_allowed=true`; reconnect preload của AdMob là no-op, nên không tạo request mới. Fix `c719d9e`: handler reconnect gọi recovery riêng của `AdMobAdapter` cho các key banner/MREC/native có `needsRecovery`, có gate `canReload`.

Unit và widget đã đỏ khi bỏ wiring, xanh khi có. Ca Pixel cắt mạng thật trước request và tạm dùng `debugConnectivityReady=false` để cho SDK gửi request offline; có lỗi native `loadBanner ❌ 0`, `FAILED_IN_FLIGHT=true`. Khi mạng về, có fix thì request mới và fill; bỏ wiring thì không ready, ca đỏ. Đây là **mạng thật + seam connectivity**, không phải mất mạng mid-request hoàn toàn tự nhiên. Ca opt-in này không chạy trong full suite dùng cờ CI mặc định. MREC/native recovery chưa có bằng chứng device tương đương banner.

### R73-09 — MINOR: VIP hết hạn lúc suspend chưa tính lại khi resume

`resyncSessionClock()` trước đây chỉ re-anchor đồng hồ; notifier VIP có thể giữ active nếu timer hết hạn chưa chạy trong lúc suspend. Fix `c719d9e`: đi qua handler expiry hiện có khi resume, không thêm timer hoặc đổi quy tắc entitlement offline.

Unit, widget và Pixel đều đỏ khi bỏ fix, xanh khi có. Timer bị suspend được mô phỏng bằng `_DeadTimer`; chưa đo một phiên khóa máy/ngủ thật qua toàn bộ cửa sổ VIP. Trong full suite TECNO và lượt chạy lại, ca này PASS.

### R73-10 — MINOR: refill sau show failure bị load backoff chặn

Show failure AdMob đánh slot cooldown rồi manager gọi refill; `beginLoad()` bị chính timestamp lỗi show chặn. Fix `c719d9e`: helper mark show failed rồi xóa timestamp backoff, giữ failure count; load failure thật vẫn bị throttle. Unit/real-path test cho bốn format xanh; khi bỏ fix, năm ca real-path đỏ.

Ca device cũ reset slot nhưng không dispose ad cache, nên có thể PASS giả hoặc bị stuck cooldown tùy timing. Trong full suite TECNO, ca này FAIL hai lần. Fix **test** `b6c91bc`: đợi initial interstitial ready, dùng `discardCachedFullscreenAds()` để dispose cache, mô phỏng failed show bằng seam rồi bắt buộc refill bắt đầu ngay (`isLoading || isReady`) và cuối cùng ready. File chạy lại TECNO: 4 ca PASS, 1 opt-in network skip. Show failure dùng seam, không phải lỗi show native phát sinh tự nhiên; bản test cuối chưa được chạy mutation bỏ fix SDK để xác nhận đỏ lần nữa.

## 3. Kiểm chứng native thủ công

| Ca | Android 16 thật | iOS 18.6 Simulator |
|---|---|---|
| Init AdMob | PASS | PASS sau xử lý ATT và mở lại |
| UMP notRequired | Đã quan sát | Đã quan sát; không chứng minh nhánh EEA required |
| ATT | Không áp dụng | Prompt thật có hiện; đã bấm Allow, lần mở lại status authorized |
| Trial debug 30s | Cấp quyền, bỏ load fullscreen trong grace; hết hạn gọi refill | Có log cấp grace; không chứng minh trial release 24h/chống reinstall |
| Interstitial | Một lần shown/dismissed/reload; test cũ lần hai bị throttle | Phiên app thủ công có 2 shown/dismissed/reload. Lần integration strict mới chưa PASS |
| Rewarded | Một lần shown, thưởng 10 coins, dismissed earned=true; lần hai bị throttle | Shown và thưởng 10 coins; chưa có dismissed/reload. Lần strict ghi `did not complete` và `Some tests failed`; bị dừng exit 144. Không tính PASS, chưa chứng minh lỗi SDK do thao tác đóng chưa thành công |
| App Open | Ảnh test ad hiện và trở về Home sau thao tác; không suy ra mọi resume edge case | Sau fix có shown/impression; kết thúc bằng hard-cap watchdog, chưa hoàn tất đóng thật |
| Banner/MREC/native fill | Lượt S24 ban đầu chưa đủ manual. Bổ sung Pixel/TECNO: test banner/native/MREC PASS với assertion ready; chưa đủ manual từng format trong release | Chưa kiểm chứng |
| Rewarded bỏ sớm/không nhận thưởng | Chưa kiểm chứng | Chưa kiểm chứng |
| Offline cold start/reconnect | TECNO có ca boot/network restore PASS; Pixel có ca banner native load fail offline rồi reconnect hồi phục, dùng seam connectivity. Không coi đây là toàn bộ cold-start/lifecycle matrix | Chưa kiểm chứng |
| Heap/memory leak | Chưa profile | Chưa profile |
| AppLovin MAX inventory thật | Chưa có credentials/test fill | Chưa có credentials/test fill |

UMP iOS: hai integration lần trước FAIL init trong khoảng 90s khi status required. `SKIP_UMP=true` chỉ bỏ gọi từ splash; SDK vẫn auto-request. Ảnh cho thấy pre-prompt và ATT system prompt, không chứng minh form UMP không thể hiện. Sau cấp ATT, mở lại trả notRequired và init được; chưa xác định nguyên nhân nhánh required chưa hoàn tất.

## 4. Full integration suite và tính hợp lệ của dữ liệu

Inventory kiểm tra cuối: **141 file `*_test.dart`**. Script CI chạy **135**, chủ ý loại 6 file:

- `app_open_ad_test.dart`
- `interstitial_ad_test.dart`
- `rewarded_ad_test.dart`
- `r36_real_applovin_appopen_over_banner_test.dart`
- `round37_coppa_hardstop_test.dart`
- `round37_reload_while_showing_test.dart`

Các file yêu cầu đóng ad thủ công hoặc chạy provider AppLovin không được tính PASS trong runner AdMob. Không tính skip là PASS.

### Full suite TECNO và lượt chạy lại cuối

Thiết bị: **TECNO KJ7, Android 14/API 34, USB `115333744A005844`**. Source SDK `c719d9e`; hai test sửa sau suite ở `b6c91bc`.

Cờ: `AD_PROVIDER_ADMOB=true`, `SKIP_ATT=true`, `SKIP_UMP=true`, `SKIP_SPLASH_AD=true`; mỗi file invocation riêng, retry một lần nếu lỗi. `RUN_REAL_NETWORK_TEST` không bật.

| Lượt | Kết quả xác minh từ log | Giới hạn |
|---|---|---|
| Full suite `c719d9e` | 135/135 file trong runner đã chạy, **132 PASS + 2 FAIL + 1 all-skipped**, real exit 1 | Hai FAIL đều đã retry và vẫn FAIL; không gọi đây là full suite xanh |
| File FAIL 1 | `multi_instance_ad_test.dart`: Native expected 2, actual 1 | Fix viewport + lọc đúng key demo ở `b6c91bc` |
| File FAIL 2 | `r73_android_admob_fixes_test.dart`: interstitial chưa ready sau simulated show failure | Fix dọn cache thật + bắt buộc refill bắt đầu ngay ở `b6c91bc` |
| Hai file chạy lại `b6c91bc` | **7 ca PASS, 1 ca opt-in skip**, log `All tests passed!`, real exit 0 | Chạy riêng sau sửa, không phải chạy lại toàn bộ suite liền mạch |
| Skip toàn file | `ump_eea_consent_test.dart` | Chưa kiểm nhánh EEA form; không tính PASS |
| Skip từng ca | Các ca cần cờ riêng, gồm mạng thật | Không suy ra không có skip chỉ vì file có marker PASS |
| Hạ tầng lượt cuối | Không có `ENOSPC` hoặc lỗi Gradle; cuối suite còn gần 36GB; không còn test runner ads sau kết thúc | TECNO được điều phối với phiên khác; chỉ nhường sau khi runner kết thúc |

**Lượt xác minh mới sau bổ sung coverage:** chạy từ đầu trên cùng working tree, đủ **135/135 file: 134 PASS, 1 all-skipped (`ump_eea_consent_test.dart`), 0 FAIL, 0 retry, real exit 0**. Không có file trong inventory runner bị bỏ sót; không có `ENOSPC`; cuối lượt còn 16GB; không còn runner ads sau khi kết thúc. Đây là một lượt liền mạch trên bản test mới, không phải kết quả gộp. Cờ chạy giữ như trên; 6 file chủ ý loại và ca `RUN_REAL_NETWORK_TEST` vẫn ngoài lượt này. Code production không đổi so với `c719d9e`; ba file test coverage mới chưa commit lúc chạy. Log: `tecno_postcoverage_suite.txt`, `tecno_postcoverage_suite.exit`.

Lần Pixel trước đó bị dừng: Gradle thiếu `metadata.bin` sau cache bị dọn, hàng loạt file fail trước khi vào test. Không dùng các lỗi build đó làm bằng chứng SDK hồi quy. Sau `gradlew --stop`, targeted test `admob_late_load_midshow_test.dart` trên TECNO build lại 311s và PASS 4/4 ca. Lượt full suite TECNO cuối chạy sau xác minh này.

Hai test cũ `banner_ad_test.dart` và `native_ad_test.dart` đã thêm revoke trial VIP + assertion ít nhất một placement ready ở `c719d9e`. Banner/native/MREC chạy riêng Pixel: 4 ca PASS; cả ba file cũng PASS trong full suite TECNO. MREC vốn đã có revoke VIP; không báo lại thiếu revoke cho file này.

Lịch sử thiếu sót giữ bằng chứng: có lần ngắt mạng/cài test trùng suite S24 và có lần xóa log/ảnh cũ trong `/tmp/r73`. Kết quả trùng thời gian không dùng để chốt. Hai file fail cuối TECNO được chạy lại sau khi thiết bị rảnh, không đổi mạng; SDK giữ nguyên.

Wi-Fi/data đã được khôi phục sau các ca mạng thật. Không ngắt mạng hoặc cài app khác trên thiết bị khi suite đang chạy.

### Release/R8 smoke bổ sung trên TECNO

Build bản sao example/SDK local trong `/tmp/admob-release-r73-qn2h4sob`, application ID riêng `com.example.admobr73releasesmoke` để không ghi đè app host. Không sao chép cấu hình signing private; APK dùng chứng thư Android Debug nhưng build mode **release/AOT**, không có debuggable flag.

`flutter build apk --release --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_ATT=true --dart-define=SKIP_SPLASH_AD=true` thành công, APK 60,8MB. Flutter Gradle plugin mặc định bật minification/resource shrinking; có `mapping.txt` khoảng 49MB và `configuration.txt` không có `-dontshrink`/`-dontobfuscate`. Không đổi cấu hình R8 trong repo.

**Build log cần giữ giới hạn:** có chẩn đoán Kotlin metadata 2.3.0 so với compiler expected 2.1.0 dù Gradle build vẫn thành công. Không khẳng định log build hoàn toàn sạch chỉ từ exit 0.

Cài package riêng trên TECNO, cold launch vào Home thành công; mở VIP API playground, quan sát trial release tới ngày kế tiếp rồi bấm `End VIP now`, UI chuyển VIP inactive. Mở Banner demo không crash; không thấy `FATAL EXCEPTION`, `MissingPluginException`, `NoSuchMethodError`, `ClassNotFoundException` trong log process thu được, nhưng vẫn có diagnostic đồ họa/platform thông thường.

**Fill release CHƯA PASS:** banner trống do SDK chủ ý hard-block Google test ad unit IDs trong release. Log viewer hiển thị cảnh báo release test-ID guard. Người dùng chọn giữ guard, ghi smoke giới hạn và chạy suite; không bypass guard hoặc dùng production IDs giả. Bằng chứng này chỉ xác nhận build R8, install/startup, native initialization và UI không crash trong ca quan sát, không xác nhận quảng cáo hiển thị trong release hoặc bản ký production.

### iOS đã chạy một phần, hiện tạm hoãn

Đã chạy một số file trên simulator iOS 18.6. `ad_retry_policy_test.dart` và `anomaly_event_test.dart` fail init với UMP `required`; đối chiếu `10fc11b` trên cùng simulator cũng fail y hệt. Điều này loại hồi quy round 73 cho **hai file được đối chiếu**, không chứng minh mọi lỗi iOS đều là môi trường.

Nhóm lọc 36 file bằng heuristic: 33 PASS, 2 FAIL, 1 all-skipped. Một file thực ra vẫn gọi initialize: `round38_native_ad_error_retry_test.dart`, UMP form timeout 180s và gate false. `t200_clear_sdk_data_test.dart` fail Keychain `-25299` lúc ghi setup; chưa đối chiếu baseline hoặc chứng minh chính xác nguyên nhân. Các lượt khác có thêm file PASS và lỗi init, nhưng không cộng thành full suite iOS xanh. Người dùng quyết định tạm bỏ iOS, chỉ tập trung Android + AdMob; không sửa iOS để vượt consent gate.

### Hồ sơ log

- Full suite mới nhất: `/tmp/r73/tecno_postcoverage_suite.txt`, `/tmp/r73/tecno_postcoverage_suite.exit` (exit 0; 134 PASS, 1 all-skipped, 0 retry).
- Full suite cũ trước sửa test: `/tmp/r73/tecno_final_out.txt`, `/tmp/r73/tecno_final.exit` (exit 1).
- TFUA/refresh bổ sung: `/tmp/r73/tfua_unit_widget.txt` (+6 PASS), `/tmp/r73/tecno_tfua_refresh.txt` (+6 PASS, ~1 skip).
- Release/R8: `/tmp/r73/release_r8_build.txt`, `release_smoke_app.log`, `release_log_ui.xml`, ảnh `release_initial.png`, `release_banner.png`; APK/mapping ở bản sao `/tmp/admob-release-r73-qn2h4sob`.
- Hai file chạy lại: `/tmp/r73/tecno_two_fixed_tests.txt` (`+7 ~1`, `All tests passed!`, task exit 0).
- Gradle recovery: `/tmp/r73/tecno_gradle_recovery_check.txt` (`+4`, PASS).
- Unit/widget: `/tmp/r73/unit_all3.txt` (`+2622`, PASS); analyze SDK/example: `an5.txt`, `an5e.txt`.
- Pixel device/mutation: `int_dns_red.txt`, `int_sf_red.txt`, `int_vip_red.txt`, các file green tương ứng và log mạng thật; một số log mạng dùng cùng tên đã bị ghi đè trong các lượt thử. Không coi mọi lượt đều còn hồ sơ độc lập.

Logs `/tmp/r73` là scratch, không bảo đảm tồn tại lâu dài. Báo cáo ghi số liệu đã xác minh; chưa có bộ log/ảnh bền vững cho toàn bộ audit.

## 5. Giới hạn đã chốt, không báo lại thành lỗi

VIP activation cần mạng, verification local; entitlement sau activation dùng offline. Không backend không bảo đảm globally single-use hay chống thiết bị bị sửa hệ thống tuyệt đối. Trial Android best-effort, iOS Keychain không phải bằng chứng chống mọi tamper. AVP2 bỏ bundle check khi PackageInfo lỗi là đánh đổi đã ghi trong source. QA hashes release, AVP1 opt-in và MAX COPPA fixed-at-init là quyết định sản phẩm.

## 6. Đánh giá hiện tại

**Full suite Android + AdMob trên TECNO đã xanh trong một lượt liền mạch: 134 file PASS, 1 all-skipped, 0 FAIL, 0 retry, real exit 0.** Baseline unit/widget full suite trước test coverage bổ sung: 2.622 PASS; TFUA unit/widget bổ sung chạy riêng 6 ca PASS. Release/R8 build và startup smoke đã làm, nhưng fill release bị test-ID guard chặn đúng thiết kế. **Chưa duyệt production toàn bộ matrix.** Hai test fix đã commit `b6c91bc`; TFUA/refresh test bổ sung và cập nhật báo cáo chưa commit; không đổi SDK production trong đợt này. Phiên này chưa push/publish.

Các phần còn thiếu trong phạm vi Android + AdMob:

- Fill quảng cáo release với cấu hình ad units hợp lệ; hiện guard Google test-ID được giữ, không bypass. Cần phân tích thêm chẩn đoán Kotlin metadata trong release build log nếu dùng build này làm release gate.
- Auto-refresh no-fill tự nhiên trên device (coverage mới là callback mô phỏng trên ad đã fill thật); mutation integration mới cho TFUA/refresh chưa chạy lại.
- MREC/native reconnect, lỗi show native thực tế (thay vì seam), lifecycle teardown và các nhánh chưa có đủ ba tầng unit/widget/integration. TFUA riêng đã được bổ sung và PASS; không tuyên bố “mọi case đủ ba tầng” từ các ca đã làm.
- Đóng fullscreen thủ công, rewarded bỏ sớm/không nhận thưởng và EEA consent form; các file runner loại không được tính PASS.
- Heap/timer memory profiling trong phiên dài; review static không chứng minh không leak.
- Kiểm tra lại test-quality: unit đã dùng assertion mạnh và mutation cho nhiều fix, nhưng một số device case còn dựa log/seam hoặc chỉ no-crash/fill observation.

Workflow Android + AdMob có 7 finder và verify, trả 9 finding: 6 surviving (gộp thành 5 vấn đề do CCPA trùng), 3 refuted. Các observation test yếu được giữ như hạn chế coverage, không biến thành lỗi runtime đã xác nhận. Kết quả reviewer không thay thế bằng chứng build/device và không bảo đảm chính sách AdMob/pháp lý mọi quốc gia chỉ từ UMP notRequired.

iOS và AppLovin MAX hiện ngoài phạm vi người dùng chọn; còn thiếu kiểm chứng ở các phần này không được diễn đạt thành Android + AdMob PASS hoặc bằng chứng dual-provider production.
