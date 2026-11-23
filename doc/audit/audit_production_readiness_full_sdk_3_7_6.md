# Audit production — Flutter AdMob/AppLovin SDK 3.7.6

- **Ngày rà soát:** 2026-11-21.
- **Đối tượng:** `packages/ad_sdk/` và `example/`; Android/iOS; AdMob/AppLovin MAX; offline, lifecycle, trial/VIP, consent và production readiness.
- **Verdict:** chưa GO rollout production. Android + AdMob có thể cân nhắc closed pilot sau khi host hoàn tất và ký đủ gates. iOS/AppLovin chưa đủ native-device/host evidence.
- **Giới hạn:** test ads không chứng nhận legal compliance, production fill, revenue hoặc host readiness. Không dùng production IDs/credentials; không tap creative/CTA. Giao thức đóng ad: Samsung App Open đóng bằng system Back; Interstitial, Rewarded và Rewarded Interstitial đóng bằng nút X đã hiển thị (Interstitial lượt đầu thử Back nhưng chưa đóng được). Source SDK trong repo không thay đổi; audit không sửa hành vi runtime.

## 1. Bản phát hành và test coverage

Pub.dev API xác nhận 3.7.6 phát hành `2026-11-19T13:44:43.420129Z`, Dart `>=3.10.0 <4.0.0`, Flutter `>=3.38.1`. Archive SHA-256:

`7e94a5ea4f65080b2ad316d16ba3539f7831268166a8ef87a682ace0d3368c25`

Disposable consumer `/tmp/ad_sdk_smoke_376_isolated` resolve `source: hosted`, version 3.7.6 và checksum trên. Metadata/checksum xác nhận danh tính package, không tự chứng minh runtime correctness. Historical device evidence round 79 chủ yếu source/runtime 3.7.0/3.7.1; T283 dùng hosted 3.7.1, không phải 3.7.6.

Các suite đã chạy trong phiên:

- Targeted consent suites: 323 pass.
- Release test-ID/QA-hash suites: 456 pass.
- `npa_consent_wiring_test.dart` và `admob_behavioral_test.dart`: 142 pass. Đây là số test riêng từng lượt, không cộng thành số test độc lập vì coverage có thể trùng.

## 2. Tổng kết theo hạng mục

| Hạng mục | Bằng chứng | Giới hạn còn lại |
|---|---|---|
| Android + AdMob | Hosted 3.7.6 debug consumer: Samsung xác nhận init, Banner, Native và App Open Google test ads; TECNO xác nhận EEA refusal/cached status, adapter init, non-personalized adapter state, Banner và Interstitial load/show/dismiss/reload; S24U xác nhận EEA refusal, init, QA IDs, Rewarded load/show/earned/dismiss và Rewarded Interstitial disclosure accept/load/show/earned/dismiss. | Chưa có host pilot, publisher release artifact/signing/R8 hoặc production inventory evidence. Mỗi format chỉ chạy trên một thiết bị: Interstitial chỉ TECNO (cached refusal, `formShown=false`); Rewarded và Rewarded Interstitial chỉ S24U (`formShown=true`). Chưa kiểm consent accept/withdrawal/Privacy Options, đóng sớm không earned (Back trong đếm ngược không đóng được creative test, xem 4c), load/show failure, SSV end-to-end, release/R8 trên 3.7.6; Banner/Native/App Open chưa có file evidence trong bundle repo. |
| iOS + AdMob | Có Flutter integration/source/tests; Google UMP/ATT phụ thuộc native plugin. | Chưa có iPhone thật xác minh ATT, UMP và ad gate. Round 79 ghi CI simulator bỏ ATT/UMP; T256 còn physical-device check. Simulator/build pass không thay thế consent verification. |
| AppLovin MAX | Có adapter/bridge và fake-bridge lifecycle/safety tests. | Chưa có native-device/credentials evidence Android/iOS trong phạm vi đã rà. Fake tests không chứng minh load/show/reward/dismiss hoặc mediation thật. Consent writes fire-and-forget, không xác nhận native đã nhận thành công. |
| Offline/online | Source có offline gates/reconnect path; round 79 ghi một lượt tắt/bật Wi-Fi thật trên TECNO với request suppression và MREC recovery. | Một thiết bị/lượt Wi-Fi không đại diện cellular, captive portal, mọi format/provider hoặc host. Online không bảo đảm fill. |
| Lifecycle/memory | Có slot state machine, disposal và regression coverage. Round 79 có 50 vòng init/destroy với fake adapter kiểm listener detach. | Fake tests và `dumpsys meminfo` snapshots không chứng minh không rò native heap. T267 đã đóng ở mức không đo được frame-presentation của Flutter SurfaceView (không còn là kết quả chờ); không có FPS/jank hoặc zero-leak claim. |
| Trial 24 giờ | `FirstInstallVipGrace.auto` mặc định release 24h; example debug 30 giây, có test coverage. | Android clear-data có thể reset trial/ledger; reinstall phụ thuộc Auto Backup. Đây là trade-off product đã chấp thuận, không phải paid-license anti-fraud guarantee. |
| VIP không backend | AVP2 Ed25519, expiry/bundle binding, local redeemed ledger và signed CRL. Activation cần mạng; VIP đang hiệu lực dùng offline. | Không bảo đảm globally single-use giữa thiết bị hoặc revocation tức thì khi chưa cập nhật CRL. Không dùng làm paid license chống chia sẻ. Smoke không dùng private key thật của owner. |
| Consent/policy | UMP flow, TCF mapping, release test-ID guard và QA fleet luôn hoạt động cả debug/release. TECNO và S24U quan sát refusal, adapter `nonPersonalizedAds=true`; mỗi thiết bị dùng UMP test hash do chính thiết bị ghi log. | UMP `notRequired` không chứng minh consent mọi thị trường; `obtained`/`canRequestAds=true` không đồng nghĩa personalized consent. Publisher chịu trách nhiệm CMP/messages, disclosures, privacy URLs, app-ads.txt, placements và legal basis. MAX age status cố định lúc init theo product contract. |

## 3. Consent source review

Round 44 ghi findings ở 2.9.23, không đủ để khẳng định 3.7.6 còn cùng lỗi. Built-in `consent_dialog.dart` không còn trong source hiện hành. Release consent-footgun guard và regression tests đã có; host/release E2E chưa được chứng minh trong phiên này.

**Host trust boundary:** `setConsent()` mặc định `qualifiesAsConsentFlow: true`; host có thể gọi affirmative consent để đánh dấu flow explicit và gỡ footgun block. SDK không xác minh giá trị đến từ CMP phù hợp hay chỉ hard-coded host config. Publisher chỉ được cấp affirmative consent dựa trên consent/legal basis phù hợp; API boolean không phải legal certification.

Source hiện tại:

- `_applyUmpConsentResult` kết hợp UMP status với `IabStorage.tcfAllowsPersonalisedAds()`. Purpose 1/3/4 không đủ consent thì không cho personalized mapping; đọc store lỗi fail-closed. Không diễn giải `obtained` thành accept đơn thuần.
- `AdMobAdapter.applyConsent()` map `hasUserConsent=false` sang `nonPersonalizedAds=true`; `RealGmaBridge` truyền vào `AdRequest`. Runtime log adapter state không phải phép bắt tham số network/native request hoặc quyết định phân phối phía Google.
- Khi có TCF string, consent forwarding không ghi đè MAX `setHasUserConsent`; MAX tự đọc vendor state. Không có TCF vẫn dùng boolean cho non-CMP integration; writes fire-and-forget.
- Pre-init `setDoNotSell` và preservation của host/QA test-device IDs có regression tests. Fallback conservative có coverage timeout/offline/provider errors, không phải legal certification.

Không có defect runtime consent được xác nhận từ các lượt hosted 3.7.6 này, nhưng phạm vi chỉ gồm đường refusal/cached-refusal; accept, withdrawal và Privacy Options chưa chạy lại trên 3.7.6. UMP refusal có thể trả `canRequestAds=true`; không dùng giá trị đó làm bằng chứng personalized consent hoặc bảo đảm fill.

## 4. Hosted 3.7.6 device evidence

### Samsung — smoke ban đầu

Disposable debug app `com.roy.admobwrapper.audit376`, Samsung S24 Ultra (serial không lưu trong report); `AD_PROVIDER_ADMOB=true`, `SKIP_ATT=true`, `SKIP_SPLASH_AD=true`; Google test App ID/ad units, không production credentials.

- UMP `notRequired`; AdMob init pass.
- Hai Banner và Native Google test creatives hiển thị; Native validator báo “No implementation issues found”.
- App Open có nhãn `Quảng cáo thử nghiệm`, hiện sau resume thứ hai; cold-start guard skip lượt đầu; đóng bằng system Back.
- Interstitial/Rewarded/Rewarded Interstitial load callbacks thành công; không verify show/reward/dismiss trên Samsung.
- QA app force-stop và uninstall khỏi user 0 thành công. User 150 bị `SecurityException: Shell does not have permission to access user 150`; package presence/removal ở profile đó chưa xác minh. Không cài/clear/uninstall host `com.roy.admobwrapper`.

### TECNO — EEA và Interstitial diagnostic

Owner chọn TECNO KJ7 cho mọi phiên. ADB xác nhận model TECNO KJ7; serial không lưu trong report. Trước cài, QA package vắng trong user 0; APK metadata xác nhận package QA riêng. Ping IP thành công; không đổi Wi-Fi/VPN. Kết quả ping chỉ xác nhận IP reachability, không bảo đảm mọi endpoint ads/CMP.

Bản consumer dùng hosted 3.7.6, Google test units và UMP hash của chính TECNO. Diagnostic copy chỉ tăng timer điều hướng example từ 8 lên 240 giây trong `/tmp`; `AdConfig.splashMaxDuration` vẫn 8 giây, SDK vẫn có log `forcing markSplashInactive`. Không sửa source SDK/repo hoặc tắt consent/safety gates. Vì vậy các lượt này không kiểm default example 8 giây trên form EEA chậm: host giữ cap mặc định cần kiểm riêng xem rời splash khi gate còn `required` có an toàn không.

**Đính chính thời gian UMP:** các khoảng 24 giây trước đây tính từ form presentation tới callback bao gồm thời gian chờ ADB chọn nút. Không đủ bằng chứng kết luận UMP mất 24 giây để xử lý hoặc hard-cap 8 giây gây mất callback; tăng timer không phải bằng chứng fix lỗi.

Lượt có log liên tục tại `/tmp/qa376_interstitial_20261121/`:

1. TECNO run: EEA refusal được áp dụng; một lượt form chưa được bấm trước timeout 180 giây trả `required`/gate-closed. Không tính làm consent-completion evidence. Sau đó rerun trên cùng owner-selected TECNO dùng UMP test hash riêng thiết bị, cached refusal, AdMob init/17 QA IDs và Interstitial Google test-ad load/show/dismiss/callback/reload pass. Banner Google test creatives cũng đã hiển thị trên TECNO. QA package được uninstall khỏi TECNO user 0.
2. Owner sau đó chọn S24U. Tab Samsung Settings > Apps có nhãn `Thư mục bảo mật`, không phải đã xác minh là work profile. Tìm `com.roy.admobwrapper.audit376` không có kết quả; chưa kiểm chứng tìm kiếm này hỗ trợ package ID hay tab đó tương ứng user 150. Vì vậy đây chỉ là quan sát UI, không chứng minh package vắng trong user 150. Owner-profile query không thấy QA package trước lượt cài; shell không có quyền đọc user 150.
3. UMP test hash lấy riêng từ S24U logcat, không lưu giá trị vào report. Hosted 3.7.6 debug QA build dùng Google test IDs, package riêng `com.roy.admobwrapper.audit376`, `UMP_EEA_DEBUG=true`, `SKIP_ATT=true`, `SKIP_SPLASH_AD=true`.
4. S24U EEA test form hiện; chọn `Do not consent`. Log: `status=obtained`, `formShown=true`, `canRequestAds=true`; TCF purpose bits chặn personalization. AdMob init success; 17 QA device IDs; `nonPersonalizedAds=true`.
5. Secondary preload logs xác nhận Rewarded và Rewarded Interstitial load callbacks success; Rewarded load sẵn. VIP auto-grant toggle vẫn OFF.
6. Bấm Rewarded `Watch ad for +10 coins`; creative hiển thị `Quảng cáo thử nghiệm`. UI sau dismiss: `Coins: 10`, `Last: earned`; reward earned, callback và dismiss pass. Không bật VIP auto-grant, không nhập SSV user ID, không tap creative/CTA.
7. QA package force-stop/uninstall khỏi S24U owner profile thành công; truy vấn owner profile không còn package. Quan sát Settings trước cài chỉ có search không trả kết quả trong tab `Thư mục bảo mật`; trạng thái user 150 chưa xác minh. Không suy cleanup owner profile sang profile khác.

**Phạm vi PASS:** EEA refusal/cache recognition, TCF refusal mapping, adapter `nonPersonalizedAds=true`, AdMob init, QA test-device config; Banner test creatives và Interstitial load/show/dismiss/callback/reload trên TECNO; Rewarded load/show/earned/dismiss và Rewarded Interstitial disclosure accept/load/show/earned/dismiss trên S24U. Rewarded Interstitial: disclosure được accept; Google test creative ghi `Quảng cáo thử nghiệm`; log có reward callback `type=Coins amount=10` và `onDone: shown=true earned=true`. UI sau dismiss `Coins: 10`/`Last: shown=true earned=true` chỉ có trong capture local, không nằm trong bundle repo; ảnh Rewarded result (`Coins: 10`, `Last: earned`) là của plain Rewarded. VIP auto-grant vẫn OFF. Không có network-level/native request capture chứng minh tham số `npa=1` của từng request hoặc personalized serving phía Google. Không suy diagnostic debug/example thành production host evidence.

Evidence tối thiểu đã lọc và lưu trong [`evidence/hosted376_android_20261121/`](evidence/hosted376_android_20261121/): ba log callback cho Interstitial, Rewarded và Rewarded Interstitial; sáu ảnh test creative/disclosure/kết quả. [`manifest.json`](evidence/hosted376_android_20261121/manifest.json) ghi scope, phép biến đổi, SHA-256 nguồn và từng file xuất. Log giữ timestamp/tag/callback, bỏ PID/TID, device hashes/serial và mọi dòng ngoài allowlist; marker loading/success được đổi sang chữ. Ảnh cắt status bar và bỏ metadata, giữ nhãn test và kết quả UI. Đây là trích đoạn, không dùng chứng minh không có lỗi, request khác hoặc callback trùng.

Raw log vẫn chỉ nằm local trong `/tmp/qa376_interstitial_20261121/`, `/tmp/s24u_qa376_rewarded.log` và `/tmp/s24u_rewarded_interstitial_20261121/`. Capture gốc gồm cả tag `UserMessagingPlatform`, có thể chứa consent strings; không đưa raw log vào repo hoặc chia sẻ. Hai capture trước kết thúc mã 255 sau khi install báo `Success`; chưa xác định nguyên nhân kết thúc, nhưng evidence reward/dismiss đã lưu đủ. Không chạy lại test ads trong lượt lưu evidence ngày 2026-11-22; source SDK không đổi.

### 4c. Pixel 7 Pro — nhánh không thưởng (2026-11-22)

Pixel 7 Pro Android 17 được owner chọn khi TECNO/S24U vắng. Hosted 3.7.6 debug QA build như trên, package riêng, Google test ads, UMP hash do chính Pixel ghi log. Ping IP thành công. Cài đặt, log và QA package chỉ trên owner profile.

1. Form EEA hiện; chọn `Do not consent`. Log: `status=obtained`, `formShown=true`, `canRequestAds=true`, TCF purposes không cho personalization, AdMob init success, `nonPersonalizedAds=true`.
2. Rewarded Interstitial đã preload. Disclosure hiện; bấm **Cancel**: UI `Coins: 0`, `Last: shown=false earned=false`; log `showRewardedInterstitialAd disclosure declined`; không có show/impression/reward. Đây là PASS cho nhánh Cancel (một thiết bị, một lần, chưa ép lặp).
3. Rewarded: lần thứ nhất bấm Back khi creative hiện `Bạn sẽ nhận được phần thưởng sau 5 giây`; lần hai bấm Back khi còn 6 giây. Cả hai lần creative vẫn tiếp tục, tới `onEarnedReward: result=true`, rồi dismiss `earned=true`; UI cuối `Coins: 20`. Vì không có nút đóng và Back không rời ad trong countdown, **chưa kiểm được nhánh đóng sớm không earned** (không tap creative/CTA, không tắt app/mạng để ép lỗi). Một lượt Home thêm (~3 giây sau show, trước `earned`) cũng không cho `earned=false`: log không có `earned`/`dismissed` nào, và khi mở lại, `AdManager singleton CREATED` xuất hiện với cùng PID — Dart state bị tạo lại, có cảnh báo memory pressure trước đó, và tôi dùng `am start` để mở lại. Nguyên nhân (OS tạo lại activity hay do thao tác test) chưa xác minh. Kết quả này không chứng minh SDK trả `earned=false` khi người dùng rời ad sớm, và không cho thấy SDK hỏng.
4. QA package uninstall khỏi owner profile thành công; log capture đã dừng. Log và ảnh đã lọc của lượt Pixel nằm trong bundle `evidence/hosted376_android_20261121/` (`pixel_*`); raw log chỉ ở `/tmp/pixel_qa376_*`.

**Thử đóng sớm bằng Close (Pixel, 2026-11-22, sau lượt Back/Home):** nút `Close` (content-desc `Close`) hiện trong uiautomator từ khoảng giây thứ 3 sau `shown`. Hai lượt: (a) kích hoạt tap bằng chính log, gửi ngay khi thấy `showRewarded [AdMob] shown`; (b) tap 4 giây sau `shown`. Cả hai lần log chỉ có `type=coins amount=10` và `onEarnedReward: result=true` khoảng 8 giây sau show, rồi `dismissed (earned=true)` sau khi tôi bấm Close lần cuối; không có `earned=false`. Trong cửa sổ trước thưởng, creative vẫn hiện và tap không rời ad. Chưa xác minh đây là hành vi của creative Google test hay do tap `adb input` không được ghi nhận; không kết luận SDK sai. Nhánh native `earned=false` vẫn chưa xác lập; log gốc chỉ ở `/tmp`, không đưa vào bundle.

**Logic SDK cho nhánh đóng sớm (fake bridge, không phải native):** `admob_behavioral_test.dart` và `r23_rewarded_interstitial_impression_test.dart` chạy 140/140 pass (2026-11-22). Chúng gồm: Rewarded và Rewarded Interstitial đóng trước khi nhận thưởng cho `earned=false`; ad đã hiện rồi đóng cho `shown=true, earned=false`; ad chưa lên màn hình cho `shown=false`. Mutation check trong bản copy cách ly (repo không đổi): đổi `if (!earned)` ở nhánh dismiss thành `if (false)` làm Rewarded fail 2 test và Rewarded Interstitial fail 1 test (`Expected: not null`, kết quả không được giao), nên test có thể đỏ. Phạm vi: chứng minh logic adapter khi bridge phát `onDismissed` mà chưa có reward, không chứng minh native ad thật gửi callback đó. Hai loại bằng chứng này khác nhau; nhánh native vẫn chưa xác lập.

### 4d. Pixel 7 Pro — consent accept, Privacy Options, withdraw (2026-11-22)

Hosted 3.7.6 debug QA build, package riêng, Google test ads, chạy từ example (không host pilot). Lần chạy sạch: xóa dữ liệu của chính package QA, log liên tục. Bằng chứng: `evidence/hosted376_android_20261121/pixel_consent_accept_withdraw.log` (lọc allowlist, không có hash/PID), `pixel_ump_eea_form.png`, `pixel_privacy_options_form.png`.

1. **Accept:** form EEA hiện, bấm `Consent`. Log: `status=obtained`, `formShown=true`, `applyConsent -> nonPersonalizedAds=false (hasUserConsent=true)`. PASS một thiết bị, một lần.
2. **Privacy Options:** mở từ màn Privacy settings của example, form UMP hiện lại. PASS.
3. **Withdraw:** bấm `Do not consent`. Log: TCF không cho personalization, `applyConsent -> nonPersonalizedAds=true (hasUserConsent=false)`, `discardCachedFullscreenAds` bỏ 4 ad đã cache, không crash (`FATAL EXCEPTION` = 0). Hướng an toàn đúng: bỏ ad cũ đã nạp dưới consent cũ.
4. **Quan sát, chưa kết luận là lỗi:** ngay sau withdraw, refill scan chạy nhưng cả 4 load bị `skipped - consent not granted (UMP)`; chỉ App Open nạp lại (~1s). Interstitial, Rewarded, Rewarded Interstitial nằm `idle` tới lần quét định kỳ 5 phút (`_retryIntervalMs`): lần chạy sạch withdraw 23:29:54 -> nạp lại 23:34:21 (~4,5 phút); lần chạy trước cùng ngày withdraw 23:23:42 -> nạp lại 23:27:40 (~4 phút). Hai lần cùng kết quả. Không có dòng `consent gate ... reopening` hay `gave up`. Hệ quả quan sát được: sau withdraw, các format fullscreen này có thể vắng tới ~5 phút. Hướng này mất doanh thu, không vi phạm consent. **Nguyên nhân đã tìm ra (2026-11-23), fix nằm trong `[Unreleased]`, chưa publish:** form dismiss kích một lifecycle resume khi apply consent còn chạy; resume bị bỏ qua rồi replay sau; refill của chính apply đã chạy khi gate còn đóng nên cả 4 load bị skip, và không gì refill lại tới lần quét 5 phút. Tái hiện được trong unit test (fake adapter, khớp thứ tự trên máy), fix 3 dòng gọi refill sau replay, 2 test chính đỏ khi bỏ fix và xanh khi có fix, full suite 2928/2928. Chưa kiểm lại trên máy thật sau fix, nên bằng chứng ở mức unit test, không phải device.
5. **Chưa chứng minh:** `npa=1` ở mức network; accept sau withdraw (vòng ngược); thiết bị khác ngoài Pixel; Privacy Options khi offline.

### 4e. Pixel 7 Pro — thử lại đóng sớm bằng Close X (2026-11-22, lượt 3) — KHÔNG hợp lệ

Cùng build hosted 3.7.6 ở 4d, Google test ad (nhãn "Quảng cáo thử nghiệm"), không tap creative/CTA. Hai lượt, **không lượt nào là một phép thử đóng sớm sạch**:

1. Lượt 1: uiautomator thấy `Close` lúc banner còn `... sau 1 giây` (`[1312,189][1400,273]`), nhưng tap Close chỉ được gửi sau khi tôi xem ảnh, tức sau khi reward đã cấp (`onEarnedReward` 23:37:45, `dismissed (earned=true)` 23:38:04). Đây là đóng sau reward, không phải đóng sớm.
2. Lượt 2: tap gửi ~1 giây sau ảnh chụp lúc banner còn `... sau 4 giây`. Ảnh đó (`pixel_close_x_countdown_4s.png`) chưa có nút X, nên không chứng minh tap trúng X. Ad không đóng, reward vẫn tới (`onEarnedReward` 23:38:43), đóng bằng lần tap sau (`dismissed (earned=true)`).

Kết luận: không thêm bằng chứng nào cho nhánh `earned=false` khi đóng sớm; vẫn như mục 4c (chỉ có fake-bridge). Muốn đóng giới hạn này cần người thử bấm X đúng lúc nó hiện, hoặc tự động hoá có xác nhận X đã hiện ngay trước khi tap (cùng một lệnh, không để agent xem ảnh xen giữa).

### 4f. Release / R8 build của example (2026-11-22)

`flutter build apk --release` từ bản copy hosted 3.7.6, package QA riêng, Google test ad unit, ký bằng debug key (example không có keystore release): build exit 0, APK 61,1MB, `mapping.txt` R8 được tạo. Cài lên Pixel, khởi động, không `FATAL EXCEPTION`/ANR.

**Chưa kiểm được ad dưới R8:** SDK chặn đúng thiết kế khi gặp Google test ad unit ở bản release (`canRequestAds` giữ false, log báo ad unit test trong RELEASE sẽ không phục vụ), nên load/show ad không chạy. Đây là bằng chứng guard hoạt động, không phải bằng chứng R8 không làm hỏng đường ad. Muốn kiểm R8 thật cần ad unit production (ngoài phạm vi: không dùng ID thật) hoặc cách khác được owner đồng ý. Ngoài ra là bản ký debug, không phải bản Play.

### 4g. Splash hard-cap 8s với form EEA chậm (2026-11-22)

Bản debug 3.7.6, **không** nâng cap lên 240s. Bằng chứng: `pixel_splash_cap_8s_eea_form.log`. UMP `required` lúc 23:29:07.660; splash cap 8s hết hạn lúc 23:29:14.304 và `REPLACE` về home (form còn mở, người thử chưa bấm); người thử bấm Consent lúc 23:29:19.246 -> `obtained`, SDK init `provider=admob` 23:29:19.313, `applyConsent hasUserConsent=true` 23:29:21. SDK init vẫn hoàn tất đúng sau khi cap đã hết. Một lần, form chờ người bấm (không giả lập mạng chậm); không có ad hiện đè lên form.

### 4h. Bảng PASS/FAIL/NOT RUN theo quickstart (2026-11-23, app example, KHÔNG phải host pilot)

Chạy trên **app example** (package QA riêng, Google test ads, Pixel 7 Pro, Android 17), không phải app host; owner đã chốt không dùng host pilot. Nguồn SDK: các mục 1-3 lấy từ lượt hosted 3.7.6 (mục 4a-4g). Các lần kiểm sau fix (withdraw refill, mạng, `clearSdkData`) dùng **source local** (commit `35c19ea`, path dependency), **không** phải hosted 3.7.6.

| Mục | Kết quả | Ghi chú |
|---|---|---|
| SDK version + source | PASS có điều kiện | hosted 3.7.6, SHA khớp (4a); lượt 2026-11-23 là source local, ghi rõ |
| 1 Test ads | PASS (một thiết bị) | Interstitial, Rewarded, Rewarded Interstitial, App Open load/show/dismiss; reward chỉ khi `earned=true`. Nhánh `earned=false` đóng sớm: NOT RUN (chưa quan sát native, 4c/4e) |
| 2 Consent | PASS (một thiết bị) | Consent, Do not consent, Privacy Options (4d). Sau withdraw, 4 slot nạp lại trong ~1,5 giây với source đã fix (`pixel_withdraw_refill_after_fix.log`); hosted 3.7.6 chậm ~4-4,5 phút. `npa=1` mức network: NOT RUN |
| 3 Nền → mở lại | PASS (quan sát) | App Open bỏ qua lần resume đầu (cold-start guard), lần sau mới hiện; chưa kiểm hết các điều kiện dialog/VIP/trial trên máy |
| 4 Mạng | PASS (quan sát, source local) | tắt/bật Wi-Fi và data: `network back online -> refilling ad slots`; chưa thử mạng di động riêng, chưa thử offline khi request đang bay |
| 5 Xóa dữ liệu | PASS một phần (source local) | `clearSdkData()` safe scope trả về bình thường, UI ghi `safe scope done`, không có `TimeoutException`. **Chưa đo thời gian** (lệnh đo bị treo), chưa seed key riêng của host để kiểm "còn nguyên" (NOT RUN). Nếu gặp `TimeoutException`: ghi **chưa xác nhận xóa**, không phải thành công; không gặp trong lượt này, nên đường timeout NOT RUN (cần storage treo thật) |
| 6 Build release | PASS một phần | build release exit 0 và R8 mapping sinh ra (4f); guard chặn test ad unit ở release hoạt động. Ad unit production, `app-ads.txt`, UMP message đúng app, signing Play: NOT RUN |

Log đã làm sạch: `evidence/hosted376_android_20261121/pixel_*`. Không có consent string, GAID hay hash thiết bị trong log lưu (đã kiểm regex 32 ký tự hex).

### 4i. Hosted 3.7.7 (2026-11-23): fix refill, `clearSdkData`, early-close

3.7.7 đã publish lên pub.dev (SHA-256 `7aab5d2d22cb7ae3c3129d77ad9f2e3c5ac1c8333913cba141a3f4e0deb38984`, khớp API và `pubspec.lock` `source: hosted`), tag `v3.7.7`. Kiểm trên Pixel 7 Pro, package QA riêng, Google test ads, bản **hosted 3.7.7** (không phải source local). Bằng chứng: `hosted377_pixel_withdraw_refill.log`.

1. **Fix refill: PASS (một thiết bị, một lần).** Sau `Do not consent`, `discardCachedFullscreenAds` bỏ 4 ad, cả 4 slot (App Open, Interstitial, Rewarded, Rewarded Interstitial) nạp lại thành công trong khoảng 1,4 giây (13.107 -> 14.513). Trước fix ở 3.7.6: ~4-4,5 phút.
2. **`clearSdkData()`: hoàn tất bình thường, 66 ms** (đo bằng `Stopwatch` trong bản copy của example, debug build, dữ liệu gần như trống). Không `TimeoutException`. Đây chỉ là đường thành công nhanh; đường timeout và key host còn nguyên vẫn **NOT RUN**.
3. **Early-close `earned=false`: vẫn NOT RUN, và lượt này không hợp lệ.** Lệnh tap lấy toạ độ từ node `Close` có bounds toàn màn hình (`[0,0][1440,3120]`), nên tap rơi vào giữa màn hình = **click nhầm vào creative của Google test ad** (log `click`, mở Google Play trang Google Ads). Không cài gì (kiểm package), đã quay lại và đóng bằng nút X thật sau khi reward đã cấp. Ghi nhận như một sự cố QA: vi phạm quy tắc "không chạm creative" mà owner đặt. Nguyên nhân là script tin node `Close` mà không kiểm tra bounds nhỏ; cần kiểm bounds trước khi tap ở các lần sau.

### 4j. Early-close có chốt an toàn, hosted 3.7.7 (2026-11-23)

Script chỉ tap khi node `Close` nhỏ hơn 300 px (thực tế 88x84) và log chưa có `onEarnedReward`, cả hai kiểm trong cùng một lệnh. Bằng chứng: `hosted377_pixel_early_close_guarded.log`.

Kết quả: tap Close lúc ~6,8 giây sau `shown`, trước reward. Ad **không đóng**, reward vẫn cấp 2 giây sau (`onEarnedReward` 10:20:18). Lần này không có click vào creative. Đây là lần thử hợp lệ thứ ba trở lên cho cùng một kết luận: với test creative video này, X trong countdown không kết thúc ad nên **không quan sát được `earned=false` trên native**. Nhánh đó chỉ có bằng chứng mức fake-bridge. Giữ NOT RUN; không thử thêm bằng adb trừ khi có creative khác.

## 5. Checklist host và QA tiếp theo

Chưa có host app pilot. Gates host, telemetry, stop criteria và rollback nằm ở nguồn chuẩn `host_pilot_quickstart_android_admob.md`, `pilot_checklist_android_admob.md` và `host_production_readiness_android_admob.md`; report này không sao chép lại để tránh lệch. Ghi mỗi gate `PASS`/`FAIL`/`NOT RUN`; không suy từ example.

Mọi lượt QA tiếp theo phải dùng thiết bị owner chọn, xác minh serial/model, package riêng, Google test IDs và hash UMP của chính thiết bị. Giữ log liên tục; trả lời test form trước deadline, tách thời gian người/ADB chờ khỏi thời gian xử lý. Nếu ad không rõ test labeling thì dừng, không tap creative/CTA. Trước show phải có consent gate mở, init/load success và slot ready; không bypass safety để ép show. Sau lượt kiểm lại cleanup đúng user/profile, không suy sang profile khác.

### Kế hoạch từ example sang host pilot

Không tạo checklist thứ hai. Bảng dưới chỉ đối chiếu 7 mục của `host_production_readiness_android_admob.md` mục 1 với bằng chứng example hiện có, để host biết việc nào phải làm từ đầu. Mọi mục đều `NOT RUN` trên host vì chưa có host app.

| Gate (nguồn chuẩn) | Example đã chứng minh một phần | Host phải làm |
|---|---|---|
| Release đã duyệt | Hosted 3.7.6, `source: hosted`, SHA-256 khớp archive pub.dev | Ghi version/lockfile của host, không dựa vào example |
| App/publisher ownership | Không (example dùng Google test IDs) | Package, AdMob App ID, ad unit, `app-ads.txt`, UMP message, privacy URL thật |
| Build thật | Chỉ debug; Gradle cần JDK 17 | Release-signed, R8, upgrade và rollback; chặn Google test IDs |
| Consent | UMP refusal, TCF mapping, `nonPersonalizedAds=true` trên 3 thiết bị; chưa chạy accept/withdrawal/Privacy Options trên 3.7.6 | Chạy đủ accept/refuse/withdrawal trên app thật, đúng thị trường |
| Ad UX | Interstitial, Rewarded, Rewarded Interstitial (disclosure accept và Cancel) trên test ads | Duyệt placement, App Open với dialog/VIP, SSV nếu dùng |
| Host handling | Không | `clearSdkData()` timeout hiển thị "chưa xác nhận xóa" |
| Pilot sign-off | Không | Chạy quickstart trên build release-shaped, owner ký từng `NOT RUN` |

Thứ tự đề xuất: (1) chốt host app và ownership; (2) dựng build release-shaped với test ads; (3) chạy quickstart sáu bước và ghi PASS/FAIL/NOT RUN; (4) chạy consent đủ nhánh ở EEA debug; (5) chốt telemetry, ngưỡng và rollback; (6) ký nhận. Chỉ bước 1 cần quyết định của owner trước khi làm tiếp.

## 6. Nguồn đối chiếu

- `doc/audit/audit_round79_full_sdk.md` — historical source/device evidence, chủ yếu 3.7.0/3.7.1.
- `doc/audit/pilot_checklist_android_admob.md`, `host_pilot_quickstart_android_admob.md`, `host_production_readiness_android_admob.md` — host gates, telemetry, rollout/rollback.
- `doc/audit/audit_round44_consolidated.md` — historical consent findings, không thay thế xác minh hiện hành.
- `packages/ad_sdk/doc/task/inprogress/T256-admob-age-treatment-api-migration.md` — iPhone physical consent check còn deferred.
- `packages/ad_sdk/doc/task/done/T283-hosted-package-partner-smoke.md` — hosted 3.7.1 consumer evidence.
- `packages/ad_sdk/lib/src/core/{ad_manager,ad_consent,ump_consent,iab_storage,ad_screen}.dart` — orchestration/consent/show guards.
- `packages/ad_sdk/lib/src/adapters/{admob_adapter,gma_bridge}.dart` — init, per-request NPA và native bridge.
- `packages/ad_sdk/lib/src/consent/consent_fallback.dart` và tests liên quan — conservative fallback.
- `packages/ad_sdk/test/{npa_consent_wiring,admob_behavioral,tcf_personalisation_consent,r44_set_do_not_sell_pre_init,r44_applovin_tcf_gate,r73_set_do_not_sell_keeps_admob_request_config}_test.dart` — regression coverage.
- `packages/ad_sdk/lib/src/vip/{_first_install_guard,signed_vip_key,vip_manager,_redeemed_key_ledger,vip_revocation_provider}.dart` — trial/AVP2/ledger/CRL.
- `packages/ad_sdk/doc/task/done/T267-flutter-android-present-frame-attribution.md` — T267 đóng ở mức không đo được.
- Pub.dev metadata: `https://pub.dev/api/packages/applovin_admob_sdk`.
- Evidence đã lọc: [`evidence/hosted376_android_20261121/manifest.json`](evidence/hosted376_android_20261121/manifest.json) — callback logs, ảnh test/disclosure/kết quả và SHA-256; raw evidence và consumer copy/lockfile chỉ ở `/tmp`.

## 7. Verdict

**Android + AdMob: có thể mở closed pilot có điều kiện khi đủ host gates và owner sign-off — đây không phải bằng chứng rằng example đã đủ cho pilot; hiện chưa GO production rollout. iOS/AppLovin: NO-GO production rollout tới khi có native-device/host verification phù hợp.**

No-go nếu host consent/legal basis chưa xác nhận, request trước consent, ad đè dialog/VIP, reward sai, policy/invalid-traffic warning, crash/ANR tăng hoặc thiếu rollback. Đây là verdict theo evidence, không phải khẳng định SDK không thể dùng production hay chứng nhận pháp lý.

**Cập nhật 2026-11-22 (chỉ app example, không host pilot):** accept, Privacy Options và withdraw chạy đúng hướng an toàn trên một Pixel (4d); sau withdraw, Interstitial/Rewarded/Rewarded Interstitial có thể vắng tới ~4-5 phút (mất doanh thu, không vi phạm consent). Nhánh `earned=false` khi đóng sớm vẫn chưa quan sát được trên native (4c, 4e). Ad dưới R8 chưa kiểm vì guard release chặn test ad unit (4f). Splash cap 8s không cản init sau form chậm, một lần thử (4g). Không cái nào đổi verdict.
