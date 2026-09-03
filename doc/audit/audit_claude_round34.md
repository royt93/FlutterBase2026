# Audit round 34 — applovin_admob_sdk v2.9.15 (Claude, độc lập)

Ngày: 2026-09-03. Phương pháp: đọc trực tiếp source (không tin CHANGELOG/comment),
verify cơ chế bằng tính tay + test thật + `flutter analyze`/`flutter test` trên máy,
grep chéo toàn bộ `lib/` (31.390 dòng, ad_manager.dart một file 7.642 dòng).

**Kết quả chạy thật (không suy đoán):**
- `flutter analyze` → *No issues found!*
- `flutter test` → **1571/1571 pass** — khớp con số CHANGELOG round 33 công bố (đã tự
  kiểm chứng, không chỉ tin lời khai).

## Tóm tắt kết luận

Codebase này đã qua 33 vòng audit liên tục, và ở vòng 34 tôi **không tìm được
BLOCKER/MAJOR mới** trong 8 trục bắt buộc sau khi đọc kỹ (không chỉ pattern-match)
các cơ chế lõi: consent (GDPR/CCPA/GPP/COPPA/ATT), VIP Ed25519, trial-mode
anti-bypass, dispose/lifecycle của adapter và widget, connectivity watch,
mediation/dual-provider parity. Điều này **khớp** với việc 32 vòng trước đã đóng
gần hết các lỗ hổng dễ tìm — không có nghĩa là SDK hoàn hảo, mà có nghĩa là ngân
sách audit của tôi không đủ để vượt qua mức độ đã được cày quá kỹ này bằng
grep+read tĩnh. Tôi có 1 finding MỚI thật (không phải re-hash của round cũ):
**một file khoá ký ứng dụng Android (Play App Signing PEPK export) đã từng bị
commit vào git history của repo này** (mục MINOR/MAJOR bên dưới, hạng mục #5/#7).

## 1. Dual-provider AdMob/AppLovin, parity Android/iOS

- `grep -rn "Platform.isIOS\|Platform.isAndroid" lib/src/adapters/*.dart` → **0 kết
  quả** trong `applovin_adapter.dart` và `admob_adapter.dart`: không có nhánh logic
  lệch giữa 2 nền tảng ở tầng Dart — khác biệt platform được cô lập hết vào plugin
  native (`applovin_max`, `google_mobile_ads`), đúng kiến trúc mong muốn.
- `gma_bridge.dart`/`applovin_bridge.dart` trừu tượng hoá callback fullscreen thành
  interface Dart thuần (`GmaFullscreenAd`, `GmaShowCallbacks`) — cho phép test mock,
  không phụ thuộc type sinh ra từ generic `FullScreenContentCallback<T>` của GMA.
- Version pin thật trên đĩa (`example/ios/Podfile.lock`): `applovin_max (4.6.4)` ↔
  `AppLovinSDK (= 13.6.3)` — khớp đúng như CLAUDE.md mô tả, không có version-drift.
- **Không tự chạy được integration_test trên simulator/emulator thật** trong phiên
  này (không có thiết bị/simulator khả dụng trong sandbox) → phần "hoạt động đúng
  trên thiết bị thật" của trục này **chưa được tôi tự kiểm chứng**, chỉ xác nhận qua
  đọc code + 1571 unit/widget test xanh.

## 2. Online/offline, connectivity, không treo UI

- `_startConnectivityWatch()` (ad_manager.dart:7424) dùng generation token
  (`_connectivityWatchGen`) để chống race 2 lần init chồng nhau ghi đè
  `_connectivitySub` của nhau (leak subscription) — đọc kỹ logic, guard đúng: lời
  gọi thua cuộc bail ra trước khi gán `_connectivitySub`.
- `_stopConnectivityWatch()` (dòng 7460) cancel cả `_connectivitySub` lẫn
  `_reconnectDebounceTimer`, được gọi từ `destroy()` (dòng 5348) — không rò rỉ khi
  SDK bị teardown giữa chừng lúc network watch đang khởi tạo (đã đọc toàn bộ
  `_destroy()` từ đầu, mọi Timer sinh ra trong file đều có điểm cancel tương ứng:
  `_consentDialogTimer`, `_splashBudgetTimer`, `_consentGateRecoveryRetry`,
  `_initRetryTimer`, `_resumeFallbackTimer`, `_reconnectDebounceTimer`,
  `_retryGen`/`_stopAdRetryTimer` — verify bằng grep đối chiếu từng field).
- 20s timeout bọc quanh `_connectivityInit()` (dòng 7442) — plugin treo không làm
  treo SDK vĩnh viễn.

## 3. Vòng đời từng loại ad + không leak

- Rà toàn bộ `Timer(`/`StreamSubscription<` trong `ad_manager.dart` (16 điểm) đối
  chiếu với đường huỷ trong `_destroy()`/`_resetGuardState()` — khớp 100%, không có
  timer mồ côi.
- `vip_redeem_screen.dart` (ví dụ dispose phức tạp nhất, có 3 `AnimationController`,
  1 `ConfettiController`, 2 `Timer.periodic`, 1 `StreamSubscription`): `dispose()`
  (dòng 230-243) huỷ **đủ cả 7** — kiểm tra từng field bằng grep tên biến, không
  thiếu cái nào.
- Round-33 fix "AppLovin late-callback guard" (banner/MREC/native) — **verify thủ
  công, không chỉ tin log commit**: đọc diff thật của
  `banner_ad_widget.dart`/`mrec_ad_widget.dart`/`native_ad_widget.dart` +
  `applovin_ad_revenue.dart`. Cơ chế: `ownerKey` (chính State object) được truyền
  vào view con; callback `onAdRevenuePaidCallback` so `AdManager().bannerAdViewId(
  ownerKey).value` (adViewId AdManager coi là "còn sống" cho state này) với
  `adViewId` mà closure đã capture tại thời điểm build — nếu widget đã reload sang
  adViewId mới thì closure cũ bị `isStaleAppLovinCallback` chặn, không double-count
  revenue. Logic đúng, không có lỗ hổng identity-confusion rõ ràng.

## 4. Trial mode 1 ngày (First-Install Grace)

- `_first_install_guard.dart`: iOS dùng Keychain flag
  (`KeychainAccessibility.first_unlock`) sống sót qua uninstall → chặn được vòng
  lặp uninstall/reinstall để lấy lại grace. Android **không có** backstop cấp
  class — dựa hoàn toàn vào Android Auto Backup khôi phục file
  `FlutterSharedPreferences.xml` (best-effort, chỉ hoạt động nếu cùng thiết bị +
  cùng tài khoản Google + backup bật).
- **Đây KHÔNG phải finding mới** — README.md dòng 61-71 đã công khai đúng y hệt
  bảng "Bypass-result matrix" trong code comment, kèm khuyến nghị. Tôi tự đọc code
  độc lập rồi đối chiếu README, khớp 100% — tài liệu không nói dối về giới hạn này.
- Xoá dữ liệu app ("Clear data") trên **cả 2 nền tảng** đều reset được trial — đây
  là giới hạn vật lý không thể fix bằng client-only mà không có server, được ghi
  nhận trung thực, không che giấu.
- Đồng hồ hệ thống lùi lại: `vip_manager.dart` có cơ chế high-water-mark chống
  rollback (dòng ~280-370) dùng `Stopwatch` (monotonic per-process) đối chiếu với
  wall-clock đã lưu, tự phát hiện khi 2 nguồn lệch nhau do chỉnh giờ thủ công. Giới
  hạn còn lại (clock chỉnh TRƯỚC lần chạy app đầu tiên, hoặc app bị kill hoàn toàn
  giữa lúc chỉnh giờ) được chính code thừa nhận là bất khả thi trong Dart thuần —
  khớp với memory nội bộ về "MJ9 clock fix" đã biết từ trước.

## 5. VIP kích hoạt bằng code, không server

- `signed_vip_key.dart`: Ed25519 verify qua thư viện `cryptography` (không tự chế
  crypto). Payload AVP2 gồm `seconds|kid|expiresAt|bundleId`, ký toàn bộ — không
  trường nào có thể sửa mà chữ ký còn hợp lệ. Domain-separation cho CRL
  (`_crlSignedMessage` thêm prefix `"CRL1|"` trước khi ký/verify) đúng đắn: nếu
  không có bước này, 1 CRL công khai (không cần bí mật) có thể bị dán nhãn lại
  thành `AVP1.<payload>.<sig>` và redeem như 1 VIP key thật — vì cả 2 format đều
  tách đúng 2 trường bằng dấu `|`. Đã đọc kỹ, cơ chế chặn đúng bản chất tấn công.
- Private key **không có trong `tool/vip_mint.dart`** — chỉ nhận qua tham số CLI
  `--priv`, không hardcode. `git log -p` trên `vip_mint.dart`/`vip_crl_mint.dart`
  qua toàn bộ lịch sử — không thấy seed/private key nào bị commit.
- Chống replay per-device: `_redeemed_key_ledger.dart` — ghi chuỗi (write-chaining
  qua `_writeChain`/`_writesInFlight` static) chống 2 lần redeem đồng thời ghi đè
  nhau (đã có 2 vòng audit trước sửa race này, đọc lại thấy đúng). Nhưng **chỉ có
  hiệu lực trên iOS** (Keychain) — Android hoàn toàn dựa vào `SharedPreferences`,
  nghĩa là 1 key đã redeem có thể bị dùng lại sau khi uninstall+reinstall trên
  Android. Đây cũng là giới hạn **đã công bố** (README dòng 61-71), không phải lỗ
  hổng ẩn.
- **Finding MỚI (chưa xuất hiện trong audit trước, verify bằng git log thật)**:
  file `android/app/private_key.pepk` (đây là **PEPK export của Android Play App
  Signing key** — không liên quan Ed25519 VIP, mà là khoá ký app để nộp Play
  Store) đã bị **commit thẳng vào git history** ở commit `60a1f3d` (2024-12-20,
  message "up"), thời điểm trước khi host app tách ra repo riêng. File này **không
  còn trong HEAD hiện tại** (đã bị xoá ở một commit sau đó) nhưng **vẫn nằm vĩnh
  viễn trong lịch sử git** — `git cat-file -p 60a1f3d:android/app/private_key.pepk`
  vẫn lấy ra được nội dung file với bất kỳ ai có quyền clone repo.
  - Mức độ nghiêm trọng: **MINOR-MAJOR** (không phải BLOCKER) — file `.pepk` là
    blob đã được **mã hoá bằng public key của Google** (định dạng PEPK dùng để
    upload khoá ký cho Play App Signing), nên **không tự nó bị giải mã/dùng được**
    nếu không có private key phía Google. Rủi ro thực tế phụ thuộc vào: (a) repo
    có đang **private** hay không (README xác nhận "repo is private" — giảm rủi ro
    hiện tại), (b) file có từng được dùng để upload khoá ký thật cho 1 app đã phát
    hành hay không.
  - Đề xuất: xác minh xem khoá này đã từng dùng để đăng ký Play App Signing cho
    app thật chưa; nếu có, cân nhắc rotate khoá ký qua Play Console (Google hỗ trợ
    key-upload-key rotation) như biện pháp phòng ngừa, và purge file khỏi git
    history (`git filter-repo` hoặc BFG) trước khi repo có khả năng đổi sang public
    hoặc thêm collaborator không tin cậy. Không phải việc sửa trong code SDK, nên
    không thể tự tôi fix trong phạm vi audit read-only này.
  - Phạm vi: đây là tàn dư từ khi host app còn sống trong repo này (theo
    CLAUDE.md, giờ đã tách repo riêng) — không liên quan trực tiếp đến
    `packages/ad_sdk`, nhưng vẫn nằm trong cùng git history nên tôi báo cáo ở đây
    thay vì bỏ qua.

## 6. Consent mọi quốc gia

- **GDPR/UK**: `ad_consent.dart` forward `hasUserConsent`/`npa` cho cả 2 network;
  KHÔNG tự relay raw TCF string — dựa vào việc AppLovin MAX SDK tự đọc thẳng
  `IABTCF_*` từ native storage do UMP ghi (đã đọc doc comment + xác nhận logic hợp
  lý: đây là cách chính thức Google UMP + AppLovin CMP đồng bộ mà không cần code
  cầu nối thủ công).
- **CCPA/CPRA + GPP US-state (round 33 — tự verify lại bằng tay, không tin
  test xanh)**: `IabStorage.usPrivacyOptedOut()` fallback sang decode section GPP
  US National (`IABGPP_7_String`) khi thiếu legacy US Privacy string. Tôi **tự tay
  giải mã bit** 2 fixture test (`CAAYAAAAAABA`, `CAAkAAAAAABA`) theo đúng thuật
  toán `_GppBitReader` (base64url 6-bit/ký tự, MSB-first) và **khớp chính xác**
  kỳ vọng của test (`SaleOptOut=1` → opted out; `SharingOptOut=1,SaleOptOut=2` →
  vẫn opted out; cả hai `=0` → null). Thứ tự field trong Core Segment
  (`Version(6)` + 6 Notice field × 2 bit + `SaleOptOut(2)` + `SharingOptOut(2)`)
  khớp đúng layout MSPA US National Core Segment thật. Đây là 1 trong số ít fix
  của round 33 tôi kiểm chứng được **độc lập bằng toán học**, không chỉ nhìn test
  pass — kết luận: **fix đúng, không phải patch giả**.
- **COPPA**: AppLovin MAX 4.x xác nhận (qua code + comment) không có API nhận tín
  hiệu child-directed runtime — SDK log cảnh báo `SafeLogger.w` khi
  `isAgeRestrictedUser=true` set giữa phiên, và có "COPPA hard-stop" test riêng
  (`ad_manager_core_test.dart` group `COPPA hard-stop`) chặn hẳn AppLovin thay vì
  chỉ log — đã đọc code, đúng như tên gợi ý (hard-stop thật, không phải chỉ
  warning).
- **ATT (iOS)**: `att_consent.dart` — có timeout 20s chống prompt treo vô hạn (case
  quan sát thật trên Simulator), có ref-count `markUmpFormOnScreen()` để App Open
  fullscreen (kể cả bản `bypassSafety: true` ở splash) không đè lên system ATT
  alert — dùng lại đúng cơ chế đã có cho UMP form thay vì viết cơ chế song song
  (giảm bug-surface). Release cleanup gắn vào **raw future chưa timeout** (không
  phải future đã `.timeout()`), lý do ghi rõ: `Future.timeout` chỉ dừng phía Dart
  chờ, alert native vẫn còn hiện — nếu gắn nhầm vào future đã timeout thì
  `markUmpFormOnScreen` release sớm trong khi alert thật vẫn án ngữ màn hình.
  Verify logic đúng.
- **Đồng bộ khi rút consent (withdraw)**: `ConsentManager.reset()` — có comment
  round-29 xác nhận đã sửa lỗi zero hoá nhầm cờ COPPA/CCPA (giữ nguyên qua reset,
  chỉ xoá phần "đã hỏi chưa"/"đồng ý cá nhân hoá"), và **luôn** gọi
  `_applyToProviders` (không còn documented-nhưng-không-thật-sự-optional như bug
  cũ). `ad_consent.dart` chỉ ghi nhận "đã áp dụng cho provider" khi **cả 2** nhánh
  AppLovin+AdMob apply thành công (round-32 fix) — đọc code xác nhận đúng: biến
  `appLovinApplied`/`adMobApplied` đều phải `true` mới set `_lastAppliedToProviders`.

## 7. Tuân thủ chính sách AdMob/AppLovin

- Không thấy test ad unit ID (`ca-app-pub-3940256099942544...`) nào bị dùng làm ID
  thật trong code production — chuỗi đó chỉ xuất hiện trong `ad_manager.dart` như
  **guard phát hiện** config sai (cảnh báo nếu host lỡ cấu hình test ID vào production
  config), không phải leftover.
- Native ad widget vẽ nhãn "Ad" thủ công cho AppLovin (AdMob dùng template tự vẽ
  AdChoices) — đáp ứng yêu cầu ghi nhãn quảng cáo của cả 2 network.
- App Open không chồng lên modal: `showAppOpenAdOnResume` check
  `AdScreenRouteLogger.isDialogOnTop` (đã xác nhận đúng theo mô tả CLAUDE.md, đọc
  lướt phần liên quan trong `ad_manager.dart` khớp).
- **Chưa kiểm tra sâu** trong lượt này: mã native Android/iOS thực tế (Kotlin/Swift
  bên trong `applovin_max`/`google_mobile_ads` trên pub-cache) để tìm CVE đã biết —
  không có kết nối internet trong sandbox để tra cứu advisory database, nên phần
  "SDK native có pin version có lỗ hổng bảo mật đã biết không" **để ngỏ, không kết
  luận**. Chỉ xác nhận version pin nhất quán giữa pubspec/CLAUDE.md/Podfile.lock
  thật trên đĩa (`applovin_max 4.6.4` ↔ `AppLovinSDK 13.6.3`) — không có drift.

## 8. Ví dụ tích hợp (`packages/ad_sdk/example`)

- `example/lib/main.dart`: `AdManager().setNavigatorKey(_navigatorKey)` gọi
  **trước** `runApp` (dòng 56/73) — đúng hợp đồng README.
  `navigatorObservers: [adRouteObserver, AdScreenRouteLogger()]` được đăng ký
  (dòng 78) — đúng.
- Splash (`initState`, dòng 724-799): thứ tự đúng —
  `markSplashActive()` → `incrementSplashCount()` → đăng ký `SimpleEventBus`
  listener **trước** khi gọi `initialize()` (comment giải thích rõ lý do: EventBus
  chỉ replay cho listener đã đăng ký trước) → ATT → UMP → `initialize()`. Có hard-cap
  timer 8s chống splash treo vĩnh viễn nếu init không bao giờ hoàn tất.
  `AdLoadingDialog.showAdBuffer()` gọi trước `showAppOpenAd(bypassSafety: true)`
  (dòng 808→823) — đúng thứ tự CLAUDE.md yêu cầu.
- `_goHome()` (dòng 831-844): remove listener EventBus (`SimpleEventBus().remove`),
  cancel `_hardCap` — dọn dẹp đúng, không leak listener khi splash bị bỏ qua giữa
  chừng (ví dụ do hard-cap timer bắn trước khi ad load xong).
- Không đọc hết toàn bộ 3028 dòng `main.dart` (chỉ đọc vùng liên quan hợp đồng
  tích hợp) — các phần UI/demo khác của file **chưa được rà kỹ**.

## Việc CHƯA kịp làm trong ngân sách vòng này (khai báo minh bạch, không giấu)

- Không chạy `integration_test/` thật trên emulator/simulator (không có thiết bị
  trong sandbox) — mọi kết luận về hành vi runtime dựa trên đọc code + 1571
  unit/widget test tĩnh, không phải quan sát trên thiết bị thật.
- Không tra cứu CVE database cho `AppLovinSDK 13.6.3` / `google_mobile_ads`
  native SDK version (không có internet trong phiên).
- Không đọc sâu `compliance/` (ad_event_log.dart, compliance_signing.dart,
  incident_recorder.dart — cơ chế hash-chain tamper-evidence) và
  `monetization/` (waterfall_tuner, monetization_arbitrator, self_healing_observer)
  — các module này tồn tại và có tên gợi ý logic phức tạp, nhưng nằm ngoài 8 trục
  bắt buộc và ngân sách audit không còn đủ để đọc kỹ thêm ~3000 dòng nữa một cách
  adversarial thật sự (chỉ lướt tên hàm sẽ chỉ là pattern-match, việc prompt này
  yêu cầu tránh).
- Không đọc `vip_manager.dart` (1779 dòng) toàn bộ — chỉ đọc phần liên quan clock
  rollback đã có sẵn trong memory nội bộ từ trước; các nhánh khác (VIP stacking,
  `bypassVipGuard`, revocation refresh scheduling) **chưa được tôi tự audit lại từ
  đầu** vòng này.

## Kết luận cuối

**Có thể dùng cho production app**, với 2 điều kiện:

1. Xử lý finding #5 (file `.pepk` trong git history) trước khi mở rộng quyền truy
   cập repo (thêm collaborator, chuyển CI sang dịch vụ third-party, hoặc cân nhắc
   public hoá) — xác minh khoá có từng active trên Play Console không, rotate nếu
   có, rồi purge lịch sử git.
2. Chấp nhận rõ ràng giới hạn đã tự SDK công bố (README "Known limitations"): VIP/
   trial anti-bypass yếu trên Android (chỉ mitigated, không eliminated), và
   AppLovin's fire-and-forget consent APIs không thể được `await` để xác nhận
   thành công thật sự ở tầng platform-channel (đã document, không phải bug ẩn).

Ngoài 2 điều kiện trên, việc đọc kỹ + verify độc lập (không chỉ tin CHANGELOG) cho
thấy SDK này có kỷ luật kỹ thuật cao hiếm thấy cho một dependency-level package:
mọi Timer/Subscription có điểm huỷ tương ứng, mọi claim "đã fix" ở round 33 mà
tôi tự tay verify lại (GPP bit-parsing, late-callback guard) đều **đúng thật**,
không phải fix hời hợt để qua audit. Rủi ro còn lại nằm ở phạm vi **ngoài kiểm
soát của code Dart** (native SDK CVE, hành vi runtime thật trên thiết bị, và tàn
dư git history từ trước khi tách repo) — đúng như tinh thần "không có SLA, single
maintainer" mà README đã tự nhận.
