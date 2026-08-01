# Audit toàn diện `applovin_admob_sdk` + example

**Auditor:** Codex

**Ngày audit lại:** 2026-08-01

**Phạm vi:** `packages/ad_sdk`, `packages/ad_sdk/example`, host integration liên quan và phiên bản public trên pub.dev.

**Phiên bản đối chiếu:** local package `1.2.2`; pub.dev cũng đang hiển thị `1.2.2` là latest.
**Kết quả chạy trực tiếp:** `flutter test` SDK: **676 tests passed**; `flutter analyze` SDK: **1 warning**; `flutter analyze` example: **No issues found**.

## Verdict ngắn

**Không nên bật production traffic ngay lập tức. Có thể dùng cho production theo điều kiện, sau một pilot nhỏ và hoàn tất checklist bên dưới.**

SDK có kiến trúc tốt, state machine và teardown khá kỹ, hỗ trợ AdMob/AppLovin trên Android+iOS, offline-safe, 24-hour first-install grace, signed VIP key và UMP/ATT plumbing. Tuy nhiên không SDK nào có thể tự bảo đảm tài khoản AdMob/AppLovin không bị policy enforcement: placement, traffic, consent message trên dashboard, app-ads.txt, privacy policy, age audience và cấu hình ad unit vẫn là trách nhiệm của app publisher.

## 1. Ma trận yêu cầu

| Yêu cầu | Kết quả audit | Ghi chú |
|---|---|---|
| AdMob Android+iOS | **Đạt về code** | `AdMobAdapter`, per-platform IDs, GMA RequestConfiguration và test behavior đều có. Production App ID/ad units vẫn phải thay từ test IDs. |
| AppLovin Android+iOS | **Đạt có điều kiện** | `AppLovinAdapter` có lifecycle/listener/widget teardown; SDK key truyền runtime. Child-user case phải chặn trước init. |
| Có mạng/không mạng | **Đạt theo semantics đúng** | Offline không cố request/show ad; cached ad không được xem là luôn có thể show. Reconnect có refill gate. App vẫn phải hoạt động đầy đủ khi không có ads. |
| Banner / MREC | **Đạt có điều kiện** | Route pause/resume, native view disposal và VIP suppression có test. Cần QA placement để tránh click nhầm gần controls. |
| App Open | **Đạt có điều kiện** | Có splash budget và show watchdog 90s; resume guard tránh chồng modal/ads. Không đặt App Open trên banner hoặc sau khi user đã bắt đầu tương tác. |
| Interstitial | **Đạt có điều kiện** | Có preload, frequency/safety gate và reject khi fullscreen đang show. Không có hard watchdog nếu native SDK không callback dismiss/fail. |
| Rewarded | **Đạt có điều kiện** | Reward chỉ từ callback earned; có re-entrancy guard và on-demand VIP path. Client callback không phải bằng chứng chống gian lận nếu không dùng SSV. |
| Trial 1 ngày | **Đạt có điều kiện** | Release mặc định 24h; debug mặc định 30s. iOS guard sống qua reinstall; Android vẫn phụ thuộc Auto Backup/account/device state. |
| VIP by code không backend | **Đạt về cryptography, không đạt one-time toàn cầu** | Ed25519 signed key không thể forge nếu private key không lộ, nhưng Android uninstall/reinstall có thể replay cùng key. Không thể giải quyết triệt để nếu không có backend. |
| Consent mọi quốc gia | **Đạt khi host tích hợp đúng CMP** | UMP/ATT/AppLovin flags có plumbing; built-in binary dialog không thay thế Google-certified CMP cho EEA/UK. |
| Policy AdMob/AppLovin | **Không thể tự chứng nhận** | Safety heuristics giảm rủi ro rõ ràng nhưng không thay thế policy review, traffic quality, dashboard setup và manual QA. |
| Pub.dev Android platform | **Chưa đạt metadata** | Trang latest `1.2.2` ngày 2026-08-01 chỉ hiển thị platform iOS. Source có Android implementation, nhưng package metadata/scoring không chứng minh Android support; phải sửa để pub.dev nhận diện Android trước khi quảng bá hỗ trợ chính thức. |

## 2. Điểm mạnh đã xác minh

### Provider và lifecycle

- Adapter contract dùng chung cho AdMob và AppLovin; provider được chọn app-wide tại init, không tự động fallback runtime.
- Fullscreen slots có state transitions, không cho show khi chưa ready/đang show/VIP/offline/consent blocked.
- AdMob `dispose()` giải phóng App Open, interstitial, rewarded, banner, MREC, native và callback pending.
- AppLovin `dispose()` clear native listeners trước, destroy widget ad views, reset slots/notifiers và xoá callback pending.
- `AdManager.destroy()` dừng retry/connectivity timers, remove lifecycle observer, detach slot watchers, dispose VIP/arbitrator/fill-rate monitor và recreate event stream.
- `AdScreenState` có disposed guard. Example tự dispose các `ValueNotifier`, `Timer`, controller.
- 676 unit/widget tests bao phủ offline/reconnect, consent persistence, provider behavior, VIP expiry/stacking, double redeem và teardown.

### Offline behavior

`isConnected` được dùng ở preload/show gates và connectivity watcher refill khi mạng trở lại. Đây là behavior đúng: **offline mode nghĩa là app không crash và không cố gọi ad**, không phải “ads vẫn có thể tải mới không cần mạng”. Host cần hiển thị UX no-fill/offline tự nhiên, không chặn chức năng chính vì ad.

### Consent plumbing

- iOS ATT được gọi trước UMP trong example.
- UMP request/update, form dismiss và Privacy Options đều có timeout 20s để không treo splash hoặc settings.
- `canRequestAds` được dùng làm gate riêng; `setConsent()` trước `initialize()` được buffer và persist, tránh consent mới bị dữ liệu cũ ghi đè.
- AppLovin `setHasUserConsent` và `setDoNotSell` được gọi trước native init trong flow chuẩn.
- AdMob maps COPPA qua `tagForChildDirectedTreatment`, CCPA opt-out qua RDP và non-personalized qua per-request `npa`.
- Example có Privacy Options entry point và `Info.plist` có ATT usage description + 152 SKAdNetwork IDs.

### VIP và trial

- Trial release `FirstInstallVipGrace.auto` là 24h; debug là 30s để QA.
- Signed key format `AVP1` dùng Ed25519; public key có thể ship, private key không được ship.
- Có chống double-tap/same-process redeem và ledger iOS Keychain.
- VIP expiry timer refresh active state và preload lại slots sau khi VIP hết hạn.

## 3. Findings cần xử lý

### C0 — Medium release gate: SDK hiện không còn `flutter analyze` sạch

Lần chạy ngày 2026-08-01 trả về `invalid_use_of_visible_for_testing_member` tại `lib/src/core/ad_manager.dart:1020`: `AdManager.initialize()` truyền tham số `isRelease` vào constructor `VipManager`, nhưng member đó được đánh dấu chỉ dùng nội bộ file/test. Đây không phải lỗi runtime, nhưng làm sai tuyên bố “analyze sạch” và sẽ làm CI fail nếu warning được nâng thành fatal.

**Khuyến nghị:** thay test seam bằng abstraction build-mode nội bộ hợp lệ hoặc điều chỉnh annotation/scope; bắt buộc `flutter analyze` zero issue trước publish tiếp theo.

### C1 — High: consent provider-apply đang fail-open

`applyConsentToProviders()` bắt exception của cả AppLovin và AdMob rồi chỉ log warning. `initialize()` vẫn tiếp tục tới preload/show. Nếu native privacy flag update thất bại, ad request có thể chạy với state cũ/default thay vì state vừa chọn.

**Tác động:** compliance risk trong jurisdiction yêu cầu consent; đặc biệt nguy hiểm khi lỗi native/platform channel bị coi như thành công ở Dart.

**Khuyến nghị:** trả về structured result hoặc throw `ConsentApplyException`; không preload ad cho tới khi provider privacy state được xác nhận. Nếu muốn fail-safe, chuyển sang “no ad” khi apply consent thất bại, retry sau khi provider ready. Thêm test mô phỏng MethodChannel error cho cả hai provider.

### C2 — High cho child/mixed audience: AppLovin child-user edge case ở first install

AppLovin MAX 4.x không có runtime child-directed API. Code chặn AppLovin init nếu `isAgeRestrictedUser=true` đã biết trước init, nhưng app mới cài chưa có persisted consent thì flag mặc định là `false`; một app luôn hướng tới trẻ em có thể initialize AppLovin ở install đầu tiên.

**Tác động:** không dùng SDK này cho Kids/child-directed/mixed audience nếu host chưa có explicit app-level child policy trước `initialize()`. AppLovin chính thức cấm initialize/use MAX cho child user.

**Khuyến nghị:** thêm config bắt buộc như `audiencePolicy: childDirected | general | mixed`; với child/mixed, không initialize AppLovin ở mọi install và route sang provider/monetization được phép. Với app WiFi stress tester hiện tại, đây là điều kiện phân loại audience, không phải blocker nếu app thực sự general-audience.

### C3 — High: UMP/CMP không thể mặc định coi là “mọi quốc gia đã compliant”

Built-in Cupertino dialog là UX binary Allow/Reject, không phải Google-certified IAB CMP cho EEA/UK. SDK đã có UMP wrapper, nhưng host phải gọi đúng thứ tự và publish message trong AdMob Privacy & Messaging cho **đúng từng AdMob App ID**. AppLovin cũng yêu cầu consent values trước initialization; nếu dùng Google UMP thì cần để MAX đọc TCF/Additional Consent đúng cách và không hiển thị hai CMP chồng nhau.

**Tác động:** cấu hình code pass chưa chứng minh consent production. Non-EEA cũng còn CCPA/US state opt-out, privacy policy, age signal và user-facing Privacy Options obligations.

**Khuyến nghị:** release gate bắt buộc: ATT → UMP → `canRequestAds` → provider init; verify live EEA/UK/CH/US state test cases; publish UMP message; show durable Privacy Options; kiểm tra MAX Mediation Debugger và AdMob Ad Inspector.

### C4 — Medium: signed VIP không chống replay Android uninstall/reinstall

Đây là giới hạn không thể tránh hoàn toàn khi không có backend. iOS ledger dùng Keychain; Android ledger durable là no-op, còn SharedPreferences có thể bị xoá khi uninstall. Android Auto Backup giảm replay trong một số trường hợp nhưng không bảo đảm cho khác account, backup tắt hoặc reset thiết bị.

**Khuyến nghị:** coi signed VIP là coupon có thể bị leak/replay, không phải entitlement one-time toàn cầu. Không dùng cho quyền lợi có giá trị cao nếu không có server; đặt `maxVipStackDuration`, duration ngắn và telemetry. Private signing key phải nằm ngoài repo/CI artifact.

### C5 — Medium: rewarded client callback không phải reward authority

Không có backend thì `onEarnedReward` vẫn có thể bị patch/hook ở client. SSV chỉ thực sự bảo vệ khi callback URL backend xác minh postback của AdMob/AppLovin và backend cấp reward.

**Khuyến nghị:** coin/entitlement quan trọng chỉ grant sau SSV. Nếu không backend, giới hạn reward ở benefit local, không gọi là secure/policy-proof.

### C6 — Medium: interstitial/rewarded chưa có hard timeout đối xứng App Open

README/source thừa nhận native SDK có thể không gọi dismiss/fail; App Open có watchdog 90s nhưng interstitial/rewarded không có hard watchdog tương tự. Slot/call-site có thể chờ vô hạn trong lỗi native hiếm.

**Khuyến nghị:** thêm per-show timeout có generation token; timeout phải resolve callback là skipped, reset slot safely và không tự grant reward. Đây là reliability gap, không phải bằng chứng hiện tại của memory leak.

### C7 — Medium: safety heuristics không phải policy shield

Daily/hour/session caps, CTR heuristic, click-spam detection và cooldown là defense-in-depth do package tự xây. Google nói publisher vẫn chịu trách nhiệm với invalid traffic; AppLovin cũng yêu cầu publisher tự chịu trách nhiệm privacy/policy.

**Khuyến nghị:** giữ `AdSafetyParams.production` ở release; không bật `QA_AD_STRESS`/999 caps/CTR bypass trong production; dùng test ad/test devices; theo dõi invalid traffic, ad serving limit, crash và policy center.

### C8 — Medium: native production coverage chưa đầy đủ

Unit/widget tests không chứng minh toàn bộ native creative lifecycle. README của package ghi rõ một số AppLovin real-ad dismiss scenarios chỉ manual được. Chưa có bằng chứng audit này về test matrix live trên cả Android và iOS cho từng provider, từng ad type, ATT/UMP geography và process death.

**Khuyến nghị:** trước rollout chạy signed release/internal track trên ít nhất một Android device + một iPhone thật cho mỗi provider, kiểm tra show/dismiss/reload/offline/background/rotation/process kill và policy tooling.

### C9 — Low: example an toàn hơn trước nhưng không phải production template

Example dùng local `path: ../`, AppLovin key/ad IDs lấy bằng `--dart-define` và AdMob dùng Google public test units. Đây là lựa chọn đúng cho demo, nhưng người dùng copy example mà quên thay IDs/CMP/Privacy Policy sẽ không có production monetization đúng.

**Khuyến nghị:** giữ `publish_to: none`, thêm release preflight fail nếu còn `YOUR_`, test App IDs, `QA_AD_STRESS` hoặc privacy URL placeholder; document rõ example không tạo cấu hình console tự động.

### C10 — Low: dependency freshness cần policy riêng

`pub get` hiện báo các bản mới hơn, trong đó GMA 9.x mới hơn constraint `^7.0.0`. Không tự nâng trong audit này vì native compatibility cần matrix riêng, nhưng production cần pin/upgrade policy, changelog, iOS pod lock và regression test.

### C11 — Medium distribution: pub.dev `1.2.2` chỉ nhận diện iOS

Trang latest hiện hiển thị `Platform iOS`, không hiển thị Android, dù source/local example có Android manifests và adapter. Điều này có thể là thiếu cấu trúc plugin/platform metadata được pub.dev nhận diện, hoặc package được thiết kế như Dart wrapper nhưng chưa khai báo Android support theo chuẩn scoring hiện tại.

**Tác động:** người dùng Android không có tín hiệu compatibility chính thức trên pub.dev; claim “Android+iOS” của README và metadata công khai đang lệch nhau.

**Khuyến nghị:** chạy `dart pub publish --dry-run`, kiểm tra pub score/package analysis, cấu trúc `flutter.plugin.platforms` nếu package có native plugin code, và xác nhận Android example build từ package hosted—không chỉ local path—trước release tiếp theo.

## 4. Solution đề xuất

### S0 — Làm sạch analyzer mà không mở public test API

Không nên đơn giản xoá `@visibleForTesting`, vì như vậy test seam `isRelease` trở thành API được khuyến khích sử dụng ngoài ý muốn. Giải pháp ít phá vỡ nhất:

1. Đổi constructor `VipManager(..., isRelease:)` thành constructor production không nhận build-mode override.
2. Thêm `VipManager.forTesting(..., required bool isRelease)` hoặc inject một interface nội bộ như `ReleaseModeResolver` trong file riêng.
3. `AdManager.initialize()` production dùng `kReleaseMode`; test khởi tạo qua seam được annotate đúng phạm vi.
4. Thêm CI gate `flutter analyze --fatal-infos --fatal-warnings` cho SDK và example.

**Acceptance:** SDK và example đều `No issues found`; test release/debug trial vẫn pass; public API docs không xuất hiện tham số build-mode dùng sai mục đích.

### S1 — Consent phải fail-closed trước mọi ad request

Thay `Future<void> applyConsentToProviders(...)` bằng kết quả có cấu trúc:

```dart
final class ConsentApplyResult {
  const ConsentApplyResult({
    required this.adMobApplied,
    required this.appLovinApplied,
    this.errors = const [],
  });

  final bool adMobApplied;
  final bool appLovinApplied;
  final List<Object> errors;

  bool appliedFor(AdProvider provider) =>
      provider == AdProvider.admob ? adMobApplied : appLovinApplied;
}
```

Flow init đề xuất:

```text
ATT (iOS) → UMP/CMP → persist consent → apply selected provider privacy flags
       → success: initialize provider → preload
       → failure: ads disabled for session → bounded retry → never preload/show
```

Chỉ yêu cầu provider đang chọn apply thành công; lỗi provider không active không được chặn app. Đặt state `AdRuntimeState.consentBlocked` và để toàn bộ `load*`/`show*` trả `AdSkipReason.consentNotApplied`. Không fallback sang personalized/default request. Khi người dùng đổi lựa chọn, dispose loaded ads cũ, apply consent mới thành công rồi mới preload lại.

**Tests:** AppLovin MethodChannel throw, AdMob `updateRequestConfiguration` throw/timeout, consent revoke giữa phiên, retry thành công, inactive-provider failure và bảo đảm bridge không nhận bất kỳ `load*` nào khi blocked.

**Acceptance:** không có ad request trước consent-ready; native apply failure không crash app nhưng tạo zero impression; compliance report ghi rõ provider/error/timestamp mà không log TC string hoặc dữ liệu nhạy cảm.

### S2 — Audience policy phải có trước AppLovin initialization

Thêm cấu hình bắt buộc, không suy diễn từ consent đã lưu:

```dart
enum AdAudiencePolicy { general, childDirected, mixed }
```

- `general`: cho phép AdMob/AppLovin sau CMP.
- `childDirected`: chỉ dùng provider/config đã được legal review; mặc định không initialize AppLovin.
- `mixed`: host phải phân loại tuổi trước ad SDK init; khi chưa biết tuổi, fail-closed và không quảng cáo.

Không cho phép thay `general → childDirected` giữa phiên mà giữ AppLovin instance cũ; phải `destroy()` và vẫn không reinitialize AppLovin cho child user. Release preflight phải lỗi nếu `audiencePolicy` không được khai báo rõ.

**Acceptance:** first install child/mixed không có AppLovin initialize call; process restart/reinstall không làm mất app-level policy; có unit test và Android/iOS integration test cho từng policy.

### S3 — Fullscreen watchdog an toàn cho interstitial/rewarded

Thêm watchdog riêng cho từng show generation, không dùng một timer chung. Giá trị mặc định đề xuất 120 giây và cho phép cấu hình trong khoảng an toàn. Callback native phải kiểm tra generation/object identity để callback đến muộn không dismiss hoặc reset một ad mới.

Khi timeout:

- resolve callback đúng một lần với `AdShowResult.timeout`;
- reset slot về `idle/cooldown` và schedule reload khi app foreground + online;
- rewarded **không bao giờ grant reward** nếu chưa nhận callback earned;
- clear listener/reference có thể clear an toàn;
- ghi anomaly event, không tự show quảng cáo khác ngay sau đó.

**Tests:** không callback, earned rồi dismiss bị mất, dismiss đến sau timeout, double callback, destroy khi timer đang chạy và show generation mới trước callback cũ.

**Acceptance:** caller không chờ vô hạn; callback exactly-once; không false reward; timer bị cancel trong mọi path dispose/destroy.

### S4 — VIP offline: định nghĩa đúng security boundary

Giữ Ed25519 vì đây là lựa chọn đúng để chống forge offline, nhưng đổi wording từ “one-time key” thành “one-time per retained device storage”. Payload nên bổ sung `appId`, `keyId`, `issuedAt`, `expiresAt`, `duration`, `campaign` và version; chữ ký phải bao phủ toàn bộ canonical payload để key của app A không dùng được cho app B.

Biện pháp không-backend khả thi:

- private key chỉ nằm trên máy mint offline/password manager, không ở repo/app/CI artifact;
- giới hạn `maxVipStackDuration`, expiry của coupon và số ngày grant;
- iOS giữ ledger trong Keychain; Android dùng Keystore-protected local ledger nhưng vẫn ghi rõ uninstall/factory-reset có thể xoá;
- hỗ trợ key rotation qua `keyId → publicKey` allowlist và revoke public-key generation trong app update;
- không dùng cơ chế này cho subscription, purchase, tiền/coin chuyển nhượng hoặc entitlement có giá trị cao.

**Acceptance:** cross-app replay fail, expired key fail, unknown signing-key id fail, concurrent redeem exactly-once trong process; tài liệu công khai thừa nhận Android reinstall replay không thể giải quyết tuyệt đối nếu không có server.

### S5 — Consent/CMP theo vùng nhưng một flow bảo thủ toàn cầu

Không tự viết logic đoán quốc gia bằng IP/SIM. Luôn gọi UMP `requestConsentInfoUpdate`; UMP quyết định form required/not-required. Trên iOS, ATT chỉ xin khi có mục đích tracking hợp lệ và sau màn hình giải thích phù hợp; ATT denial không được chặn contextual/non-personalized ads nếu CMP/provider policy vẫn cho phép.

Host bắt buộc có:

- UMP message đã publish riêng cho từng AdMob Android/iOS App ID;
- Privacy Options entry point luôn truy cập được;
- US state privacy/do-not-sell flow phù hợp dashboard và legal scope;
- TCF/Additional Consent sync được kiểm tra trước MAX init nếu dùng UMP cho mediation;
- privacy policy thật, vendor/mediation disclosure, data-safety/App Privacy declarations khớp binary;
- không hiển thị built-in binary dialog chồng lên UMP. Dialog built-in chỉ dùng cho jurisdiction/use case đã được legal chấp thuận, không được quảng bá là certified CMP.

**Acceptance:** EEA/UK/CH accept/reject/reopen, US opt-out, non-required geography và under-age test đều tạo request flags đúng; thay đổi consent khiến loaded ads cũ bị dispose trước request mới.

### S6 — Placement policy thành API thay vì chỉ là tài liệu

Thêm reason bắt buộc khi show interstitial, ví dụ `InterstitialMoment.levelComplete`, `contentTransition`, `userInitiatedBreak`; không cung cấp `appLaunch` hoặc `appExit`. Enforce central frequency cap và không cho fullscreen liên tiếp. Rewarded API phải nhận disclosure model (`action`, `reward`, `amount`) và chỉ show sau một user gesture mới.

App Open chỉ được gọi từ cold-start/resume coordinator khi splash/loading surface còn active; chặn nếu có modal, fullscreen khác, banner đang phủ vùng không phù hợp hoặc user đã tương tác với nội dung. Banner/MREC cần safe-area và khoảng cách tối thiểu với control do host QA xác nhận.

**Acceptance:** policy-negative widget/integration tests cho launch interstitial, exit interstitial, repeated fullscreen, rewarded không opt-in và App Open sau interaction; manual checklist có screenshot/video cho từng placement production.

### S7 — Xác nhận Android distribution và native matrix

Trước publish kế tiếp:

1. Chạy `dart pub publish --dry-run` và sửa mọi warning về platform/package layout.
2. Tạo app tạm chỉ phụ thuộc hosted release candidate, không dùng `path: ../`.
3. Build Android release/AAB và iOS archive từ clean checkout.
4. Chạy Android+iOS × AdMob/AppLovin × banner/MREC/native/App Open/interstitial/rewarded với online, offline, reconnect, background, process death và consent variants.
5. Xác minh Ad Inspector, MAX Mediation Debugger, test devices, production preflight và không có test ID trong release config.

**Acceptance:** pub.dev nhận diện Android+iOS hoặc có giải thích kỹ thuật chính xác; hosted-package app build/run cả hai platform; report real-device có device/OS/provider/ad type/result và log không chứa secret.

### Thứ tự triển khai đề xuất

1. **Wave 1 — release blockers:** S0, S1, S2.
2. **Wave 2 — reliability/security:** S3, S4.
3. **Wave 3 — policy integration:** S5, S6.
4. **Wave 4 — release proof:** S7, internal track/TestFlight, staged rollout 1% → 5% → 25% → 100% chỉ khi metrics và Policy Center sạch.

Mỗi wave chỉ được chuyển sang `Implemented` sau khi code, unit/widget tests, analyze và audit regression đều pass. Không đóng finding chỉ bằng cập nhật README.

## 5. Checklist trước production

### Code/release

- [ ] C0: `flutter analyze` SDK trở lại zero issue.
- [ ] C1: consent apply fail-safe; native apply failure không preload/show ad.
- [ ] C2: chốt audience policy explicit trước AppLovin init; không dùng SDK cho child/mixed audience nếu chưa xử lý.
- [ ] C6: thêm watchdog interstitial/rewarded hoặc chấp thuận rủi ro bằng owner sign-off.
- [ ] `flutter test` và `flutter analyze` pass trong CI; build release Android+iOS từ clean checkout.
- [ ] Không ship private VIP signing key; rotate demo keypair trước release.
- [ ] C11: pub.dev nhận diện Android hoặc tài liệu giải thích rõ vì sao package wrapper không được badge Android; hosted-package Android build pass.

### AdMob/AppLovin console

- [ ] AdMob Android App ID và iOS App ID là hai app IDs riêng; thay toàn bộ public test IDs.
- [ ] UMP message đã **published**, không chỉ saved/draft, cho từng AdMob App ID.
- [ ] Có Privacy Policy URL thật, nêu rõ Google/AdMob, AppLovin và mediated partners.
- [ ] Có app-ads.txt trên domain chính xác.
- [ ] AppLovin MAX privacy settings/mediation partners và SKAdNetwork list đã verify trong dashboard.
- [ ] Rewarded SSV callback được cấu hình và backend verify nếu reward có giá trị.

### Real-device pilot

- [ ] Android + iOS, mạng tốt/mất mạng/reconnect, cold start/resume/background/rotation/process kill.
- [ ] Mỗi ad type: load, no-fill, show, click-through, dismiss, reload và duplicate show.
- [ ] EEA/UK/CH consent accept/reject/reopen; US opt-out; age-restricted test; non-EEA not-required.
- [ ] Xác nhận không App Open chồng modal/banner/fullscreen khác.
- [ ] Theo dõi 2–4 tuần: crash-free sessions, ANR, fill rate, CTR, invalid traffic, ad serving limits, eCPM và policy center.

## 6. Kết luận sử dụng

### Đối với app general-audience hiện tại

**Có thể dùng làm pilot production**, sau khi hoàn tất console checklist và kiểm thử real-device. Không nên rollout 100% traffic ngay ngày đầu; dùng staged rollout/remote kill switch ở host app và theo dõi dashboard.

### Đối với app Kids/child-directed/mixed audience

**Chưa nên dùng AppLovin path.** Cần explicit audience gate trước init hoặc loại AppLovin hoàn toàn cho nhóm user này. Không dựa vào consent persisted từ phiên trước.

### Đối với VIP “bảo mật cao”

**Không đủ nếu không có backend.** Signed key bảo vệ chống forge, không bảo vệ chống leak/replay Android. Dùng cho coupon/ad-free ngắn hạn thì chấp nhận được; entitlement thương mại cần server/store purchase.

## 7. Nguồn đối chiếu

- [pub.dev `applovin_admob_sdk` — latest 1.2.2 và Known limitations](https://pub.dev/packages/applovin_admob_sdk)
- [Google UMP consent mode](https://developers.google.com/admob/flutter/privacy/consent-mode)
- [Google invalid activity guidance](https://support.google.com/admob/answer/3342099)
- [Google invalid traffic policy](https://support.google.com/admob/answer/3342054)
- [Google disallowed interstitial implementations](https://support.google.com/admob/answer/6201362)
- [Google App Open guidance](https://support.google.com/admob/answer/9341964)
- [Google testing ads](https://support.google.com/admob/answer/9388275)
- [AppLovin MAX privacy/consent](https://developers.applovin.com/en/max/ios/overview/privacy/)
- [AppLovin Android terms/privacy flow](https://developers.applovin.com/en/max/android/overview/terms-and-privacy-policy-flow/)
- [AppLovin iOS terms/privacy flow](https://developers.applovin.com/en/max/ios/overview/terms-and-privacy-policy-flow/)

## 8. Mức độ chắc chắn và lời khuyên triển khai

### Mức độ chắc chắn của audit

| Kết luận | Mức tin cậy | Cơ sở |
|---|---:|---|
| Package hiện tại là `1.2.2` và test Dart/Flutter pass | **Cao** | Đã chạy trực tiếp trên workspace ngày 2026-08-01: 676 tests passed; SDK analyze còn 1 warning. |
| Teardown Dart/native có thiết kế chống leak tốt | **Cao** | Đã đọc `AdManager.destroy()`, cả hai adapter `dispose()`, slot watchers, timers và widget teardown; test lifecycle pass. |
| Offline không làm app cố request ad hoặc crash | **Cao** | Connectivity gates và reconnect refill có test; cần vẫn xác minh real device. |
| Signed VIP chống forge nhưng không chống replay Android uninstall | **Cao** | Code và tài liệu đều ghi rõ Android durable ledger là no-op khi không có backend. |
| SDK tự bảo đảm không bị AdMob/AppLovin policy enforcement | **Không thể kết luận** | Điều này phụ thuộc traffic, placement, consent dashboard, audience, app-ads.txt, privacy policy và account review ngoài source code. |
| Native ad lifecycle hoàn toàn không có leak/hang trên mọi device | **Trung bình** | Unit/widget coverage tốt nhưng native creative, process death, ATT/UMP prompt và callback lỗi hiếm cần real-device matrix. |

### Lời khuyên thực tế

1. **Không release toàn bộ traffic ngay.** Dùng internal track/TestFlight, sau đó staged rollout nhỏ. Chuẩn bị kill switch ở host app để tắt ads/provider từ xa.

2. **Tách “SDK code pass” khỏi “monetization production ready”.** Trước khi bật ad unit thật, hoàn thành UMP message published, Privacy Options, privacy policy, app-ads.txt, production IDs, SKAdNetwork/ATT và Ad Inspector/ MAX Mediation Debugger.

3. **Ưu tiên AppLovin hoặc AdMob độc lập trong pilot đầu tiên.** Không giả định dual-provider nghĩa là runtime fallback hoặc mediation tự động. Đo fill rate, eCPM, crash, ANR và policy signals riêng cho từng provider.

4. **Đặt safety policy ở host app, không để mỗi màn hình tự quyết.** Interstitial chỉ gọi tại logical breaks; rewarded chỉ sau user opt-in rõ ràng; App Open chỉ ở cold start/resume và không chồng modal/banner/fullscreen khác.

5. **Giữ trial/VIP ở mức coupon rủi ro thấp.** Dùng duration ngắn và `maxVipStackDuration`; không dùng offline VIP cho subscription, purchase hoặc quyền lợi cần one-time toàn cầu. Những quyền lợi đó cần backend hoặc StoreKit/Google Play Billing.

6. **Nếu app có khả năng phục vụ trẻ em, dừng AppLovin path trước khi init.** Không chờ consent persisted từ phiên trước. Cần một audience policy rõ ràng trong host configuration.

7. **Bổ sung các gate trước khi gọi là production-ready:**
   - consent apply failure phải fail-safe và không preload/show ad;
   - watchdog cho interstitial/rewarded phải resolve callback an toàn;
   - release preflight phải fail nếu còn `YOUR_*`, public test IDs, `QA_AD_STRESS` hoặc privacy URL placeholder;
   - real-device matrix phải chạy trên Android và iOS với cả provider;
   - pub.dev/hosted-package Android compatibility phải được xác nhận.

### Quyết định đề xuất

**Đề xuất: APPROVE FOR CONTROLLED PILOT, HOLD FOR FULL PRODUCTION.**

Sau khi đóng C0, C1, C2, C6 và C11, hoàn tất console/legal checklist và pilot ổn định tối thiểu 2–4 tuần, có thể chuyển sang full production cho app general-audience. Không dùng kết quả 676 test như bằng chứng duy nhất để tuyên bố SDK “policy-safe” hoặc “không memory leak tuyệt đối”.
