# Audit round 33 — `applovin_admob_sdk` 2.9.14 (Codex, 2026-09-02)

## Kết luận ngắn

**Không nên phát hành 2.9.14 nguyên trạng cho production có AppLovin hoặc có yêu cầu consent pháp lý.** Hai lỗi round 32 đã được sửa một phần đúng, nhưng fix BLOCKER-A chưa đạt mục tiêu “provider write thành công và retry khi lỗi”: API privacy của dependency `applovin_max 4.6.4` là fire-and-forget `void`, do đó code hiện tại vẫn có thể ghi nhận AppLovin đã apply dù platform channel thất bại. Nhánh AdMob nhận biết được lỗi nhưng không có retry tổng quát cho quyết định thủ công/COPPA.

Kết quả round này: **2 BLOCKER, 2 MAJOR, 3 MINOR/known limitation**. BLOCKER đầu là lỗi còn tồn tại trong fix round 32; BLOCKER thứ hai là thiếu GPP enforcement nếu SDK tuyên bố hỗ trợ “mọi quốc gia”. Không phát hiện leak timer/controller mới trong các đường dispose đã đọc. `flutter analyze`: **0 issue**; `flutter test`: **1562/1562 pass** trong 2 phút 31 giây.

## Phạm vi và phương pháp

- Đọc bắt buộc `doc/audit/audit_round32_deep_consolidated.md` trước.
- Đọc source hiện tại trong `lib/`, toàn bộ `example/lib/main.dart`, README integration contract, cấu hình package và test liên quan.
- Đối chiếu diff thật của `3b0a8ac`, `e7c770e`, `0b2bd54`; không dựa vào commit message.
- Trace init/load/show/dispose, connectivity/backoff, fullscreen mutual exclusion, inline visibility/refresh, consent apply/reconcile, trial/VIP storage/clock/replay.
- Đọc luôn implementation đã resolve của `applovin_max 4.6.4`, vì kiểu trả về của privacy API quyết định `try/catch` trong package có hoạt động hay không.
- Không sửa source. File này là thay đổi duy nhất do audit tạo.

## Verify ba follow-up commit round 32

| Commit / mục | Kết quả | Đánh giá |
|---|---|---|
| `3b0a8ac` — TCF open timeout | `iab_storage.dart:228-267` bắt mọi lỗi ngoài `StateError`, log và trả `false`; read timeout cũng trả `false` | **Đúng**: timeout/read failure fail-closed, không còn Future rejection như 2.9.11 |
| `3b0a8ac` — chỉ commit consent khi hai provider thành công | `ad_consent.dart:148-232` có hai cờ và chỉ gán marker khi cả hai true | **Chỉ đúng với AdMob; chưa đúng với AppLovin và chưa có retry tổng quát** — BLOCKER R33-01 |
| `e7c770e` — safety floor | `remote_ad_safety_provider.dart:99-103` thêm `min: 1` | **Đúng** |
| `e7c770e` — RI loading dialog | `ad_manager.dart` đã thêm `AdLoadingDialog.isShowing` vào `canShowRewardedInterstitialAd` | **Đúng** |
| `e7c770e` — splash race mẫu | `example/lib/main.dart:809-820` kiểm tra `!mounted || _navigated` | **Đúng** |
| `e7c770e` — bootstrap cap | `ad_bootstrap.dart:122-149` cap mặc định 20 s, init tiếp tục background | **Đúng về tránh treo caller**; semantics “false” là timeout hoặc failure đều giống nhau, đã document |
| `0b2bd54` — Banner/MREC revenue | `banner_ad_widget.dart:645-656`, `mrec_ad_widget.dart:517-528` chuyển impression/revenue sang `onAdRevenuePaidCallback`; load callback không còn ghi impression | **Đúng về timing**, nhưng thiếu late-callback ownership guard — MAJOR R33-03 |
| `0b2bd54` — Native revenue | `native_ad_widget.dart:487-501` đã wire callback + mapping chung | **Đúng về wiring/mapping**, vẫn cần device test như changelog thừa nhận |

### Vì sao test mới của 2.9.12 không bắt được phần AppLovin

`test/ad_consent_test.dart:126-150` chỉ làm **GMA channel** ném lỗi; AppLovin mock luôn trả thành công. Trong dependency đã resolve:

```dart
// applovin_max-4.6.4/lib/applovin_max.dart:191-194,207-210
static void setHasUserConsent(bool value) {
  _methodChannel.invokeMethod('setHasUserConsent', {'value': value});
}
static void setDoNotSell(bool value) {
  _methodChannel.invokeMethod('setDoNotSell', {'value': value});
}
```

Future của `invokeMethod` bị bỏ và API trả `void`, nên không thể `await`/bắt platform error từ call site hiện tại.

## Findings

### R33-01 — BLOCKER — fix consent vẫn báo AppLovin thành công giả; AdMob failure không được retry tổng quát

**File:** `lib/src/core/ad_consent.dart:148-175,207-232`; call site `lib/src/core/ad_manager.dart:3985-3998`; `lib/src/consent/consent_manager.dart:105-110`; dependency evidence `applovin_max-4.6.4/lib/applovin_max.dart:191-210`.

```dart
try {
  AppLovinMAX.setHasUserConsent(...); // void, Future channel bị dependency bỏ
  AppLovinMAX.setDoNotSell(...);      // void, Future channel bị dependency bỏ
  appLovinApplied = true;
} catch (e) { ... }
...
if (appLovinApplied && adMobApplied) {
  _lastAppliedToProviders = c;
}
```

**Kịch bản lỗi thật 1 (AppLovin):** user rút consent hoặc bật Do Not Sell → method channel chưa đăng ký/đang teardown/native side ném `PlatformException` → hai setter trả `void` ngay, `appLovinApplied=true` → nếu GMA write thành công, marker được cập nhật → resume reconcile thấy state “khớp” và không retry. Native MAX có thể giữ `hasUserConsent=true`/`doNotSell=false`; Future lỗi còn có thể thành unhandled async error.

**Kịch bản lỗi thật 2 (AdMob/manual choice):** host gọi `setConsent`/`setDoNotSell` với state không đến từ IAB TCF/USP, GMA `updateRequestConfiguration` ném → marker không đổi, nhưng `applyConsentToProviders` nuốt lỗi và trả success; `setConsent` tiếp tục mở luồng bình thường. Reconcile hiện chỉ được kích bởi device TCF refusal hoặc legacy USP opt-out. Không có job nào so sánh “desired ConsentManager value” với marker rồi retry mọi axis. Với COPPA, global request config có thể giữ tag cũ; với một custom/manual `doNotSell`, không có IAB signal để kéo retry.

**Hậu quả:** không bảo đảm consent được *áp dụng* xuống cả provider và retry khi lỗi, đúng yêu cầu business. Đây không phải false positive: kiểu `void` được xác nhận từ dependency thực tế, và test hiện chỉ cover GMA throw + marker, không cover retry hay AppLovin channel failure.

**Điều kiện sửa trước ship:** cần một bridge AppLovin awaitable (gọi MethodChannel trả `Future`, hoặc upstream API hỗ trợ Future), xác minh/đọc lại `hasUserConsent()` và `isDoNotSell()` sau write; apply trả structured per-provider result; giữ consent gate đóng khi tightening chưa xác nhận; retry có backoff cho desired-vs-applied trên cả ba axis. Không nên chỉ thêm một cờ khác.

### R33-02 — BLOCKER nếu contract là “mọi quốc gia” — GPP chỉ đọc để báo cáo, không enforce US multi-state

**File:** `lib/src/core/iab_storage.dart:48-52,154-171`; `lib/src/core/ad_manager.dart:5100-5138`; README `1915` (thừa nhận raw-only).

```dart
static const keyUsPrivacy = 'IABUSPrivacy_String';
static const keyGppString = 'IABGPP_HDR_GppString';
...
Future<void> _reconcileDeviceUsPrivacy() async {
  final optedOut = await IabStorage.usPrivacyOptedOut(); // chỉ legacy USP
  if (optedOut != true) return;
  await mgr.set(...doNotSell: true);
}
```

**Kịch bản:** CMP hiện đại ghi GPP sections cho Colorado/Virginia/Connecticut/Utah/Texas… nhưng không ghi legacy `IABUSPrivacy_String` → SDK expose `gppConsentString` nhưng không parse/map opt-out → `AdConsent.doNotSell` giữ false → AppLovin `setDoNotSell(false)` và AdMob RDP không được bật.

**Hậu quả:** tuyên bố “consent mọi quốc gia / US state privacy/GPP” không đúng ở tầng enforcement. Đây **không phải false positive**; source và README chủ động nói không parse GPP. Nếu business hạ contract thành “host/CMP chịu trách nhiệm map GPP và gọi `setDoNotSell`”, mức độ có thể hạ thành known integration limitation, nhưng không được quảng cáo zero-config mọi quốc gia.

### R33-03 — MAJOR — callback revenue AppLovin inline mới thiếu ownership/dispose guard

**File:** `lib/src/widget/banner_ad_widget.dart:628-656`; `lib/src/widget/mrec_ad_widget.dart:505-528`; so sánh `lib/src/widget/native_ad_widget.dart:487-493`; teardown `lib/src/adapters/applovin_adapter.dart:825-858`.

```dart
onAdRevenuePaidCallback: (ad) {
  AdSafetyConfig.recordBannerImpression();
  final sink = AdManager().adapter?.eventSink; // adapter hiện tại, không phải owner
  sink?.call(...);
}
```

Native callback có check `adapter == null || !adapter.isInitialised`, Banner/MREC mới thì không. Cả ba đều resolve singleton adapter **tại lúc callback**, không capture adapter/adView generation sở hữu platform view.

**Kịch bản:** MAX đã queue paid/click callback → widget bị unmount hoặc host `destroy()` + init provider mới → callback cũ chạy → Banner/MREC vẫn tăng global impression; nếu adapter mới đã lên, event `[AppLovin]` bị gửi vào sink phiên mới (thậm chí phiên AdMob). CTR denominator, revenue panel/compliance log và session attribution sai. Với callback sau dispose nhưng trước adapter mới, sink null tránh event nhưng impression vẫn tăng.

**Hậu quả:** telemetry/fraud gates sai và event xuyên generation; không trực tiếp hiển thị ad chồng ad. Đây không phải false positive: chính comment teardown tại `applovin_adapter.dart:851-858` thừa nhận queued callback có thể sống sau listener clear, nhưng widget callbacks không dùng sink của old adapter.

### R33-04 — MAJOR/known product gap — dual-provider không có runtime failover

**File:** `lib/src/config/ad_config.dart:417-424,673-675`; adapter được chọn một lần trong `ad_manager.dart` init; README/changelog 2.9.13 cũng ghi deferred.

**Kịch bản:** session chọn AppLovin, MAX outage/no-fill kéo dài trong khi AdMob có inventory (hoặc ngược lại) → retry/backoff chỉ gọi lại cùng adapter → toàn bộ placements trống đến khi host tự `destroy()` + `initialize()` với provider khác.

**Hậu quả:** “dual-provider” là selectable provider, không phải HA waterfall. Không crash/treo UI, nhưng không đáp ứng yêu cầu business nếu dual-provider được hiểu là tự fallback. Không phải false positive; đây là feature gap đã xác nhận/chấp nhận ở 2.9.13.

### R33-05 — MINOR/known limitation — Rewarded Interstitial không có trên AppLovin

**File:** `lib/src/adapters/applovin_adapter.dart:1835-1847`; README `1229-1233`.

```dart
Future<void> loadRewardedInterstitial() async {}
Future<void> showRewardedInterstitial(...) async {
  onDone(const RewardResult(earned: false, shown: false));
}
```

Ứng dụng cấu hình AppLovin và dùng API chung sẽ không bao giờ có RI; không có capability flag/fallback. Đã document rõ nên không coi là bug bí mật, nhưng host phải branch theo provider hoặc không dùng format này.

### R33-06 — MINOR/accepted security limit — trial/VIP là local best-effort, không chống reinstall Android hay global replay

**File:** `lib/src/config/ad_config.dart:511-533`; `lib/src/vip/_first_install_guard.dart`; `lib/src/vip/vip_manager.dart:1282-1448`; `lib/src/vip/signed_vip_key.dart:88-100,220-248`; README `989-1007,1089-1094,1390`.

- Clock rollback trong cùng install được chống bằng persisted high-water mark + monotonic session anchor; không thấy bypass mới ở logic này.
- iOS có Keychain guard/ledger sống qua uninstall. Android dựa SharedPreferences/host Auto Backup; clear-data hoặc reinstall không restore sẽ cấp lại trial và xoá one-time ledger.
- Ed25519 public key trong APK/IPA không cho forge chữ ký nếu private key giữ kín. AVP2 ký duration + key id + expiry + bundle binding. AVP1 vẫn accepted, không expiry/bundle binding, là compatibility decision.
- “One-time” chỉ per-device; cùng code dùng trên thiết bị khác. CRL cần host fetch và fail-open; không có backend thì không có revocation tức thời/toàn cục.
- `vip_manager.dart:1343-1350` fail-open bundle binding khi `PackageInfo` lỗi: key AVP2 của app khác có thể redeem trong cửa sổ đó. Đã được product chấp nhận ở round 32, không báo lại như bug mới.

Theo chỉ dẫn audit, đây là limitation của thiết kế offline-only, không phải BLOCKER độc lập. Không dùng entitlement này cho giá trị tài chính đáng kể nếu không có backend.

### R33-07 — MINOR/integration limit — popup Overlay không nằm trong ad-stacking guard

**File:** `lib/src/core/ad_route_observer.dart`; README `228-239`.

`AdScreenRouteLogger` chỉ quan sát Navigator/PopupRoute; `OverlayEntry`, `SnackBar`, toast/loading bên thứ ba không phải Route. App Open resume có thể phủ lên popup đó. 2.9.13 đã document đúng; example dùng route/dialog chuẩn. Host phải tránh overlay trong resume window hoặc cung cấp gate riêng.

## Audit theo trục business

### Android + iOS / online + offline

- Cả hai adapter có timeout/watchdog/backoff, connectivity debounce và periodic refill; offline load được chặn hoặc fail-soft, không thấy đường sync-block UI mới.
- `AdBootstrapOptions.initTimeout` mặc định 20 s ngăn caller treo ~130–150 s; init tiếp tục background. Splash example còn hard-cap 8 s.
- IAB Android store trỏ đúng default SharedPreferences; iOS dùng prefixless async store. Tuy nhiên chính source vẫn ghi iOS IAB branch chưa device-verify, nên production iOS cần test thật.
- Không có automatic provider failover (R33-04).

### Lifecycle/policy từng format

| Format | AdMob | AppLovin | Kết luận |
|---|---|---|---|
| Banner | per-widget ad ownership/dispose, paid/impression callback, visibility pause | per-view id, destroy retry, auto-refresh ownership | Timing revenue đã sửa; còn late callback R33-03 |
| MREC | tương tự Banner | tương tự Banner | cùng R33-03 |
| Native | native ad dispose + per-instance state | platform view tự load; per-instance tombstone bounded | revenue đã wire; cần device verification |
| App Open | expiry/show watchdog/resume gates | stale-ad identity + show watchdog | mutual fullscreen/dialog/route gates có; bypassSafety là API host phải giới hạn ở splash |
| Interstitial | load/show/dispose + reload sau dismiss | listener identity guards | không thấy double-show mới |
| Rewarded | reward callback/SSV data | reward callback/custom data | callback resolution/watchdog có; SSV vẫn cần backend của host để xác nhận thật |
| Rewarded Interstitial | implemented | no-op | R33-05 |

Không tìm thấy timer/stream/controller leak mới: adapter dispose huỷ show/destroy timers và null listeners/sink; manager destroy dừng retry/connectivity/debounce và dispose monetization observers; widget state huỷ timer/notifier/controller. Việc AppLovin widget callback late là ownership correctness, không chứng minh native object leak.

### Consent

- GDPR/EEA/UK: UMP + TCF purpose 1/3/4 fail-closed khi storage lỗi; không coi `obtained` đơn thuần là personalized consent. Fix timeout 2.9.12 đúng.
- COPPA/TFUA: AdMob config được set trước initialize; AppLovin không init cho child-directed user và re-init khi flag đổi. Phần này của finding #6 round 32 đúng là false positive.
- CCPA legacy USP: opt-out được reconcile/persist/apply cả hai provider.
- GPP/new US states: chưa enforce (R33-02).
- Provider write/retry: chưa đáng tin với AppLovin và manual consent (R33-01).

### Example integration

`example/lib/main.dart` có `WidgetsFlutterBinding.ensureInitialized`, navigator/route observer, ATT → UMP → init, splash hard-cap, event subscription cleanup, và demo cho các format kể cả RI. Race buffered App Open đã sửa bằng `_navigated`. Không tìm thấy BLOCKER mới riêng trong example. Lưu ý sample AppLovin vẫn phải chấp nhận RI no-op và callback revenue chưa device-test.

## Các claim round 32 được phân loại lại

- BLOCKER-B timeout TCF: **đã fix hoàn toàn ở mức code/test**.
- BLOCKER-A provider apply: **chưa fix hoàn toàn**; marker GMA đúng hơn nhưng AppLovin fire-and-forget và retry tổng quát còn thiếu.
- COPPA runtime change: **false positive**, source có hard-stop + rebuild adapter.
- AppLovin banner/MREC/native revenue: **logic timing/mapping đã fix**, callback ownership còn MAJOR mới.
- Bootstrap/dialog/splash/safety-floor: **đã fix**.
- Trial/VIP Android, AVP1, fail-open bundle/CRL, no runtime provider failover, AppLovin RI: **known/intentional limits**, chỉ trở thành ship blocker nếu product contract đòi bảo đảm mạnh hơn.

## Điều kiện production

**Bắt buộc trước khi ship:** sửa R33-01 và test lỗi native/platform-channel thật cho cả `hasUserConsent` + `doNotSell`, bao gồm retry/backoff và tightening gate; hoặc loại AppLovin khỏi build/traffic cho tới khi có đường apply xác nhận được. Nếu marketing/contract tiếp tục nói hỗ trợ privacy “mọi quốc gia”, phải sửa R33-02 hoặc đổi contract rõ ràng và buộc host map GPP.

**Nên sửa trước ship AppLovin:** generation/owner guard cho Banner/MREC/Native paid/click/load callbacks và test destroy→reinit late callback (R33-03); chạy device matrix Android+iOS cho paid callback, IAB read, UMP withdrawal, COPPA startup, offline cold-start.

**Có thể chấp nhận có điều kiện:** selectable-provider không failover; RI AppLovin no-op; Overlay popup limitation; trial/VIP offline-only và Android replay — miễn là mô tả sản phẩm không hứa HA, global one-time, revocation tức thì hay anti-reinstall tuyệt đối.

**Verdict cuối:** 2.9.14 có nền lifecycle/safety và test coverage rất mạnh, nhưng **chưa production-ready cho deployment AppLovin có user consent-regulated**. AdMob-only cũng chỉ nên ship sau khi bổ sung retry cho global consent/COPPA write hoặc chứng minh host luôn restart/reapply khi write lỗi. Không có cấu hình nào nên tự nhận “GPP mọi US state zero-config” ở phiên bản này.
