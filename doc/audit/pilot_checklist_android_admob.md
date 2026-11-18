# Checklist closed pilot — Android + AdMob (host app)

- **Rà soát:** 2026-11-18
- **Áp dụng cho:** Android + AdMob. Host phải pin đúng bản SDK đã được release owner phê duyệt; version/source metadata trong checkout không tự chứng minh bản đó đã publish hoặc host đang dùng nó.
- **Thay thế:** mục 7 của `audit_round78_android_admob.md` (ghi pub.dev 3.6.8 và 3.7.0 draft, đã lỗi thời).
- **Phạm vi:** Android + AdMob. iOS và AppLovin MAX **không** nằm trong checklist này.
- **Trạng thái:** chưa có host app nào được kiểm tra; không có ad unit production nào được dùng. Checklist là điều kiện cần trước khi chạy pilot, **không** phải kết quả pilot.

## Trạng thái evidence

Đánh dấu từng gate theo một trong ba mức:

- **Đã kiểm chứng trong repo/example:** source review, unit/widget tests hoặc Android test-ad smoke; không mặc định áp dụng cho host app.
- **Host/publisher phải xác nhận:** cấu hình package thật, console/domain, release signing/obfuscation, policy, telemetry và rollback.
- **Chưa có evidence:** chưa chạy trên host app thật hoặc test cần môi trường/native platform chưa có.

Không đổi mục host/device sang “pass” chỉ vì SDK unit test/example smoke pass.

## Ma trận trạng thái evidence (2026-11-17)

| Trạng thái | Hạng mục | Bằng chứng/owner |
|---|---|---|
| **Đã kiểm chứng trong SDK repo** | Release test-ID guard; consent gate đến GMA bridge; example dùng Kotlin Gradle Plugin 2.3.0+ và `minSdk` 24. | Source/unit tests và example config. Không chứng minh cấu hình host. |
| **Đã kiểm chứng bằng example/disposable app** | Android AdMob test ads, UMP EEA trên TECNO, T281 native paid event 3/3, Banner/MREC/Native smoke. | Chỉ package/test IDs/thiết bị ghi trong evidence; không phải production host. T281 fullscreen follow-up: App Open inconclusive, Interstitial shown/impression nhưng dismiss chưa xác minh. |
| **Host/publisher phải xác nhận** | SDK source/version đã được duyệt; App ID/ad units; app-ads.txt; UMP message/privacy policy; signing/R8; trial policy; telemetry/rollback; actual host consent/ad gate. | Owner evidence từ host app/build/console. SDK repo không thể xác nhận. |
| **Chưa có evidence** | Host closed pilot, release ad serving/config correctness, crash/ANR/fill/revenue trend trên host. | Chưa chạy host app thật; không đánh dấu pilot-ready. |
| **Không đo được hiện tại** | T267 app-layer frame presentation trên Android. | Các phương pháp đã thử không gắn được presentation frame với Flutter SurfaceView; không đưa ra FPS pass. |

## Giới hạn của bằng chứng hiện có (đọc trước)

Round 79 và các follow-up chỉ kiểm tra **example/disposable consumer app** với Google test ads:

| Đã có bằng chứng | Thiết bị | Ghi chú |
|---|---|---|
| Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial, App Open hiển thị | Pixel 7 Pro | Test ads; ảnh + log trong `evidence/round79_pixel/` |
| UMP EEA: form hiện, Consent và Do not consent đều ghi trạng thái và cờ NPA đúng | TECNO KJ7 | Test geography EEA; ảnh + 2 log trong `evidence/round79_tecno/` |
| Wi‑Fi tắt/bật thật, SDK nối lại mạng | TECNO KJ7 | Offline: không request mới (`no network`, `_initMrec offline`); bật lại: `network back online -> refilling ad slots` và MREC tải lại ~4 giây. Một lần chạy, chỉ Wi‑Fi (không thử mạng di động/captive portal); ảnh + log trong `evidence/round79_tecno_manual/screens7/` |
| Quảng cáo trong vòng đời VIP: xem rewarded -> VIP 3 ngày, ad bị chặn khi VIP, gỡ VIP thì ad lại tải | TECNO KJ7 | Test ads, log liên tục; `evidence/round79_tecno_manual/screens4/` |
| Adaptive surface nhánh MREC (>=600pt) | TECNO KJ7 | Chạy bằng `wm density 240` (giả lập, đã khôi phục), không phải màn rộng thật; `screens6/` |
| Key VIP ký (AVP1 demo, AVP2: hết hạn/sai bundle/đúng bundle/dùng lại/không ràng bundle) và CRL thu hồi | TECNO KJ7 + S24U | Dùng cặp khóa tạm và gói tạm (đã gỡ), không phải key của owner; CRL chỉ được nạp từ provider giả lập trong example, chưa qua mạng thật; `screens5/`, `screens8/`, `screens9/` |
| Privacy Options đổi consent sau khi đã từ chối | TECNO KJ7 | Lần 2 (adb bấm nút, không phải người): từ chối -> Privacy Options -> Consent hoàn tất trong ~19 giây, `nonPersonalizedAds` true -> false, không timeout. Lần 1 không ai bấm: timeout 180 giây rồi nhả chặn sau 15 phút. Một máy, một lần chạy thành công; `evidence/round79_tecno_manual/t278/` |
| Consent đã lưu thì form không hiện lại | TECNO KJ7 | Gọi trực tiếp luồng UMP, không qua UI đầy đủ |

Chưa có bằng chứng: host app thật, ad unit production, consent trên thiết bị người dùng thật, native memory, FPS/presentation (T267 đóng: không đo được bằng các cách đã thử), iOS, AppLovin. Chưa thử thêm: CRL qua CA công khai thật/mạng di động, phản hồi chậm hoặc cụt, đổi đồng hồ khi app đang chạy, key AVP2 ký bằng khóa thật của owner. (CRL qua HTTPS với CA tạm ghim chứng chỉ trên TECNO: chứng chỉ giả mạo bị từ chối, SDK giữ CRL cũ, xem `screens13/`. CRL tải qua HTTP trong mạng LAN từ server tạm đã thử trên S24U: áp dụng được, cập nhật được, và lỗi mạng thì SDK giữ CRL cũ; xem `screens12/`.) (Đã thử trên S24U, đạt: CRL còn hiệu lực sau khi khởi động lại app, redeem bị từ chối khi offline, VIP vẫn chặn quảng cáo khi offline, đồng hồ lệch -1 ngày/+2 ngày, xem `screens11/`.) (CRL cũ bị phát lại và CRL ký sai khóa đã được thử trên S24U, bị từ chối đúng, xem `screens10/`.)

## A. Trước khi cài bản pilot

- [ ] Dependency trỏ tới bản **đã publish và được release owner duyệt** của `applovin_admob_sdk`; xác nhận source/version trong lockfile và không dùng git/path dependency chưa qua quy trình release.
- [ ] Làm theo `doc/AD_PROMPT_FLUTTER.MD` của đúng version đang pin, bắt đầu từ mục "Start here — numbered walkthrough" (không copy cấu hình từ bản cũ).
- [ ] Kotlin Gradle Plugin `>= 2.3.0` (cần cho `google_mobile_ads 9.2.x`); `kotlinOptions { jvmTarget }` đã chuyển sang `kotlin { compilerOptions { ... } }`.
- [ ] `minSdk >= 24`; AdMob `APPLICATION_ID` trong manifest đúng app/publisher.
- [ ] **Test ad unit IDs của Google không nằm trong cấu hình release** (SDK sẽ chặn request ở release; vẫn phải kiểm tra bằng build release thật).
- [ ] Ad unit ID, `app-ads.txt` và UMP message thuộc đúng app/publisher; do owner xác nhận, SDK không tự kiểm được.
- [ ] Quyết định có bật trial 24h hay không: mặc định release là `FirstInstallVipGrace.auto`; nếu chưa được duyệt, đặt `FirstInstallVipGrace.disabled`.
- [ ] R8/ProGuard và signing do host kiểm tra bằng bản release.

## B. Consent (UMP)

- [ ] UMP là consent owner duy nhất; chạy mỗi lần mở app trước khi request ad.
- [ ] Có mục **Privacy Options** dễ tìm khi UMP yêu cầu (example đã có mẫu).
- [ ] **Automated SDK boundary:** `consent_gate_test.dart` verifies a closed `AdManager` gate makes zero GMA bridge load calls and an open gate makes one. The fake bridge proves only the Dart boundary; it does not prove a native GMA request, network transmission, Google receipt, or fill.
- [ ] **Host/device EEA verification (still required):** on a test device, use EEA `DebugGeography` and manually exercise Consent, Do not consent, and Privacy Options. Capture UMP outcome, relevant IAB state, request/no-request observations, and test-ad result for the host app. Existing `ump_eea_consent_test.dart` covers only an already-obtained decision, form suppression, open `canRequestAds`, and non-empty TCF; it does not drive the form or observe an ad request.
- [ ] Ghi nhận: `canRequestAds=true` sau khi từ chối nghĩa là ad **không cá nhân hoá** (`nonPersonalizedAds=true`), không phải không có ad.
- [ ] Chính sách quyền riêng tư mở được từ app. Trách nhiệm pháp lý theo từng thị trường thuộc publisher, không thuộc SDK.

## C. Hành vi quảng cáo (dùng test ads / test device trước)

- [ ] Mỗi format host dùng: load → show → dismiss → không crash. Với reward: chỉ cấp khi callback `earned=true`.
- [ ] Giữ safety gate mặc định; `bypassSafety` chỉ cho App Open ở splash như tài liệu.
- [ ] Mất mạng thật (tắt Wi‑Fi): không request mới; mạng về thì tải lại. Example đã được thử một lần trên TECNO (log trong repo, xem bảng trên); host phải tự kiểm lại trên app và thiết bị của mình, kể cả mạng di động.
- [ ] Đưa app xuống nền rồi mở lại: App Open không chồng lên dialog; không hiện ad khi VIP/trial đang hoạt động.
- [ ] Banner/MREC trong `IndexedStack` dùng `active:` hoặc `Visibility(maintainState: true)` (xem README).

## C2. Xóa dữ liệu và timeout — host phải kiểm lại

- [ ] Ghi SDK version/source từ lockfile host và build đang thử; dùng bản đã được release owner phê duyệt, không suy ra từ version trong repo.
- [ ] Seed một key riêng của host và dữ liệu SDK tổng hợp; gọi `await AdManager().clearSdkData()`. Sau thành công, key host còn nguyên; các key SDK trong scope và Flight Recorder cũ không còn sau khởi động lại. Không dùng dữ liệu cá nhân thật làm fixture.
- [ ] VIP và consent provenance giữ nguyên với scope mặc định. Chỉ thử xóa entitlement trong môi trường disposable có xác nhận rõ; không xóa quyền lợi khách hàng thật.
- [ ] Host bắt `TimeoutException` sau 30 giây: hiển thị **chưa xác nhận xóa**, không báo thành công. Cleanup vẫn đang chờ/chạy; Flight Recorder bỏ event đến trong khoảng này và chỉ mở lại khi cleanup kết thúc. Nếu storage treo mãi, recording dừng tới khi app khởi động lại; retry cũng xếp sau thao tác đang kẹt.
- [ ] Phân biệt timeout/error với success trong telemetry host, không ghi nội dung evidence/consent. Log lỗi muộn phụ thuộc level/tag filter của `SafeLogger`, không thay thế xác nhận kết quả xóa.
- [ ] Kiểm host resume/dialog/VIP sau khi xóa và ghi lại kết quả. Lỗi storage được tạo bằng fake trong SDK tests; smoke thiết bị bình thường không chứng minh đường timeout thật.

Repo evidence (2026-11-18): `t200_clear_sdk_data_test.dart` pass 2 test trên TECNO KJ7 với gói cách ly, kiểm scope/key host và secure storage thật; không phải host pilot. Bộ test recorder kiểm thứ tự write/remove và caller timeout bằng backend điều khiển được. Host vẫn phải chạy checklist trên app/build của mình.

## D. Tiêu chí dừng ngay (no‑go)

Dừng pilot nếu gặp bất kỳ điều nào:

- Crash/ANR tăng rõ so với bản không có ad.
- Ad hiện khi VIP/trial đang hoạt động.
- Ad request khi chưa có consent hợp lệ ở thị trường cần UMP.
- Cảnh báo policy hoặc invalid traffic từ AdMob; click nhầm do vị trí đặt ad.
- Reward được cấp khi `earned=false`.

Ngưỡng cụ thể (số người, số ngày) do chủ sản phẩm chọn; đây không phải tiêu chuẩn của Google.

## E. Theo dõi trong pilot

- Tỉ lệ fill, lỗi tải, impression, doanh thu; crash/ANR; rút consent qua Privacy Options.
- Chỉ thu telemetry tối thiểu; không log GAID, ad unit hoặc consent string thô ngoài quy trình QA được duyệt.
- Cohort nhỏ, vài ngày. Có đường lùi: pin về version trước và tắt ad serving từ host/console (pub.dev không rút được bản đã publish).

## F. Giới hạn đã được chủ sản phẩm chấp nhận (không phải lỗi)

- Mã VIP khuyến mãi không phải giấy phép single-use toàn cầu; kích hoạt cần mạng, sau đó dùng offline.
- Trial Android chỉ chống cài lại theo kiểu best-effort (qua Auto Backup); xoá dữ liệu entitlement có thể cấp lại trial.
- Khôi phục backup Android có thể giữ dấu "đã dùng mã" nhưng mất grant VIP.

## F2. App Open follow-up — TECNO, 2026-11-18

`example/integration_test/app_open_ad_test.dart` đã chạy với test siết assertion trên bản copy cách ly `/tmp/t281-tecno-qa/example`, SDK source lib đồng nhất checkout `e773c76`, package `com.roy.admobwrapper.t281qa`, TECNO KJ7 Android 14. Hai chu kỳ đều có native display confirmation, impression, dismiss thật và callback đúng một lần; `All tests passed` sau 00:59. Không dùng `bypassSafety`; test đợi safety mở trước show thứ hai. Mỗi lần đóng đều xem screenshot và xác nhận foreground là AdActivity của package cách ly trước khi adb tap **Continue to app**; không tap creative/Install. Host `com.roy.admobwrapper` không bị thay thế/xóa; harness chỉ gỡ package cách ly.

Nguyên nhân harness cũ: chờ tile App Open ngoài vùng dựng của ListView trước khi cuộn. Đổi tín hiệu Home sang tile đầu (`Banner ad`) rồi cuộn giải quyết được. Run trung gian chỉ show/dismiss một lần: lần hai bị throttle nhưng test cũ vẫn PASS; không dùng run đó làm bằng chứng hai chu kỳ. Test mới bắt buộc fill, display và dismiss ở cả hai lượt.

Evidence lưu tại `doc/audit/evidence/appopen_tecno_20261118/`. Sáu log đã che đường dẫn home của máy dev (`<home>`); hash bên dưới là hash của **bản đã che** (ảnh giữ nguyên). Bản gốc chưa che nằm trong archive ngoài repo, SHA-256 `b14fdab2a884baad87b2f11bef4aa6022b50106cf78c3b32e45f8150f09452d2`. Các tên `/tmp` là tên file gốc:

- `/tmp/appopen-strict.log` — SHA-256 `d4f3062125d01c4b0e00ffe480613eb7f5a914806a4ac96d10a91999637983d5`.
- `/tmp/appopen-strict1-ready.png` — SHA-256 `38e87c8d9facbb6d38f66eea2abdc8afcefc09ab1bc94350cf9aeeeea2bab249`.
- `/tmp/appopen-strict2.png` — SHA-256 `7b56cfa8958246d47e2abc415397e0191b494124e7f94c94c872fbebeed5ab5b`.

Giới hạn: một máy, debug/example, Google test inventory, show trực tiếp qua public API và đóng thủ công qua adb. Không chứng minh production/release, pub.dev consumer resolution, App Open tự động khi resume/splash, iOS/AppLovin hay race callback muộn.

### Resume tự động và màn nhạy cảm — follow-up 2026-11-18

`example/integration_test/t262_sensitive_real_appopen_test.dart` chạy trên cùng gói TECNO cách ly với `T262_HOST_LIFECYCLE=true`. Driver dùng adb Home, chờ 6 giây rồi relaunch package thật; không gọi lifecycle giả. Màn `AdSensitiveScreen` chặn ad khi slot đã ready (`sensitive_block_confirmed`). Sau khi về màn thường, resume đầu bị cold-start guard chủ ý bỏ qua; thêm một vòng Home/relaunch thì SDK tự chạy buffer, native shown/impression/dismiss và test pass sau 01:16. Đóng bằng **Continue to app**, đã xem screenshot và xác nhận foreground AdActivity cách ly trước tap; không tap creative/Install.

Run đầu fail vì chỉ có một vòng resume ở màn thường, chưa tiêu thụ cold-start skip; giữ log fail để phân biệt lỗi kịch bản với lỗi SDK. Hướng dẫn test được bổ sung vòng cold-start, không tắt guard. File evidence local cùng thư mục ở trên:

- `appopen-resume-t262.log` (run đầu fail) — SHA-256 `f13a25e4cc00482e46dbefc7e3cc8b2a36a18489b6ffcb2c6347ce6ba0cf29bb`.
- `appopen-resume-t262-retry.log` (run pass) — SHA-256 `7144ad5a95cbaaa4a03912ffd5c0789b5c6fcfe6114986216cdec39554b8f006`.
- `appopen-resume-t262-retry.png` — SHA-256 `a909a39c59a0b86c8d2a4c72375d32ef1438d50ca5d28ea4d26c11cb363014ed`.

Bằng chứng này bổ sung một resume tự động và nhánh màn nhạy cảm trên example/debug/Google test ads, không mở rộng thành host pilot hoặc production. Nhánh dialog/VIP không nằm trong run T262; được kiểm riêng bên dưới.

### Resume thật khi dialog/VIP — follow-up 2026-11-18

`appopen_real_resume_guards_test.dart` chạy với `HOST_RESUME_GUARDS=true` trên gói TECNO cách ly. Driver Home/relaunch sau từng marker, ở nền 6 giây; không gọi lifecycle giả. Review độc lập chỉ ra run đầu có thể pass giả vì cold-start guard chưa bị tiêu thụ trước probe dialog. Test được sửa: một resume thật tiêu thụ cold-start trước (`cold_start_consumed`), sau đó resume khi dialog mở bị `a dialog/popup is on top` chặn, resume khi VIP active bị `VIP member` chặn, rồi sau khi đóng dialog và revoke VIP tổng hợp thì resume tiếp theo tự hiện native ad, impression, dismiss và đúng một successful show event. Runner pass 01:07. Native close là **Continue to app**, chỉ tap sau screenshot và kiểm foreground AdActivity cách ly; host package không bị chạm.

Kiểm test có thể đỏ: trong bản copy cách ly (không phải `lib/` của repo) gỡ cả hai cổng `_fullscreenBusyReason` ở đường resume và `showAppOpenAd`; run mutant để ad hiện đè lên dialog trên thiết bị (`AdActivity` foreground) và test fail đúng ở assertion dialog (`appOpenSlot.isReady`, dòng 96 của test, vì ad đã bị show). Run mutant một cổng (chỉ gỡ cổng ở đường resume) vẫn bị cổng thứ hai trong `showAppOpenAd` chặn (`showAppOpen skipped — a dialog/popup is on top`), rồi test dừng sớm ở bước VIP với lỗi `real VIP resume` do harness; không dùng run đó làm bằng chứng cho cổng đơn lẻ và không lưu artifact của nó. Bản copy cách ly đã khôi phục giống `lib/` repo.

Evidence cùng thư mục (log đã che; run đầu `appopen-resume-guards.*` giữ làm lịch sử, không phải run cuối):

- `appopen-resume-guards2.log` (run cuối pass) — SHA-256 `a50f7f3bbd16eb4ecec733898bf5f8d3c1068d23898a70344ec7bbb58dd020f4`.
- `appopen-resume-guards2.png` — SHA-256 `e9253355e210762a2c9148bf0ab615dc47f02d349fd1fdb1118bb69950a25c06`.
- `appopen-resume-guards-mutant2.log` (mutant hai cổng, fail) — SHA-256 `10fb46db12390946b2b44b43ffd7ba8fabb347b1114f0ad242f8e229f3143354`.
- `appopen-mutant2.png` (ad đè lên dialog trong mutant) — SHA-256 `248457dc9e681482679bcc09f1c7bb688bb1650a6cf5bf38d9fe3b9d1ee572a6`.
- `appopen-resume-guards.log` / `.png` (run đầu, trước khi tiêu thụ cold-start) — SHA-256 `971328ccd6ac7921a1f40a1e051b181daf28c1333f5a81141bce3999c1078c99` / `da80f46341f6913b7f71e7d2e3a7ca8f7a9d5bfb2b3dbcccb5e3eba41665258b`.

Giới hạn: một máy, debug/example, Google test ads và VIP entry tổng hợp; không chứng minh production release, quyền VIP trả phí, iOS/AppLovin hoặc mọi thứ tự cạnh tranh lifecycle. Dialog được kiểm khi ad ready; VIP có thể tự giải phóng ad, nên không suy ra VIP vẫn giữ creative trong cache.

## G. Khoảng trống còn mở

- Pilot trên host app thật chưa chạy.
- T267 (frame/presentation) đã đóng ở mức "không đo được" (Macrobenchmark, Perfetto/SurfaceFlinger và JankData đều không cho frame hiển thị của Flutter SurfaceView trên Pixel 7 Pro, TECNO, S24U): không có số FPS hiển thị, chỉ có thời gian engine. T257 (60 fps toàn app) vẫn chưa đạt.
- iPhone thật (ATT + UMP + AdMob) và AppLovin chưa được kiểm tra.
- Bốn kết luận trên không thay thế review pháp lý/consent của publisher.
