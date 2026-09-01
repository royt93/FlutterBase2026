# Audit round 28 — independent Codex review

**Ngày:** 2026-09-01  
**HEAD được audit:** `d3da1bc`  
**Package:** `packages/ad_sdk` — `applovin_admob_sdk` **2.9.6**  
**Reviewer:** Codex (đọc source hiện tại độc lập, sau đó mới đối chiếu kết luận round 27)

---

## 1. Kết luận điều hành

**Ready for production use in a real consuming app: YES WITH CONDITIONS.**  
**Điểm: 8.2/10.**

Source hiện tại có kiến trúc khá phòng thủ: consent gate fail-closed, shared
fullscreen mutex, callback/watchdog teardown, keyed inline-ad ownership, Ed25519
verification, VIP write serialization và anti-clock-rollback. Không tìm thấy
BLOCKER/MAJOR regression mới trong hai commit sau round 27; đúng như brief,
không có thay đổi `lib/` trong hai commit đó.

Các điều kiện/caveat production còn thật sự tồn tại:

1. **Không thể coi AppLovin credential leak cũ là resolved từ source.** Việc
   rotate AppLovin SDK key và 8 ad-unit ID trên dashboard là out-of-band; source
   sạch hiện tại không chứng minh credential cũ đã bị thu hồi.
2. Rewarded Interstitial chỉ được triển khai thật ở AdMob; AppLovin adapter là
   documented no-op vì MAX không có format tương ứng
   (`lib/src/adapters/applovin_adapter.dart:1700-1713`). Consumer phải feature-
   gate format này theo provider.
3. Trial và redeemed-key durability trên Android chỉ best-effort qua Auto Backup;
   Clear data, backup tắt/khác account, hoặc reinstall không restore vẫn reset
   local state (`lib/src/vip/_first_install_guard.dart:27-56,114-133`). Đây là
   giới hạn tất yếu của yêu cầu “không backend”, nhưng phải được chấp nhận rõ.
4. Ed25519 verify là offline, nhưng API redemption cố ý yêu cầu connectivity
   trước khi verify (`lib/src/vip/vip_manager.dart:1301-1313`). Vì vậy “không
   backend” và “không thể forge key” đạt; “redeem khi device offline” không đạt.

---

## 2. Phương pháp và kiểm chứng thực chạy

- Đọc baseline `doc/audit/audit_round27_consolidated.md` trước theo yêu cầu,
  nhưng re-audit trực tiếp `lib/src/adapters`, `core`, `consent`, `vip`, `widget`,
  `config` và các test liên quan.
- Kiểm tra `git log`: sau `f59be16` (2.9.6) chỉ có `6784858` (docs) và
  `d3da1bc` (integration-test navigation fix); không có `lib/` delta.
- `cd packages/ad_sdk && flutter analyze`: **PASS, 0 issue** (`No issues
  found`, 5.8 s).
- `cd packages/ad_sdk && flutter test --reporter expanded`: **PASS,
  1.482/1.482 test**, 0 fail, kết thúc **4:16**. Đây là số từ lần chạy round 28,
  không tái sử dụng số round 27.
- Không chạy on-device integration suite vì brief chỉ yêu cầu hai command trên;
  unit/widget test không thay thế xác nhận real SDK callback trên cả Android và
  iOS hardware.

---

## 3. Đối chiếu 7 yêu cầu sản phẩm

| # | Yêu cầu | Kết quả |
|---|---|---|
| 1 | Dual provider, Android + iOS | **PASS-with-caveat** |
| 2 | Có mạng và không mạng | **PASS-with-caveat** |
| 3 | Đủ ad type, lifecycle, compliance, no leak | **PASS-with-caveat** |
| 4 | Trial 1 ngày | **PASS-with-caveat** |
| 5 | VIP code, no backend, Ed25519 chống forge | **PASS-with-caveat** |
| 6 | Consent mọi vùng | **PASS-with-caveat** |
| 7 | AdMob/AppLovin policy | **PASS-with-caveat** |

### 3.1 Dual provider AdMob/AppLovin trên Android và iOS — PASS-with-caveat

**Bằng chứng:** package khai báo chỉ Android/iOS và kéo cả hai native SDK
(`pubspec.yaml:27-29,61-67`). Config chọn provider qua một enum và giữ config
riêng cho AdMob/AppLovin (`lib/src/config/ad_config.dart:665-675`). Hai adapter
có load/show/dispose riêng; AdMob dispose đặt `_fullscreenDisposed` trước khi
giải phóng native handles và dispose toàn bộ keyed banner/MREC/native resources
(`lib/src/adapters/admob_adapter.dart:555-685`). AppLovin teardown cũng clear
listener trước rồi destroy native widget views và dispose slots
(`lib/src/adapters/applovin_adapter.dart:788-921`).

**Caveat:** Rewarded Interstitial là AdMob-only. AppLovin implementation trả
`shown:false/earned:false` (`applovin_adapter.dart:1700-1713`). Đây không phải
memory/lifecycle bug nhưng có nghĩa “mọi format trên cả hai provider” không phải
capability thực tế. Ngoài ra test host không chứng minh native integration trên
hai OS; cần smoke test release build cho từng provider trước rollout.

### 3.2 Online và offline device — PASS-with-caveat

Ad widgets kiểm tra connectivity trước load và collapse thay vì treo; ví dụ MREC
return khi offline (`lib/src/widget/mrec_ad_widget.dart:135-168`). Manager có
connectivity watcher/refill và test suite thực chạy bao gồm flapping, reconnect,
consent-init offline. UMP network update có timeout 20 s, sau đó đọc cached
`canRequestAds/status` (`lib/src/core/ump_consent.dart:215-239`), nên splash
không chờ vô hạn. Khi UMP inconclusive/offline, consent đã lưu không bị ghi đè
(`lib/src/core/ad_manager.dart:4219-4251`).

**Caveat:** offline không thể tải/quảng cáo mới — expected. VIP signed-code
redemption cũng bị product gate yêu cầu network 2 s trước khi verify
(`vip_manager.dart:1262-1313`), dù cryptographic verification tự thân offline.

### 3.3 Bảy ad type, lifecycle, policy và leak — PASS-with-caveat

- Fullscreen: App Open, interstitial, rewarded, rewarded-interstitial dùng slot
  state machine, freshness/watchdog, shared present gate. App Open kiểm tra mutex
  ngay trước present và ẩn inline ads trong toàn thời gian fullscreen
  (`lib/src/core/ad_manager.dart:5882-5935`).
- Dialog stacking: resume App Open đọc `_fullscreenBusyReason`, bao phủ native
  UMP form, loading dialog và Flutter `PopupRoute`
  (`ad_manager.dart:5977-5986`; `ad_manager.dart:1443-1476`). `PopupRoute` depth
  được cập nhật trên push/pop/remove/replace
  (`lib/src/core/ad_route_observer.dart:28-99`).
- Banner/MREC RouteAware: resubscribe khi route đổi, unsubscribe và dispose keyed
  instance/notifiers trong `dispose()` (`lib/src/widget/banner_ad_widget.dart:
  252-262`; `lib/src/widget/mrec_ad_widget.dart:116-133,227-238`). Không thấy
  RouteAware listener leak mới.
- AdMob late teardown callbacks: dispose guard được đặt trước native release;
  late failure của Rewarded Interstitial bị drop
  (`admob_adapter.dart:555-575,1646-1663`). Lần test này thực sự chạy bốn case
  “late onFailed after dispose” và đều pass.
- Native/MREC/banner dùng keyed maps nên nhiều widget đồng thời không tranh một
  handle; teardown union cả slot/listenable key set
  (`admob_adapter.dart:653-685`).

**Caveat:** AppLovin Rewarded Interstitial unsupported như mục 3.1. Automated
tests mock bridge/platform callbacks; real-ad close/reward/background lifecycle
trên Android+iOS vẫn cần release smoke matrix. Không thể tuyệt đối chứng minh
“no memory leak” chỉ bằng source/test, nhưng không thấy ownership leak cụ thể.

### 3.4 Trial 1 ngày — PASS-with-caveat

Initialize stamp first-install time, kiểm tra one-shot prefs flag, cấp đúng
configured duration và ghi Keychain marker trước prefs flag để đóng force-kill
window (`lib/src/core/ad_manager.dart:2563-2650`). iOS dùng Keychain
`first_unlock`, tồn tại qua reinstall (`_first_install_guard.dart:15-25,70-83,
192-205`). Guard read timeout chọn không cấp trùng nhưng không burn first-install
flag trên timeout (`ad_manager.dart:2583-2610`). VIP clock dùng persisted
high-water mark + raw-clock start check; test suite có rollback/poisoned-clock
coverage và đã pass.

**Caveat quan trọng:** Android guard class luôn trả false; độ bền phụ thuộc Auto
Backup của host và không chống Clear data / backup-disabled reinstall
(`_first_install_guard.dart:27-56,114-133`). Clock local không thể chống một
attacker kiểm soát clock/storage mạnh như server time; implementation giảm
rollback đơn giản, không tạo trust anchor tuyệt đối.

### 3.5 VIP code, no backend, Ed25519 — PASS-with-caveat

Key format giữ signature trên payload; verifier thử danh sách public key rotation,
kiểm tra key 32-byte và gọi Ed25519 verify, rồi mới parse duration/expiry/app
binding (`lib/src/vip/signed_vip_key.dart:115-120,149-223,225-249`). Private key
không ship nên decompile không cho phép mint key hợp lệ mới. AVP2 có expiry và
bundle binding. Same-process double redeem được claim đồng bộ trước await;
durable ledger check xảy ra trước grant (`vip_manager.dart:1369-1395`). iOS
ledger write được serialize bằng `_writeChain`, đóng lost-update race round 27
(`lib/src/vip/_redeemed_key_ledger.dart:47-94`). Teardown giữa grant và burn được
guard (`vip_manager.dart:1396-1432`).

**Caveat:** nếu `PackageInfo.fromPlatform()` lỗi, AVP2 bundle binding bị skip
(`vip_manager.dart:1328-1335`); signature vẫn chống forge nhưng stolen valid code
có thể dùng cross-app trong failure mode đó. Android redeemed ledger vẫn reset
được nếu local/backup state mất. Và redemption API không hoạt động offline như
đã nêu; đây là hành vi product cố ý, nhưng tên “offline-verified VIP codes” dễ
bị consumer hiểu thành “redeem offline”.

### 3.6 Consent mọi quốc gia/vùng — PASS-with-caveat

- GDPR/EEA: UMP tự quyết `required/notRequired`, timeout network 20 s, form
  presentation ref-counted và chỉ release khi native dismiss callback chạy;
  timeout Dart không mở ad gate dưới form (`ump_consent.dart:24-100,241-337`).
- TCF: UMP status được kết hợp purpose bits, không coi `obtained` đồng nghĩa với
  personalized consent (`ad_manager.dart:4195-4217`).
- CCPA: AppLovin `setDoNotSell`; AdMob RDP theo request
  (`lib/src/core/ad_consent.dart:24-31,141-165`; `admob_adapter.dart:705-719`).
- COPPA/TFUA: AdMob nhận child-directed và under-age tags
  (`ad_consent.dart:167-197`). AppLovin không có runtime COPPA flag; adapter phải
  chặn init khi biết child-directed, còn mid-session flip chỉ có thể warn/reinit
  (`ad_consent.dart:145-160`).
- ATT: iOS request có bounded timeout/fail-denied behavior
  (`lib/src/core/att_consent.dart:82-161`).

**Caveat:** SDK không tự xác định ISO country; region/policy source of truth là
UMP và host-supplied consent country (`lib/src/consent/consent_settings.dart:
39-41`; `consent_manager.dart:82-84`). Nếu UMP không có cached decision lúc
offline, gate giữ đóng: compliant nhưng có thể mất revenue. COPPA trên AppLovin
phải được biết trước init; app child-directed không nên chọn AppLovin path.

### 3.7 AdMob/AppLovin policy — PASS-with-caveat

Implementation có safety caps/frequency gates, common fullscreen mutex, rewarded
disclosure hooks, test-device propagation và inline-ad suppression dưới App Open.
Consent changes giữ lại test device list khi thay RequestConfiguration
(`ad_consent.dart:64-75,167-199`). App Open resume không stack trên dialog/form
và không bypass daily/session safety (`ad_manager.dart:5977-6021`).

**Caveat:** SDK không thể tự đảm bảo placement/ad density của consuming app,
`app-ads.txt`, dashboard mediation mapping, SKAdNetwork list, privacy-policy text,
hoặc production creative behavior. Inspector/test-device workflow vẫn là trách
nhiệm release QA. Credential rotation cũ chưa thể xác nhận từ repo và là điều
kiện policy/security trước khi repo được mở rộng quyền truy cập/public.

---

## 4. Các điểm được yêu cầu soi kỹ

### Adapter dispose/teardown race

Không tìm thấy regression mới. AdMob sets disposed first, disposes cached native
objects, resolves pending callbacks, disposes slot/listenable maps và null event
sink cuối teardown (`admob_adapter.dart:555-701`). AppLovin clear native listeners
trước, null Dart callbacks rồi destroy views. `AdManager.destroy()` chờ showing
fullscreen tối đa 5 s và flush log có timeout; test teardown/reinit/late callbacks
đều pass. Rủi ro còn lại là native plugin behavior chỉ observable on-device.

### VIP ledger concurrency

Round-27 race đã được đóng trong source: `_writeChain` serialize read-modify-write
(`_redeemed_key_ledger.dart:47-94`), còn same-kid concurrent claim dùng
`_signedKidsInFlight` trước await (`vip_manager.dart:1369-1378`). Không thấy
lost-update path mới trong một `VipManager` instance.

### Consent/UMP offline và region misdetection

Offline update timeout không ghi đè consent trước; gate lấy cached UMP answer và
fail closed. SDK đúng khi không tự đoán geography, nhưng vì thế integration phải
coi UMP config/dashboard là critical dependency. `countryCode` chỉ analytics,
không phải legal-region detector.

### App Open stacking trên dialog

Đã chặn cả Flutter popup, SDK loading buffer và native UMP form qua một shared
mutex (`ad_manager.dart:1443-1476,5977-5986`). Ref-count UMP tránh overlap form
làm clear boolean quá sớm (`ump_consent.dart:40-100`). Không tìm thấy path resume
App Open bypass mutex.

### Banner RouteAware leak

Banner/MREC đổi subscription khi `ModalRoute` thay đổi và unsubscribe trong
dispose; keyed native instance cũng được dispose. Không tìm thấy listener giữ
`State` sau unmount (`banner_ad_widget.dart:252-262`; `mrec_ad_widget.dart:
116-133,227-238`).

### Trial clock manipulation

Source có high-water mark, monotonic session anchor và raw-clock start/expiry
cross-check; rollback tests pass. Tuy vậy một local-only SDK không thể biến device
clock/storage thành trusted server clock. Kết quả đúng là “hardens common clock
rollback”, không phải “tamper-proof trial”, đặc biệt trên Android sau data wipe.

---

## 5. BLOCKER round 26/27: AppLovin key + 8 ad-unit ID

**Không thể đánh dấu resolved từ source alone.** Repo hiện không cần chứa key/ID
thật để compile, và scan source hiện tại không phát hiện credential production
mới. Nhưng credential từng commit vào git history chỉ thực sự mất giá trị sau khi
rotate/revoke trên AppLovin dashboard. Dashboard state không nằm trong source và
không được cung cấp cho reviewer. Do đó:

- **Source remediation:** có vẻ sạch/không có leak mới.
- **Operational remediation (rotation):** **UNVERIFIED / vẫn là điều kiện treo.**

Đúng theo lịch sử quyết định round 26/27, đây là risk-accepted cho repo private,
không phải bằng chứng rằng secret cũ đã an toàn.

---

## 6. Đồng bộ pub.dev với HEAD

Đã kiểm tra có network:

- Trang HTML `https://pub.dev/packages/applovin_admob_sdk` tại thời điểm mở vẫn
  hiển thị cached **2.9.4**.
- Pub.dev package API trả latest **2.9.6** và archive
  `applovin_admob_sdk-2.9.6.tar.gz`.
- Download archive 2.9.6 và so SHA-256 với repo HEAD:
  - `pubspec.yaml`: **trùng** (`183eb399…242f`)
  - `README.md`: **trùng** (`b2bae768…771`)
  - `CHANGELOG.md`: **trùng** (`ecf21b17…fd8c`)

**Kết luận:** package artifact authoritative trên pub.dev **đồng bộ HEAD cho
version, README và CHANGELOG**. HTML page đang có cache/indexing lag và không nên
được dùng thay API/archive để kết luận version publish.

---

## 7. So sánh với round 27 và findings mới

- Re-derived và xác nhận fix round 27 tồn tại thật: event-log flush bounded,
  AdMob late `onFailed` guards, VIP ledger write serialization.
- Hai commit sau round 27 không đổi `lib/`; không thấy source regression.
- Gap tài liệu MREC/Native/Rewarded Interstitial được commit docs `6784858` đóng;
  đây không phải source behavior change.
- **Không có BLOCKER/MAJOR mới.** Những điểm round 28 làm rõ hơn baseline là:
  1. Rewarded Interstitial không phải dual-provider capability; AppLovin là no-op.
  2. “Offline verified” không đồng nghĩa redeem offline vì product gate network.
  3. Android 1-day trial và redeemed ledger không chống Clear data/reinstall khi
     Auto Backup không restore.
  4. Pub.dev API/archive đã là 2.9.6 dù HTML view còn hiển thị 2.9.4.

Các mục 1-3 là limitation/caveat đã thể hiện trong source hoặc README, không phải
regression do hai commit mới; chúng cần được consumer hiểu để không over-claim.

---

## 8. Verdict cuối

**Ready for production use in a real consuming app: YES WITH CONDITIONS — 8.2/10.**

Trước rollout thực:

1. Xác minh/hoàn tất rotation AppLovin credential trên dashboard.
2. Chạy smoke matrix release trên Android + iOS, mỗi provider, với real test
   units và lifecycle background/resume/dismiss/reward; không chỉ mock tests.
3. Feature-gate Rewarded Interstitial khi provider là AppLovin.
4. Chấp nhận bằng văn bản local-only limitations: Android trial/key-ledger reset,
   offline redemption bị từ chối, AppLovin COPPA phải biết trước init.
5. Consumer app tự review ad density/placement, app-ads.txt, mediation adapters,
   SKAdNetwork IDs, privacy policy, inspector và test-device configuration.

Với các điều kiện đó, source 2.9.6 đủ chặt để pilot production có giám sát; chưa
nên rollout toàn lưu lượng mà không có dashboard telemetry và rollback plan.
