# Audit round 34 consolidated — applovin_admob_sdk 2.9.15

Ngày: 2026-09-03. Bối cảnh: audit toàn diện theo yêu cầu chủ dự án, đối chiếu với
version publish trên pub.dev (2.9.15, khớp đúng local, published "in the last
hour" tại thời điểm audit). Sau 33 vòng audit trước, vòng này chạy độc lập
nhiều agent + tự orchestrator verify lại từng finding gây tranh cãi bằng cách
đọc source thật, không chỉ tin báo cáo của agent nào.

## Agent đã dùng và agent không dùng được

| Công cụ | Kết quả |
|---|---|
| Codex (`gpt-5.6-sol`, `codex exec --dangerously-bypass-approvals-and-sandbox`) | Hoàn thành, có lần vào source thật `applovin_max-4.6.4` trong pub-cache để verify. Hết usage limit ngay sau khi ghi xong report (không ảnh hưởng report). |
| Claude (headless, `claude -p --dangerously-skip-permissions`) | Hoàn thành, chạy `flutter analyze`/`flutter test` thật (1571/1571 pass), tự tay giải mã bit GPP để verify round-33 fix. |
| Gemini CLI (`gemini -y -p`) | **Không dùng được** — tài khoản free tier bị chặn (`IneligibleTierError`, Google yêu cầu chuyển sang Antigravity). |
| agy (`agy --dangerously-skip-permissions`) | **Không dùng được** — chưa đăng nhập trong môi trường này (`authentication required`). |

Chỉ 2/4 công cụ độc lập chạy được vòng này. Điều này tự nó là một giới hạn của
báo cáo — ít hơn round 33 (3 agent).

## Hai agent ra hai verdict khác nhau — như mọi round trước

| Agent | BLOCKER | MAJOR | Verdict |
|---|---|---|---|
| Codex | 1 | 5 | **Không approve nguyên trạng** |
| Claude (headless) | 0 | 0 (+ 1 finding mới MINOR-MAJOR) | **Dùng được cho production, kèm điều kiện** |

Đọc kỹ cả 6 finding của Codex thì thấy **5/6 không phải phát hiện mới** — chúng
là các giới hạn đã được audit trước đó (round 29/32/33) tìm ra, cân nhắc, và
**chủ động quyết định không sửa** vì lý do kiến trúc (không backend) hoặc giới
hạn dependency, rồi ghi thẳng vào README "Known limitations" / CLAUDE.md thay
vì giấu đi. Codex không đọc phần "Known limitations" của README trước khi kết
luận "BLOCKER", nên đánh giá đúng cơ chế nhưng sai về tính mới/mức độ khẩn cấp.

## Tự verify từng finding (đọc source thật, không tin báo cáo nào)

### Đã xác nhận: không mới, đã công bố, đã quyết định từ trước — không cần hành động thêm

- **R34-01 (Codex, BLOCKER) — trial/VIP Android bypass qua uninstall/reinstall**:
  cơ chế đúng 100% (`FirstInstallGuard` không có backstop trên Android, dựa vào
  Auto Backup best-effort). Nhưng README.md dòng 61-71 ("VIP anti-bypass is
  durable on iOS, weak on Android") đã công khai **chính xác** kịch bản này từ
  trước, kèm khuyến nghị dùng AVP2 với `--valid-days` ngắn. Không phải lỗ hổng
  ẩn — là tradeoff đã cân nhắc cho một SDK cố tình không có backend.
- **R34-02 (Codex, MAJOR) — key hợp lệ không one-time toàn cầu, AVP1 không có
  expiry/app-binding**: đúng cơ chế, đã công bố ở README dòng 72-81 ("A leaked
  key is a leaked key — mitigated, not eliminated"). AVP1 giữ lại có chủ đích
  (backward-compat cho key đã phát hành trước AVP2), có đường nâng cấp
  (`refreshRevocationList`).
- **R34-04 (Codex, MAJOR) — AppLovin consent setter fire-and-forget, không
  await được**: chính là R33-01 đã tìm thấy round 33, quyết định **không sửa
  code** (giới hạn API `void` của dependency `applovin_max`, không phải bug
  phía SDK này), ghi vào README dòng 111-121. Codex tự lần vào
  `applovin_max-4.6.4/lib/applovin_max.dart:191-210` xác nhận đúng — verify
  chất lượng tốt, nhưng đây là round thứ 2 liên tiếp tìm lại đúng finding này.
- **R34-05 (Codex, MAJOR) — `bypassSafety` không có enforcement thật**: đọc
  `ad_manager.dart:5910-5926` — chính comment tại chỗ ghi rõ đây là "round-32
  audit — flagged again as a footgun risk, kept as a public param by design"
  kèm `bypassAuditTrail` (audit-trail sau sự kiện, không phải enforcement,
  đúng như Codex mô tả) được thêm **vì đã biết** giới hạn này. Không mới.

Bài học lặp lại từ round 32/33 ([[audit-must-be-slow-and-adversarial]],
[[vip-offline-gate-and-qa-hashes-are-features]]): agent audit mới luôn có xu
hướng tái phát hiện các tradeoff đã cân nhắc kỹ và công bố công khai, gắn nhãn
BLOCKER/MAJOR như thể chưa ai biết. Giá trị thật của các agent này nằm ở việc
**verify lại cơ chế còn đúng không sau các lần sửa gần đây** (nó đúng), không
phải ở tính mới của finding.

### Xác nhận MỚI và THẬT — cần xử lý

**F1 (MAJOR, docs) — README nói sai về mức độ hỗ trợ GPP sau round 33.**
`README.md:1928-1934` ("CCPA / US state privacy") vẫn viết *"The GPP string is
not decoded... exposed raw and nothing more"* — đúng ở bản 2.9.13 trở về
trước, nhưng round 33 (2.9.15) đã thêm `IabStorage._gppUsNationalOptedOut()`
(`lib/src/core/iab_storage.dart:229-247`) giải mã một phần section US National
của GPP. Tài liệu hiện **không khớp code**, gây hiểu lầm cho người tích hợp
hoặc reviewer pháp lý về phạm vi thật.

Đối chiếu source (đã tự verify bằng tay ở round này, khớp round-33 report):
code chỉ đọc 2 field `SaleOptOut`/`SharingOptOut` trong Core Segment US
National, **không đọc** `TargetedAdvertisingOptOut` (field ngay kế bên, có
tên trong chính doc-comment của hàm) và **không đọc bất kỳ section theo bang
nào** (California, Colorado, Virginia, Connecticut...) dù các bang đó có
quyền "opt out of targeted advertising" tách biệt với "opt out of sale". Đây
là giới hạn *có chủ đích* (comment: "mis-parsing a privacy signal is worse
than not reading one") — hợp lý về mặt kỹ thuật, nhưng README cần nói đúng
phạm vi hiện tại thay vì câu cũ đã lỗi thời.

**F2 (MAJOR, config mặc định) — App mẫu ghi đè default an toàn, log raw GAID
ở release.** SDK core đã tự sửa "N1: unsafe-by-default logging footgun" —
default hiện tại đúng là
`logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning`
(`ad_config.dart:392`). Nhưng `example/lib/main.dart:264` **ép cứng**
`logLevel: AdLogLevel.verbose` không điều kiện `kDebugMode`. Vì
`SafeLogger.d(_tag, () => 'GAID=$_currentDeviceGAID')`
(`ad_manager.dart:2230`) log raw advertising ID ở mức verbose, build **release**
của app mẫu vẫn in raw GAID vào `LogBuffer`. App mẫu là template tích hợp
chính thức (README dẫn người dùng đọc nó) — rủi ro copy-paste nguyên cấu hình
này vào app thật là có thật.

**F3 (MINOR-MAJOR, git hygiene, ngoài phạm vi code SDK) — khoá ký Play App
Signing từng bị commit vào git history.** Xác nhận bằng
`git cat-file -p 60a1f3d:android/app/private_key.pepk` (commit `60a1f3d`,
2024-12-20, message "up") — blob PEPK thật, hiện không còn trong HEAD nhưng
vẫn lấy được nguyên vẹn qua lịch sử. File là bản mã hoá bằng public key của
Google (định dạng PEPK upload key cho Play App Signing) nên bản thân nó
**không** cho phép ký app ngay nếu không có private key phía Google — rủi ro
phụ thuộc việc repo có từng/sắp public hay thêm collaborator không tin cậy
hay không. Đây là tàn dư từ thời host app còn sống chung repo (theo CLAUDE.md,
nay đã tách riêng) — không phải lỗi của package `ad_sdk`, nhưng cùng git
history nên vẫn là rủi ro thật của **repo này**.

## Các trục đã audit và xác nhận ổn (không lặp lại chi tiết — xem 2 báo cáo gốc)

Dual-provider Android/iOS không lệch logic tầng Dart; connectivity watch có
generation-token chống leak, mọi Timer/Subscription có điểm huỷ tương ứng
(verify chéo bằng grep từng field, không chỉ đọc tên hàm); VIP Ed25519 domain
-separation đúng giữa CRL và key thường; COPPA hard-stop AppLovin thật (test
riêng); ATT có timeout + ref-count tránh chồng UMP; ví dụ tích hợp tuân đúng
hợp đồng README (setNavigatorKey trước runApp, 2 observer, init trong splash,
dispose listener). Chi tiết đầy đủ: `audit_codex_round34.md`,
`audit_claude_round34.md`.

## Phần audit bổ sung (sau khi 2 agent xong, orchestrator tự làm tiếp)

**F4 (thông tin mới, ngoài tầm kiểm soát code Dart) — nghiên cứu bảo mật công
khai (5/2026, Felix Braberg) cho biết đã "bẻ" được giao thức mã hoá mediation
riêng của AppLovin, phát hiện SDK native AppLovin dùng một định danh do server
cấp để nhận diện lại thiết bị xuyên nhiều app, hoạt động cả khi user đã từ
chối App Tracking Transparency (ATT) trên iOS.** Đây không phải lỗi của
package `ad_sdk` — nằm hoàn toàn trong binary native của `applovin-sdk`
(Android) / `AppLovinSDK` (iOS) mà package này gọi vào, không có API nào phía
Dart để tắt/kiểm soát hành vi này. Rủi ro thật cho production: (a) chính sách
minh bạch quyền riêng tư của Apple (App Store) coi việc lách ATT là vi phạm
rõ ràng nếu bị phát hiện, dù lỗi nằm ở tầng AppLovin chứ không phải app; (b)
không có CVE chính thức nào được cấp cho vấn đề này (không phải lỗ hổng kỹ
thuật truyền thống, mà là hành vi thiết kế gây tranh cãi). Không tìm thấy CVE
chính thức nào khác cho các bản native đang pin: `AppLovinSDK 13.6.3` (iOS),
`com.applovin:applovin-sdk 13.6.3` (Android), `Google-Mobile-Ads-SDK 12.14.0`
(iOS), `com.google.android.gms:play-services-ads 24.9.0` (Android).

**Đã đọc sâu `compliance/` và `monetization/` (2103 dòng, 13 file) — không
có finding mới.** Sửa lại 1 mô tả sai của chính tôi ở bản trước: đây **không
phải hash-chain từng dòng** — cơ chế thật là 1 chữ ký Ed25519 duy nhất ký lên
toàn bộ JSON export (`compliance_signing.dart`), đủ để phát hiện sửa tay sau
khi export (đổi 1 byte làm sai chữ ký), có tài liệu rõ về threat model (chỉ
chống sửa tay sau export, không chống chủ thiết bị cố tình làm giả từ đầu —
tự nhận đúng, không phóng đại). `monetization_arbitrator.dart` (module phức
tạp nhất, 304 dòng) xác nhận: chỉ được phép **veto** (giảm) một lần show ad để
nudge VIP, chạy SAU khi mọi safety-gate đã pass — grep xác nhận không module
monetization nào gọi `AdSafetyConfig`/`bypassSafety`/switch provider, nên
không có đường nào để logic tối ưu doanh thu tự ý vượt qua safety cap.

**Đã chạy integration_test thật** trên thiết bị Android thật đang cắm dây
(Samsung SM A507FN, Android 11 thật, không phải emulator) và iOS Simulator
(iPhone 16, iOS 18.6) — cùng flag với CI (`AD_PROVIDER_ADMOB=true` vì không
có AppLovin SDK key thật để test cục bộ, giống giới hạn CI đã biết). Kết quả
chi tiết: xem phần cập nhật cuối file này sau khi cả 2 run hoàn tất.

## Khuyến nghị production

**Dùng được cho production**, với các điều kiện — không đổi nhiều so với các
round trước, cộng 3 việc nhỏ mới của round này:

Điều kiện đã biết từ trước (chấp nhận, không phải chặn):
1. Chấp nhận VIP/trial trên Android chỉ "weak, mitigated" — dùng AVP2 với
   `--valid-days` ngắn thay vì phát key vô thời hạn quy mô lớn.
2. Chấp nhận AppLovin consent-write không verify được ở tầng platform-channel
   (giới hạn dependency, không sửa được từ code SDK).
3. Không dùng `bypassSafety` ngoài đúng 1 điểm gọi ở splash — đây là honor
   system, không có enforcement kỹ thuật.

Việc nên làm trước khi release tiếp (mới phát hiện round 34, chi phí thấp):
4. Cập nhật README mục "CCPA / US state privacy" cho khớp code sau round 33 —
   nói rõ hiện tại chỉ đọc Sale/SharingOptOut của US National GPP, chưa đọc
   `TargetedAdvertisingOptOut` và chưa đọc section theo bang.
5. Sửa `example/lib/main.dart:264` dùng `kDebugMode ? verbose : warning` thay
   vì ép cứng `verbose`, khớp default an toàn mà chính SDK core đã tự áp dụng.
6. Xác minh khoá `private_key.pepk` (đã xoá khỏi HEAD) có từng active trên
   Play Console không; nếu có, cân nhắc rotate qua Play Console và purge khỏi
   git history trước khi mở quyền truy cập repo.
7. **(F5, MAJOR, xác nhận bằng test thiết bị thật)** Banner mount lần đầu
   trong lúc VIP đang active không tự load lại sau khi VIP hết hạn — chỉ hồi
   phục khi widget bị remount. Ảnh hưởng doanh thu thật, không phải edge case
   hiếm (đúng lúc VIP hết hạn là lúc quan trọng nhất để banner quay lại).
   Cần điều tra `banner_ad_widget.dart` (`_initStarted`/`_initBanner`/
   `initRevision` reload path) và sửa trước khi coi round 34 đã đóng hẳn.

Round 34 tìm được **1 bug thật mới** (F5, xác nhận bằng integration test
thiết bị thật, tái lập 2/2 lần) — đủ để thêm vào điều kiện production, nhưng
KHÔNG đủ nghiêm trọng để đổi khuyến nghị tổng thể từ "dùng được" sang "không
nên dùng": phạm vi hẹp (chỉ 1 kịch bản chuyển tiếp VIP→hết hạn cụ thể trên
banner, không phải core an toàn/pháp lý), có workaround tạm (dùng
`bypassVipGuard`/hoặc chấp nhận banner chỉ hồi phục sau khi user tự chuyển
màn hình — hầu hết app đều có điều hướng thường xuyên). Các BLOCKER/MAJOR
còn lại do Codex nêu đều là rủi ro đã biết, đã cân nhắc, đã công bố từ trước
— không phải lỗ hổng mới phát sinh. Codebase vẫn giữ kỷ luật kỹ thuật cao
(dispose/lifecycle nhất quán, mọi claim "đã fix" ở round 33 verify lại bằng
tay đều đúng thật) — F5 là lỗi thật đầu tiên round này tự tìm ra được bằng
cách chạy trên thiết bị thật thay vì chỉ đọc code, đúng minh chứng cho việc
test thiết bị thật vẫn cần thiết dù đã có 1571 test tĩnh xanh.

## Kết quả integration_test trên thiết bị/simulator thật (bổ sung)

- **Android (thiết bị thật, Samsung SM A507FN, Android 11, cắm dây)**: chạy
  bị lỗi hạ tầng máy cục bộ (cache Gradle hỏng — `metadata.bin` thiếu, thiết
  bị cũng rớt kết nối USB giữa chừng), gần như mọi file fail cùng lúc vì
  cùng 1 nguyên nhân build — không phải bug SDK. Theo quyết định của user,
  **không rerun** — chấp nhận kết quả Android trên CI (emulator, chạy định kỳ
  và đáng tin) là đủ.
- **iOS (Simulator, iPhone 16, iOS 18.6, `AD_PROVIDER_ADMOB=true` vì không có
  AppLovin key thật để test cục bộ — giống giới hạn CI)**: chạy đầy đủ 48
  file, **43/48 pass** thật trên simulator (không phải suy đoán từ test tĩnh).
  5 file fail sau 2 lần thử, đã tự tay đọc log từng file:
  - `consent_gate_recovery_test.dart`, `consent_resume_backstop_test.dart` —
    assertion fail thật, nhưng khớp giới hạn iOS Simulator **đã biết từ
    trước** (form UMP không present được trên Simulator — xem
    [[ios-simulator-cannot-run-consent-integration-tests]]) — không phải hồi
    quy mới.
  - `r36_real_applovin_appopen_over_banner_test.dart` — timeout 12 phút, đúng
    như tên file dự đoán ("real_applovin"): cần AppLovin ad thật, không thể
    pass khi bị ép `AD_PROVIDER_ADMOB=true` do không có key cục bộ — giới hạn
    đã biết, không phải bug.
  - `waterfall_tuner_test.dart` — timeout 12 phút, **CHƯA rõ nguyên nhân**.
    Test chỉ gọi `AdManager().loadInterstitial()` thật (network thật tới
    AdMob) sau 53 phút simulator đã chạy liên tục hàng chục file trước đó —
    nghi ngờ hợp lý nhất là cùng loại simulator-flake CI đã tự ghi nhận trước
    đây (`.github/scripts/integration-retry.sh` có hẳn đoạn comment về
    "simulator's logging subsystem wedged" sau phiên dài) hơn là một hang
    thật trong code, nhưng **KHÔNG khẳng định chắc** — cần chạy lại **một
    mình** file này trên simulator vừa mới khởi động (không phải sau 53 phút
    chạy liên tục) để phân biệt dứt điểm. Chưa làm được trong phạm vi round
    này vì thời gian — ghi nhận minh bạch là "chưa kết luận", không quy kết
    bừa cho môi trường để bỏ qua.
  - `r23_banner_revive_on_vip_expiry_test.dart` — assertion fail thật (VIP
    chưa hết hạn đúng lúc test kỳ vọng), có kèm 1 dòng log lạ
    "cached CRL failed to verify, ignoring" mà chính file test này không hề
    dùng CRL — nghi ngờ hợp lý nhất là rò rỉ state giữa các file test chạy
    tuần tự trên cùng 1 simulator (không reinstall app giữa mỗi file, khác
    với CI có thể có setup sạch hơn), tạo ra 1 flake liên quan thời gian VIP
    hết hạn — tương tự flake `vip_redeem_flow_test` đã biết trước đó
    ([[ios-simulator-cannot-run-consent-integration-tests]]). Cũng **CHƯA
    khẳng định chắc** — cần rerun riêng lẻ để loại trừ khả năng là bug thật.

**Cập nhật (rerun riêng lẻ trên simulator mới boot, không chạy song song):**

- `waterfall_tuner_test.dart` → **PASS sạch khi chạy một mình.** Xác nhận là
  simulator-flake (simulator đã sống 53+ phút lúc chạy chung 48 file), không
  phải bug. Đóng, không cần theo dõi thêm.
- `r23_banner_revive_on_vip_expiry_test.dart` → **FAIL LẠI, sạch, tái lập
  được 2/2 lần** (lần chạy chung 48 file VÀ lần chạy riêng một mình) —
  **đây là bug thật, không phải flake.**

**F5 (MAJOR, bug thật, tái lập được) — banner không tự load lại sau khi VIP
hết hạn, nếu banner được mount LẦN ĐẦU trong lúc đang VIP.**

Kịch bản tái hiện chính xác (từ chính test): user đang VIP → mở trang có
banner (banner bị ẩn vì VIP, đúng) → VIP hết hạn → theo thiết kế, biến đếm
`AdManager().initRevision` phải tăng để báo `BannerAdWidget` load lại — xác
nhận **tăng đúng** (`packages/ad_sdk/test` unit test level đã pass, và test
integration dòng 112 pass) — nhưng banner **không thực sự gửi request quảng
cáo mới** trong vòng 20 giây sau đó (dòng 127 fail: `bannerLoads` rỗng).

Nghi vấn cụ thể nhất (chưa khẳng định 100%, cần điều tra thêm):
`lib/src/widget/banner_ad_widget.dart` — `didChangeDependencies()` có cờ
một-lần `_initStarted`: `if (!_initStarted.value) { _initStarted.value =
true; _initBanner(context); return; }`. Nếu lần gọi `_initBanner` đầu tiên
này rơi đúng lúc đang VIP, `_initBanner` return sớm ở check
`mgr.isVIPMember()` (không load được gì) — NHƯNG `_initStarted.value` đã bị
đánh dấu `true` vĩnh viễn cho vòng đời widget này, bất kể load có thành công
hay không. Đường reload thứ hai (qua `ValueListenableBuilder<int>` lắng nghe
`initRevision` ở `_buildBanner()`, điều kiện `!_allowed.value &&
!_initScheduled && isInitialised`) về lý thuyết vẫn độc lập với
`_initStarted` nên vẫn nên chạy được — đã đọc kỹ nhưng **chưa lần ra được
chính xác điểm nào chặn nó** trong ngân sách audit round này.

**Impact thật nếu đúng:** một banner mount lần đầu trong lúc user đang VIP
(rất phổ biến — VIP mua/kích hoạt trước khi mở app) sẽ vĩnh viễn không hiện
quảng cáo sau khi VIP hết hạn, cho tới khi widget bị dispose/remount (đổi
màn hình, khởi động lại app...) — mất doanh thu thật cho đúng nhóm user vừa
hết hạn gói VIP, không phải edge case hiếm.

**Việc còn nợ:** cần 1 phiên làm việc riêng để (a) xác nhận chính xác điểm
chặn bằng cách thêm log tạm thời hoặc breakpoint vào `_buildBanner`/
`_initBanner`, (b) viết unit test tái hiện đúng thứ tự "mount trong lúc VIP
→ revoke VIP" (khác với `r23_vip_expiry_banner_revive_test.dart` hiện có, có
thể đang test thứ tự ngược lại), (c) sửa fix thật (có thể chỉ cần bỏ qua
kiểm tra `_initStarted` khi lần init trước đó bị skip vì VIP, không phải vì
lỗi thật).

**Kết luận phần test thiết bị thật:** 43/48 pass thật củng cố thêm độ tin
cậy so với chỉ dựa vào 1571 test tĩnh. 4/5 fail ban đầu có lời giải thích rõ
(giới hạn UMP-simulator / thiếu AppLovin key / simulator-flake đã xác nhận).
**1 fail (F5, banner không hồi sinh sau VIP hết hạn) là bug thật, tái lập
2/2 lần, chưa fix.** Đây LÀ finding đủ quan trọng để đưa vào danh sách điều
kiện production bên dưới.
