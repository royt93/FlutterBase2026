# Audit round 68 — báo cáo độc lập (nguồn: Claude Sonnet 5, thay vai trò `codex` do hết quota)

**Ngày:** 2026-09-20
**Codebase audited:** worktree `round68-codex-audit`, HEAD `4ce0197` (Release
3.0.3), tức là bản đã publish lên pub.dev, top của 67 vòng audit trước đó.

## Phương pháp

Tôi không có ngữ cảnh chia sẻ với bất kỳ phiên audit nào khác (round 1-67 lẫn
mọi fork "codex"/"agy"/"gemini" trước đây) — mọi kết luận dưới đây tự tôi đọc
code và kiểm chứng, không copy lại nhận định cũ mà không xác minh. Vì repo đã
qua 67 vòng audit rất sâu (nhiều vòng fork riêng cho từng file, tìm được
race condition ở mức dòng lệnh), khả năng còn bug MAJOR nông là thấp — nên
chiến lược của tôi là:

1. Đọc lại 3 vòng audit gần nhất (65, 66, 67) để biết method + phạm vi đã
   phủ, tránh lặp lại đúng những gì đã bị bác bỏ mà không tự kiểm tra lại.
2. Grep chéo tên file trong `lib/` với toàn bộ `doc/audit/*.md` để tìm file
   ít được nhắc tới nhất (đại diện cho vùng ít được soi) — không file nào
   trong số đó có logic đáng kể chưa từng bị đọc.
3. Đọc trực tiếp, có đối chiếu bằng tay, các file trọng yếu nhất theo đúng 6
   yêu cầu chức năng trong brief: `signed_vip_key.dart`,
   `_first_install_guard.dart`, `_redeemed_key_ledger.dart`,
   `vip_revocation_provider.dart`, `att_consent.dart`, `ad_consent.dart`,
   `consent_settings.dart`, `iab_storage.dart` (đoạn GPP), `ad_config.dart`
   (enum `AdProvider`), `applovin_adapter.dart` (gate COPPA T40),
   `banner_ad_widget.dart` (dispose/listener pairing), `ad_manager.dart`
   (connectivity watch, phần liên quan).
4. Chạy thật `flutter analyze` và `flutter test` trên bản sao worktree này
   (không chỉ đọc code) để xác nhận trạng thái hiện tại đúng như tài liệu.
5. Kiểm tra git history của worktree cho rò rỉ private key (cả VIP Ed25519
   lẫn Play App Signing `pepk`).

## Phát hiện

**Không tìm thấy bug MAJOR mới.** Không tìm thấy MINOR mới đáng ghi nhận
ngoài những gì 67 vòng trước đã biết. Dưới đây là các điểm tôi tự kiểm
chứng (không chỉ tin tài liệu) cho từng yêu cầu trong brief.

### 1. Đa provider (AppLovin MAX + AdMob), Android + iOS

`AdConfig.provider` (enum `AdProvider { admob, appLovin }`,
`lib/src/config/ad_config.dart:64-70`) xác nhận kiến trúc thật: SDK không
chạy đồng thời cả 2 SDK gốc trong cùng 1 app — nó chọn MỘT provider chính
(`AppLovinAdapter` hoặc `AdMobAdapter`), còn "đa provider" theo nghĩa
mediation (AppLovin làm mediation network bên trong AdMob) là qua
`gma_mediation_applovin`, sống ở tầng app tiêu thụ chứ không phải trong
package này — đúng như `CLAUDE.md` mô tả. Đây là thiết kế có chủ đích, có
tài liệu hoá rõ ràng trong `ad_consent.dart` (dòng ~248-260: logic
`applyConsentToProviders` chỉ bắt buộc cả 2 provider "apply thành công" khi
`config == null`, còn khi app chỉ khai 1 provider thì chỉ provider đó cần
thành công) — không phải bug, không phải nửa vời.

### 2. Online/offline

`ad_manager.dart` có cơ chế connectivity watch riêng
(`_connectivitySub`/`_lastConnected`/`_connectivityReady`,
dòng ~1945-2010) với debounce 800ms chống "flapping", cờ
`_connectivityReady` chặn đọc `ConnectionNotifierTools.isConnected` trước
khi plugin init xong (né exception thay vì catch). `AdSlot.armLoadWatchdog`
(`lib/src/state/ad_slot.dart:247-274`) đặt watchdog timeout cho MỌI lần
load — nếu native callback không bao giờ về (mất mạng, timeout máy chủ),
watchdog tự chuyển slot sang `failed` thay vì treo `loading` vô hạn. Cặp
`beginLoad()`/`armLoadWatchdog()` được xác nhận (round 66) khớp ở cả 14 call
site thật trong 2 adapter — không có đường load nào thiếu watchdog. Kết
luận: không rủi ro treo UI/ad load vô hạn khi offline.

### 3. Vòng đời + leak cho banner/app-open/rewarded/interstitial

Đọc trực tiếp `banner_ad_widget.dart`: mọi `addListener` (dòng 395, 401)
đều có `removeListener` đối xứng trong `dispose()` (dòng 663-669). File có
docstring tự thú nhận giới hạn thật (không phải che giấu): `VisibilityDetector`
không phát hiện được widget bị `IndexedStack` giấu (non-current child không
được `paint()`), và khuyến cáo host tự set `active` thủ công cho trường hợp
đó — đây là giới hạn API Flutter (`RenderIndexedStack.paintStack`), không
phải bug của SDK, và đã được tài liệu hoá minh bạch cho người tích hợp biết
trước.

Vòng 65 (fork W/A, method riêng, không phải tôi) đã săn đúng lớp bug "stale
cross-adapter callback sau `destroy()`+reinit" xuyên suốt cả widget lẫn 2
adapter và tìm thấy 1 chỗ sót (`native_ad_widget.dart` thiếu guard ở
`onAdLoadedCallback`/`onAdLoadFailedCallback`) — đã fix, có regression test.
Tôi verify lại bằng cách đọc code hiện tại: guard `identical(adapter,
capturedAdapter)` hiện có mặt ở cả 4 callback (`onAdLoadedCallback`,
`onAdLoadFailedCallback`, `onAdClickedCallback`, `onAdRevenuePaidCallback`)
trong `native_ad_widget.dart` — khớp với những gì CHANGELOG 3.0.3 ghi.
Không nghi ngờ gì thêm ở lớp bug này.

App Open không chồng lên dialog: `showAppOpenAdOnResume` kiểm tra
`AdScreenRouteLogger.isDialogOnTop` — đúng như hợp đồng ở `CLAUDE.md`.

COPPA (item pháp lý trong yêu cầu #3): `applovin_adapter.dart:750-767` —
nếu `isAgeRestrictedUser == true`, `initialize()` **từ chối khởi tạo hoàn
toàn** AppLovin MAX (log lỗi rõ ràng, trả `false`), vì AppLovin MAX 4.x
không có API child-directed runtime nào để tắt track trẻ em giữa chừng —
đây là lựa chọn hợp lý và bảo thủ đúng hướng an toàn pháp lý (thà không
chạy AppLovin còn hơn phục vụ ad cá nhân hoá cho audience khai là trẻ em).
Nhược điểm thật: nếu app khai `isAgeRestrictedUser=true` và chọn
`AdProvider.appLovin`, toàn bộ mảng quảng cáo AppLovin của session đó biến
mất — đây là **giới hạn cấu trúc đã biết và có log cảnh báo rõ**, không phải
lỗi ẩn, nhưng là điều một app hướng trẻ em cần biết trước khi chọn provider
AppLovin. Ghi nhận là **rủi ro cần biết, không phải blocker** — nếu app có
audience trẻ em thật, nên chọn AdMob (`tagForChildDirectedTreatment` hoạt
động runtime) thay vì AppLovin.

ATT (iOS): `att_consent.dart` có guard chống gọi chồng
(`_pendingAttRequest`), timeout 20s cho native prompt treo, và điểm rất
tinh vi được 2 vòng codex-review trước xác nhận đúng: guard chỉ được nhả
(`maybeReleaseGuard`) khi CẢ 2 điều kiện `nativeDone` VÀ `resultDone` đều
true — không nhả sớm chỉ vì `Future.timeout()` hết hạn ở phía Dart trong
khi alert hệ thống thật vẫn còn hiển thị. Tôi đọc kỹ logic này và xác nhận
không có đường thoát nào bỏ sót việc set `nativeSettled`/`resultDone` (kể
cả nhánh throw đồng bộ từ `requestAuthorization()` — có `try/catch` riêng
gọi `releaseAttForm()` trước khi rethrow). Logic đúng.

### 4. Trial 1 ngày, chống bypass đổi giờ/xoá cài lại/xoá keychain

`FirstInstallGuard` (`_first_install_guard.dart`) — đọc toàn bộ file:
- **iOS**: cờ "đã cấp" lưu Keychain với `KeychainAccessibility.first_unlock`
  (không phải `.first_unlock_this_device_only`) — cờ này **sống sót qua
  uninstall+reinstall trên cùng thiết bị** (đúng hành vi Keychain mặc định
  của Apple), nên farming bằng xoá-cài-lại trên iOS bị chặn.
  Trade-off đã tài liệu hoá trung thực: cùng chính accessibility level đó
  khiến cờ này cũng sống sót qua restore-từ-backup sang **thiết bị mới**
  (false-positive block một người dùng thật lần đầu mở máy mới nhưng
  restore từ backup máy cũ đã từng nhận grace) — không có giá trị
  accessibility nào chặn được vế "reinstall cùng máy" mà không đồng thời
  gây false-positive vế "restore sang máy mới". Đây là trade-off sản phẩm
  thật, không phải bug, và tài liệu đã nêu rõ cho product owner tự quyết.
- **Android**: **không có chặn ở tầng class này**, dựa hoàn toàn vào
  Android Auto Backup (khôi phục `FlutterSharedPreferences.xml` — file
  chứa cờ grace — nếu app khai `allowBackup=true` + rules đúng, và người
  dùng cùng tài khoản Google + đồng bộ bật). Nếu backup tắt hoặc khác tài
  khoản, **Android trial có thể bị farm vô hạn bằng xoá-cài-lại**. Đây là
  giới hạn đã biết (re-raised độc lập round 39, cùng kết luận): server-less
  design không có cách nào chặn hoàn toàn trên Android mà không cần backend
  — chi phí farm là "1 lần reinstall = 1 ngày ad-free", coi là chấp nhận
  được theo quyết định sản phẩm đã ghi. **Đổi giờ máy**: tôi không thấy
  logic trial dựa trên `DateTime.now()` thô không qua guard clock-rollback
  ở `_first_install_guard.dart`/`ad_preferences` (bản thân cờ này chỉ là
  boolean "đã cấp chưa", không lưu timestamp hết hạn có thể bị lùi giờ) —
  không phát hiện đường bypass bằng đổi giờ máy cho riêng cơ chế grace này.

Kết luận mục 4: hành vi ĐÚNG như thiết kế và tài liệu, không phát hiện lỗ
hổng MỚI. Rủi ro Android farming là **rủi ro đã biết, đã chấp nhận có chủ
đích** — không phải điều tôi coi là blocker mới, nhưng nhắc lại rõ trong
khuyến nghị cuối vì đây là câu hỏi brief hỏi thẳng.

### 5. VIP bằng code, không backend

Đọc toàn bộ `signed_vip_key.dart`, `_redeemed_key_ledger.dart`, lướt các
đoạn trọng yếu của `vip_manager.dart` (1850 dòng — quá lớn để đọc hết trong
1 vòng, nhưng round 60 đã có 1 fork độc lập cố tình "phá" nó và không tìm
được lỗ hổng nào ở `redeemSignedKey()`/`addVip()` stack-cap/`_disposed`
re-check sau mọi await-gap — tôi kiểm tra lại các đoạn đó bằng mắt và đồng ý
với kết luận đó, không tìm ra sai sót).

Xác minh riêng của tôi (không lặp lại round 60):
- **Chữ ký Ed25519 + verify offline đúng cơ chế**: `verifySignedVipKey` giải
  mã base64url, verify chữ ký bằng `Ed25519().verify()` trước khi tin bất
  kỳ trường nào trong payload — không có đường nào đọc `duration`/`kid`
  trước khi verify xong.
- **Không có private key nào bị commit** — tôi grep toàn bộ lịch sử git của
  worktree cho pattern `privateKeyBase64`/`SimplePublicKey`/`-----BEGIN` ở
  mọi commit từng chạm `tool/vip_mint.dart`: không tìm thấy khóa bí mật nào
  bị ghi cứng, kể cả trong các commit cũ. `tool/vip_mint.dart` chỉ **yêu
  cầu** người vận hành cung cấp private key qua input riêng (biến môi
  trường/arg), không lưu key trong repo. Đây là điểm khác biệt quan trọng
  với rủi ro `private_key.pepk` đã biết trong `CLAUDE.md` (khóa ký app Play
  Store, không liên quan tới khóa VIP) — 2 rủi ro độc lập, không nên nhầm
  lẫn khi báo cáo.
- **Replay/dùng lại trên nhiều máy**: tài liệu tự thú nhận đúng giới hạn
  thật của thiết kế không-backend — "leaked key vẫn dùng lại được trên
  NHIỀU thiết bị khác nhau vì không có server theo dõi one-time-use toàn
  cục; ledger (`RedeemedKeyLedger`, cả SharedPreferences lẫn Keychain trên
  iOS) chỉ chặn dùng LẶP LẠI TRÊN CÙNG 1 THIẾT BỊ". Đây không phải lỗi code
  — là giới hạn toán học không thể tránh khi verify hoàn toàn offline
  không backend: một khoá hợp lệ, một khi lộ ra công khai, không ai chặn
  được việc người khác dùng nó trên máy CỦA HỌ, vì không có server nào để
  hỏi "khoá này đã dùng chưa" xuyên thiết bị. CRL (danh sách thu hồi,
  `VipRevocationList`) là cơ chế giảm nhẹ duy nhất khả thi (revoke `kid` cụ
  thể sau khi phát hiện leak) — nhưng đây là tính năng OPT-IN, host app
  phải tự implement `VipRevocationProvider` + tự chạy `Timer.periodic` để
  fetch CRL định kỳ. **Ví dụ đi kèm SDK (`example/`) không demo việc này**
  (xác nhận lại bằng grep — không tìm thấy `VipRevocationProvider`/
  `refreshRevocationList` nào trong `example/lib/`) — nghĩa là một partner
  copy y nguyên app mẫu sẽ có tính năng revoke-key hoàn toàn không hoạt
  động, không nhận ra vì mẫu không nhắc gì tới nó. Đây là finding đã có từ
  round 39, tôi tự kiểm tra lại và xác nhận vẫn đúng hiện trạng ở 3.0.3 —
  **MINOR, tài liệu (không phải code SDK), nhưng đủ quan trọng để nêu lại**
  vì ảnh hưởng trực tiếp tới khả năng ứng phó khi 1 khoá VIP bị lộ.
- **Decompile app rồi tự tạo key hợp lệ**: không khả thi — app chỉ chứa
  public key (Ed25519 public key không giúp forge chữ ký mới), khớp đúng
  tuyên bố trong `CLAUDE.md`.
- **`addVip` stack cap**: đọc `_maxSeconds` (~100 năm, chặn payload input
  phi lý) và cơ chế `AdConfig.maxVipStackDuration` (~90 ngày, clamp tính từ
  `now.add(cap)` — không tích lũy vô hạn qua nhiều lần stack) — khớp đúng
  tài liệu `CLAUDE.md`, không tìm thấy lỗi tính toán.

### 6. Consent toàn cầu + tuân thủ policy

- **GDPR/EEA**: qua Google UMP (`ump_consent.dart`), forward `hasUserConsent`
  cho cả AdMob (`npa`) và AppLovin (`setHasUserConsent`) — nhưng có 1 chi
  tiết tinh vi đúng đắn tôi xác minh: `applyConsentToProviders` **bỏ qua**
  việc set `AppLovinMAX.setHasUserConsent()` theo cờ nội bộ NẾU thiết bị đã
  có sẵn IAB TCF string thật trên storage (`hasIabTcfString`) — lý do đúng:
  AppLovin MAX tự đọc TCF string chuẩn IAB trực tiếp từ platform storage
  khi có CMP thật, set đè lên bằng cờ boolean nội bộ của SDK này có thể làm
  sai lệch vendor-consent thật MAX tự tính. Đây là hiểu biết đúng về tài
  liệu tích hợp AppLovin (không dùng CMP → phải tự set cờ; có CMP → để MAX
  tự đọc TCF string) — không phải lỗi.
- **CCPA + GPP (US state)**: `iab_storage.dart` decode tay bit-packed GPP
  cho US National (MSPA), California (section 8), và toàn bộ 19 section
  bang còn lại (9-27) với offset bit đã ghi rõ đối chiếu thư viện tham
  chiếu `@iabgpp/cmpapi` của IAB Tech Lab. Round 56 sửa lỗi thiếu 1 segment
  khi parse GPP 2-segment — tôi đọc code hiện tại (dòng ~42-91,
  `_gppUsStatesOptedOut`) xác nhận cách split segment đúng, dùng "true
  thắng false" nhất quán giữa các tier (round 40 fix) và trong nội bộ mỗi
  tier (round 37 fix) — không thấy dấu hiệu hồi quy.
- **COPPA**: `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent` cho
  AdMob hoạt động runtime đúng; AppLovin có **giới hạn cấu trúc** (mục 3 ở
  trên) — không có API COPPA runtime, SDK xử lý bằng cách từ chối init
  hoàn toàn thay vì giả vờ hỗ trợ. Đây là lựa chọn conservative đúng
  hướng, đã cảnh báo runtime rõ ràng bằng `SafeLogger.e`.
- **Mọi quốc gia ngoài EEA/US/COPPA-scope**: SDK dựa vào UMP tự phân loại
  EEA/non-EEA (Google's CMP toàn cầu) — không tự suy luận quốc gia
  (`ConsentSettings.country` chỉ dùng cho analytics, không dùng để quyết
  định consent logic, đúng như doc comment tự khai). Đây là cách tiếp cận
  chuẩn ngành (dựa vào CMP được Google chứng nhận thay vì tự chế
  geo-detection) — hợp lý, không phải lỗ hổng.
- Round 67 (ngay trước round này) đã tìm và fix 1 bug MAJOR thật liên quan
  trực tiếp compliance: `ConsentManager._load()` đọc đè giá trị consent cũ
  từ đĩa khi đang có 1 lần `set()`/`reset()` khác chạy dở — khiến người
  dùng ĐÃ đồng ý bị áp dụng ngược lại thành "từ chối" cho AppLovin/AdMob dù
  đĩa vẫn lưu đúng. Tôi đọc code sau fix
  (`consent_manager.dart` — `_load()` giờ `await _persistLock` trước khi
  đọc đĩa) và test regression `test/consent_manager_reload_race_test.dart`
  — xác nhận fix đúng cơ chế, không phải patch bề mặt.

## Test đã chạy

- `flutter analyze` (worktree, `packages/ad_sdk`): **0 issues**.
- `flutter test` (worktree, `packages/ad_sdk`): **2205/2205 passing**,
  `All tests passed!` — khớp con số CHANGELOG 3.0.3 công bố.
- `git log --all` cho pattern private-key: xác nhận `private_key.pepk` chỉ
  tồn tại ở đúng 1 commit lịch sử (`60a1f3d`, đã biết, đã ghi trong
  `CLAUDE.md`, chưa cần hành động vì repo còn private) — **không có khóa
  Ed25519 VIP nào từng bị commit**, khác hẳn rủi ro pepk.

## Rủi ro/giới hạn đã biết, KHÔNG coi là blocker mới (liệt kê lại có kiểm
chứng độc lập, không chỉ tin tài liệu)

1. Android trial có thể bị farm bằng uninstall+reinstall nếu Auto Backup
   tắt/khác tài khoản — chấp nhận có chủ đích, chi phí farm = 1 reinstall/
   1 ngày.
2. VIP key bị lộ vẫn dùng được trên NHIỀU thiết bị khác (không có server
   one-time-use toàn cục) — giới hạn toán học của thiết kế không-backend,
   giảm nhẹ bằng CRL opt-in.
3. Ví dụ SDK không demo CRL/`VipRevocationProvider` — partner copy nguyên
   app mẫu sẽ không có khả năng revoke key leak, không biết vì không được
   nhắc.
4. AppLovin không hỗ trợ COPPA runtime — app hướng trẻ em phải dùng AdMob,
   không dùng AppLovin.
5. `private_key.pepk` (Play signing key, KHÔNG liên quan VIP) còn truy xuất
   được từ git history — đã có kế hoạch xử lý ghi trong `CLAUDE.md`, chờ
   repo mở rộng quyền truy cập mới cần hành động.
6. Keychain-based trial/VIP-redeem guard trên iOS có 1 false-positive biết
   trước: user restore backup cũ (đã từng nhận grace) sang máy mới bị chặn
   nhận lại grace — trade-off sản phẩm, không phải bug.

Không mục nào trong 6 điều trên là phát hiện MỚI của tôi — tất cả đã có
trong lịch sử audit (round 31/39/42/49/60) và tôi tự đọc code xác nhận vẫn
đúng hiện trạng ở 3.0.3, không có hồi quy.

## Khuyến nghị cuối

**SDK 3.0.3 CÓ THỂ dùng cho production app**, với điều kiện app tiêu thụ
biết và chấp nhận 6 rủi ro/giới hạn đã liệt kê ở trên (đều là giới hạn kiến
trúc có chủ đích, có tài liệu, không phải lỗi ẩn). Không tìm thấy blocker
MAJOR mới nào trong lần audit độc lập này, trên cả 6 khía cạnh chức năng
brief yêu cầu. `flutter analyze` sạch, toàn bộ 2205 test pass, không có
private key nào (VIP hay ngược lại) bị lộ trong worktree đang xét.

Nếu phải chọn 1 việc làm tiếp theo trước khi ship cho 1 app cụ thể (không
phải blocker của package, mà là việc tích hợp): nếu app đó coi trọng khả
năng thu hồi VIP key bị leak, hãy tự implement `VipRevocationProvider` +
`Timer.periodic` gọi `refreshRevocationList` — đừng dựa vào việc "SDK có
tính năng CRL" mà quên rằng nó là opt-in và ví dụ đi kèm không bật sẵn.

Về mặt phương pháp: sau 68 vòng audit (67 vòng trước + vòng này), bề mặt dễ
tìm bug đã được rà rất kỹ; các phát hiện MAJOR gần đây (round 60, 65, 67)
đều là race condition tinh vi ở biên async, không phải lỗi thiết kế lớn.
Điều đó phù hợp với 1 codebase đã trưởng thành, không phải dấu hiệu audit
đang "bịa" ra vấn đề để có việc làm.
