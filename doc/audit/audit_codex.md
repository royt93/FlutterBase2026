# Audit round 40 — Codex (`codex exec --dangerously-bypass-approvals-and-sandbox`)

**Run against:** an isolated `rsync` copy of the repo at `/tmp/audit_r40_copy`
(read-only instructions given; verified afterward the isolated copy's own
throwaway git history shows only the two generated report files touched —
no source file was modified, no commit/push happened).
**Model/tool:** OpenAI Codex CLI, `exec` mode, no test/build run (static
read only, by its own account).

Codex was given the same 7-criteria brief as the in-session Claude audit
(`audit_claude.md`) and asked to write its own independent verdict to
`AUDIT_OUTPUT.md`, without seeing this session's context or the other two
reviewers' output.

---

## Kết luận

**Chưa nên coi bản hiện tại là hoàn tất về consent đa bang Hoa Kỳ.** Audit
đọc tĩnh tìm được **1 MAJOR mới**: bộ tổng hợp GPP ưu tiên tín hiệu "không
opt-out" của một section và bỏ qua opt-out ở section khác. Ngoài ra có **1
MINOR** về thời gian tự hồi phục sau một nhánh re-init hiếm. Không thấy
BLOCKER mới.

Phạm vi đã đọc gồm adapter, bridge, manager, widget lifecycle, UMP/IAB
storage, consent manager và toàn bộ cơ chế trial/VIP. Không chạy build/test
và không thay đổi source. "False-positive" dưới đây nghĩa là claim ban đầu
đã được lần theo tới consumer/native-facing call và bác bỏ; giới hạn kiến
trúc thật nhưng đã biết vẫn được ghi riêng, không giả làm finding mới.

## 1. Provider adapter AdMob/AppLovin trên Android và iOS

### Không có lỗi adapter đa nền tảng mới — false-positive: **Có** đối với nghi vấn `AdViewId` sai kiểu

- `AdViewId` được giữ nguyên dưới dạng `num` xuyên qua bridge và widget,
  không ép `int`/`String`: `lib/src/adapters/applovin_bridge.dart:44-45,111-113`,
  `lib/src/adapters/applovin_adapter.dart:203-205`,
  `lib/src/widget/banner_ad_widget.dart:724-744`. Điều này phù hợp với
  plugin AppLovin 4.6.4: Android trả integer và iOS trả `NSNumber`; không có
  channel type mismatch.
- Consent/test-device được đặt trước `AppLovinMAX.initialize`, đúng thời
  điểm native SDK đọc cấu hình: `lib/src/adapters/applovin_adapter.dart:709-758`.
  AdMob chuyển COPPA/UAC qua `RequestConfiguration` và NPA/RDP theo từng
  request: `lib/src/adapters/gma_bridge.dart:57-105,108-115,121-220`.
- Callback load muộn và tài nguyên fullscreen/inline đều có dispose/identity
  guard; không tìm được đường callback mới nào hồi sinh adapter đã teardown.

**Mức độ:** không có finding mới.

## 2. Online/offline resilience

### R40-01 — Re-init có thể mất fast-refill khi connectivity watch mới thất bại

**Mức độ: MINOR — False-positive: Không.**
*(Xem xác minh chéo trong `audit_round40_consolidated.md` — cơ chế đúng,
nhưng đã được ghi chú và chấp nhận CHỦ Ý ngay trong code, không phải finding
mới của round 40.)*

`_connectivityReady` là cờ cấp process và không reset khi teardown, trong
khi `_stopConnectivityWatch()` hủy subscription
(`lib/src/core/ad_manager.dart:1279-1289,7658-7662`). Mỗi init có gọi lại
`_startConnectivityWatch()` (`lib/src/core/ad_manager.dart:3292-3294`), nhưng
nếu lần gọi sau lỗi/timeout thì cờ vẫn là `true`, subscription vẫn `null`;
nhánh tự sửa định kỳ lại chỉ gọi `_startConnectivityWatch()` khi
`!_connectivityReady` (`lib/src/core/ad_manager.dart:7594-7607`). Vì vậy
chuỗi thật là: init #1 thành công → destroy hủy listener → init #2 không
dựng được listener → reconnect không phát `_onConnectivityChanged` cho
manager. Quảng cáo không kẹt vĩnh viễn vì poll vẫn chạy mỗi 5 phút
(`lib/src/core/ad_manager.dart:112,7525-7573`) và getter còn đọc trạng thái
global (`lib/src/core/ad_manager.dart:5891-5915`), nhưng refill tức thời bị
mất tới tối đa một chu kỳ poll.

Khuyến nghị: trạng thái "backend notifier đã init" và "manager hiện có
subscription" phải là hai cờ riêng; retry watch dựa trên
`_connectivitySub == null`, với seam test để không chạm detector thật.

Các nhánh offline thông thường đã đúng: load bị chặn khi offline, failure đi
vào per-slot backoff, reconnect debounce rồi refill, và cache fullscreen
không bị show khi stale.

## 3. Từng ad type, policy placement và lifecycle

### Không có leak/lifecycle finding mới — false-positive: **Có** đối với hai nghi vấn đã kiểm chứng

- Banner/MREC hủy listener, RouteAware subscription, native object/ad-view
  và notifier trong `dispose`; timer/visibility được quản lý theo instance:
  `lib/src/widget/banner_ad_widget.dart:396-418`,
  `lib/src/widget/mrec_ad_widget.dart:275-324`. Cả `active:false` lúc mount
  lẫn thay đổi visibility đều chặn load/reload.
- Native không có RouteAware là chủ ý hợp lý, không phải leak: format này
  không auto-refresh; item rời cây gọi `disposeNativeInstance`, listener lỗi
  và timer retry đều được tháo/hủy:
  `lib/src/widget/native_ad_widget.dart:18-38,94-113,239-253`.
- App-open/interstitial/rewarded/rewarded-interstitial có single-show guard,
  show watchdog, callback identity và refill sau terminal callback; AdMob
  cache có freshness gate trước show.
- **Rewarded-interstitial trên AppLovin không phải implementation thiếu:**
  MAX không có format tương đương; slot cố ý idle/no-op
  (`lib/src/adapters/applovin_adapter.dart:191-197`,
  `lib/src/core/ad_manager.dart:6965-6973`). API trả `shown:false`, không
  giả lập bằng rewarded thường nên tránh sai disclosure/placement policy.
  Đây là giới hạn capability đã document, không phải bug runtime.

**Mức độ:** không có finding mới.

## 4. Trial mode 1 ngày

### Giới hạn đã biết: farm trial trên Android khi không có Auto Backup

**Mức độ: MAJOR (kiến trúc) — False-positive: Không; nhưng không mới.**

Android luôn trả `false` từ guard
(`lib/src/vip/_first_install_guard.dart:137-158`) và chỉ dựa vào restore của
`FlutterSharedPreferences.xml` (`lib/src/vip/_first_install_guard.dart:27-47`).
Uninstall/reinstall khi backup tắt, chưa sync, đổi Google account, hoặc xóa
dữ liệu sẽ nhận lại trial. iOS dùng Keychain `first_unlock` và ghi marker
trước prefs (`lib/src/vip/_first_install_guard.dart:93-105,177-203`), nên
chặn reinstall thường; erase-device vẫn bypass và restore sang thiết bị mới
có thể false-positive block (`lib/src/vip/_first_install_guard.dart:49-68`).
Đây đúng là trade-off đã ghi từ round 39, không có bypass mới phát hiện
trong round 40. Muốn chống farm chắc chắn cần identity/claim phía server;
local-only không thể chứng minh "đã từng cài" sau khi toàn bộ local state bị
xóa.

## 5. Kích hoạt VIP bằng code, Ed25519 offline

### Giới hạn đã biết: cross-device replay và tamper trên thiết bị đã compromise

**Mức độ: MAJOR (kiến trúc) — False-positive: Không; nhưng không mới.**

- Chữ ký Ed25519 được verify bằng public key 32 byte; private key không nằm
  trong runtime. AVP2 ký duration/kid/expiry/bundle binding, CRL có domain
  separation `CRL1|`: `lib/src/vip/signed_vip_key.dart:109-191,193-249,268-344`.
- Một code hợp lệ vẫn redeem được trên nhiều thiết bị vì ledger chỉ
  per-device; source tự document giới hạn này
  (`lib/src/vip/vip_manager.dart:1238-1249`). Android ledger nằm ở
  SharedPreferences và mất khi uninstall/restore không hoạt động
  (`lib/src/utils/ad_preferences.dart:361-381`); iOS có Keychain mirror
  (`lib/src/vip/_redeemed_key_ledger.dart:79-125`).
- Root/jailbreak, runtime hooking hoặc sửa binary/public key có thể vô hiệu
  hóa ledger/verification. Secure storage bảo vệ at-rest với thiết bị bình
  thường, không tạo trust boundary trước chủ thiết bị có đặc quyền. Đây
  không thể sửa triệt để trong mô hình "offline, không backend".

Không thấy lỗi mới về signature confusion, CRL rollback, double-tap race hay
save ordering. AVP1 vẫn không có expiry/bundle binding nhưng là
compatibility surface đã biết
(`lib/src/vip/signed_vip_key.dart:86-105,210-212`).

## 6. Consent mọi quốc gia

### R40-02 — GPP "first non-null wins" có thể bỏ qua opt-out của bang áp dụng

**Mức độ: MAJOR — False-positive: Không.** *(Xác nhận độc lập — xem
`audit_claude.md` mục R40-A và `audit_round40_consolidated.md`: đây là
finding thật, mới, chưa từng có test hay doc comment nào bàn tới trước round
40.)*

`usPrivacyOptedOut()` trả ngay khi legacy US Privacy, US National hoặc
California cho một giá trị, rồi chỉ đọc các section sau nếu giá trị trước
là `null` (`lib/src/core/iab_storage.dart:220-240`). `_gppUsStatesOptedOut()`
cũng trả section bang đầu tiên có giá trị, kể cả `false`, và không xem các
section còn lại (`lib/src/core/iab_storage.dart:385-405`). Đây không phải
pattern-match: consumer `_reconcileDeviceUsPrivacy()` chỉ nâng `doNotSell`
khi kết quả cuối là `true` (`lib/src/core/ad_manager.dart:5192-5227`), rồi
mới truyền RDP cho mọi request AdMob và `setDoNotSell(true)` cho AppLovin.
Do đó một store hợp lệ có US National=`Did Not Opt Out` nhưng California
(hoặc bang áp dụng khác)=`Opted Out` bị tổng hợp thành `false`; tín hiệu hạn
chế không tới cả hai provider.

Việc probe mọi isolated section nhưng không decode GPP header/applicable
section làm "priority theo ID" không có cơ sở pháp lý. Nếu tiếp tục không
xác định jurisdiction/section đang áp dụng, phép gộp an toàn phải là:
**bất kỳ tín hiệu `true` nào thắng; chỉ trả `false` khi đã đọc toàn bộ tín
hiệu hiện diện và không có `true`**. Tốt hơn là decode header và chọn đúng
section áp dụng. Cần regression test tối thiểu cho USNat=false + USCA=true
và state-9=false + state-10=true.

Các phần còn lại đã được nối đúng: UMP chặn request trước consent, TCF
Purpose 1/3/4 quyết định personalization
(`lib/src/core/iab_storage.dart:422-515`), privacy-options late-dismiss được
re-read (`lib/src/core/ump_consent.dart:411-421,491-513`), và consent cuối
cùng được áp cho cả provider.

## 7. Tuân thủ policy AdMob/AppLovin nói chung

### Không có finding policy độc lập mới — false-positive: **Có** đối với "SDK tự bảo đảm test ads/COPPA cho mọi cấu hình"

- Consent-before-request có hard gate ở manager và gate lặp lại tại
  adapter/widget; rút consent loại cache/instance cũ trước khi refill.
- AppLovin MAX 4.x không có child-directed API, nên SDK fail-closed và
  không initialize provider khi COPPA=true
  (`lib/src/adapters/applovin_adapter.dart:672-697`). Đây là hành vi
  compliance đúng, dù đồng nghĩa không có ads AppLovin cho child audience.
- ATT được tách thành explicit bootstrap step và không dùng GAID trước khi
  trạng thái ATT phù hợp; app host vẫn phải có
  `NSUserTrackingUsageDescription` và gọi bootstrap đúng thứ tự.
- Test-device registration không thể tự biến mọi ad unit thành test
  inventory: AppLovin chỉ đăng ký GAID trong debug khi lấy được ID
  (`lib/src/adapters/applovin_adapter.dart:740-755`), còn AdMob nhận danh
  sách test IDs qua request configuration. Host vẫn chịu trách nhiệm dùng
  test unit/test mode khi QA. Đây là integration obligation, không phải một
  đường policy bypass tự phát trong SDK.
- Disclosure của rewarded-interstitial được đặt trước show ở lớp
  `AdScreen`; fullscreen mutex, dialog/UMP-on-screen gate và banner/MREC
  hiding ngăn ad stacking.

**Mức độ:** ngoài R40-02 (đã tính ở tiêu chí 6), không có finding mới.

## Tổng hợp finding hành động

| ID | Severity | Tiêu chí | False-positive | Hành động |
|---|---|---:|---|---|
| R40-01 | MINOR | 2 | Đã biết, không mới (xem ghi chú xác minh chéo ở trên) | Retry connectivity watch khi subscription null, không dựa duy nhất vào cờ init cấp process. |
| R40-02 | MAJOR | 6, 7 | Không, mới | Gộp mọi section GPP theo "true wins" hoặc decode header/applicable section; thêm test xung đột section. |

Hai MAJOR trial/VIP nêu ở tiêu chí 4–5 là giới hạn local-only đã biết và
được chấp nhận từ round trước, không phải regression round 40. Không phát
hiện BLOCKER, memory leak mới, channel argument mismatch, hay race
show/load mới trong bảy vùng audit.

---

*Cross-check note added by orchestrating Claude session: R40-01 was
independently re-read against the doc comment sitting directly above the
cited code in `ad_manager.dart` and found to already be documented there as
a conscious, accepted trade-off (not new); R40-02 was independently re-read
and confirmed genuinely new — no existing test or comment addresses the
"definitive false in a higher-priority section shadows a real true in a
lower-priority one" case. See `audit_claude.md` and
`audit_round40_consolidated.md`.*
