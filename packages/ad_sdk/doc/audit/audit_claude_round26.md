# Audit round 26 — independent security/compliance review (Claude)

**Ngày:** 2026-08-31
**Phạm vi:** source thật trong `packages/ad_sdk/lib` (không dựa vào doc/comment
cũ) — trọng tâm `lib/src/vip/`, `lib/src/adapters/` (AdMob + AppLovin),
`lib/src/consent/` + phần consent trong `lib/src/core/`, `lib/src/core/ad_manager.dart`
(6914 dòng, orchestrator trung tâm), và toàn bộ dispose()/lifecycle của các
widget ad (`lib/src/widget/`).
**Bản audit:** `applovin_admob_sdk` 2.4.0, khớp HEAD hiện tại
(`1680214 docs(ad_sdk): update test documentation...`).
**Đối chiếu pub.dev:** đã fetch được `https://pub.dev/packages/applovin_admob_sdk`
— xác nhận version mới nhất trên trang là **2.4.0** ("Published in the last
hour"), khớp bản đang audit. Mục "Known limitations" trên trang (đọc từ
README) khớp với hành vi thật trong source đã verify ở round này (đặc biệt
mục "VIP anti-bypass durable on iOS, weak on Android" — khớp đúng
`_first_install_guard.dart`/`_redeemed_key_ledger.dart` đã đọc). Không lấy
được điểm pub-points chi tiết (trang không render breakdown số liệu qua
fetch) — bỏ qua mục này, không suy diễn.

**Phương pháp:** 6 sub-agent đọc song song từng khu vực (VIP, AdMob adapter,
AppLovin adapter, `ad_manager.dart`, consent, widget lifecycle), mỗi finding
ứng viên phải trích nguyên văn code + file:line. Sau đó **tôi tự đọc lại từng
đoạn code liên quan (Read trực tiếp, không qua agent) ít nhất 1-2 lần** trước
khi đưa vào báo cáo này — loại bỏ toàn bộ finding không tự verify được bằng
mắt. Đã đọc baseline `audit_round23_consolidated.md` (3281 dòng, rounds tới
25) trước để không lặp lại các fix/deliberate-non-fix đã có.

**Baseline đã đối chiếu, không báo lại (đã tự kiểm tra source hiện tại vẫn
khớp mô tả baseline):** MJ9 clock split (`VipManager._isLive`), CRL laundering
qua 1 tap watch-ad, cached-CRL-tương-lai kẹt revocation, `redeemSignedKey`
verify offline Ed25519 (đây là yêu cầu #5, không phải bug), `kQaTestDeviceHashes`
merge chủ ý, native ad không có RouteAware lifecycle (đã biết/document),
COPPA flip giữa init AppLovin, rewarded-interstitial intro-screen policy,
IABUSPrivacy_String đọc-nhưng-không-áp-dụng (đã fix round 21), consent gate
cho rewarded load 15s (đã fix round 22).

---

## Kết quả — 6 finding mới

### 1. MAJOR — `RedeemedKeyLedger.markRedeemed` không khoá, race giữa 2 lần redeem đồng thời làm mất bản ghi "đã dùng" trên iOS

**File:** `lib/src/vip/_redeemed_key_ledger.dart:66-78`

```dart
Future<void> markRedeemed(String kid) async {
    if (!_platformIsIos()) return;
    try {
      final raw = await _secure.read(key: _storageKey);
      final ids = raw == null
          ? <String>{}
          : (jsonDecode(raw) as List).cast<String>().toSet();
      ids.add(kid);
      await _secure.write(key: _storageKey, value: jsonEncode(ids.toList()));
    } catch (e) {
      SafeLogger.w(_tag, 'markRedeemed threw: $e');
    }
  }
```

Đây là read-modify-write thuần trên Keychain, không có lock/queue nào (khác
hẳn `_vip_entries_store.dart`/`VipManager._save()`, nơi có `_saveQueue`
process-wide đã được audit kỹ ở round 8-12). Đã grep xác nhận
`VipManager.redeemSignedKey` (`vip_manager.dart:1282`) chỉ chặn redeem trùng
**cùng một** `kid` qua `_signedKidsInFlight` (dòng 222) — không chặn 2 lời gọi
`redeemSignedKey` với **2 code khác nhau** chạy gần như đồng thời (ví dụ: host
app cho nhập nhiều mã liên tiếp, hoặc 1 deep-link tự động redeem trùng lúc
người dùng bấm redeem thủ công).

**Kịch bản lỗi:** 2 luồng gọi `markRedeemed(kidA)` và `markRedeemed(kidB)` gần
như đồng thời → cả hai đọc Keychain ra `{}` trước khi bên kia ghi xong → ghi
đè lẫn nhau → chỉ 1 trong 2 `kid` tồn tại trong ledger cuối cùng. `kid` bị mất
vẫn được cấp VIP đúng 1 lần ở lượt cài hiện tại (ledger chính
`AdPreferences`/SharedPreferences không bị race này vì không có `await` giữa
đọc và ghi ở tầng đó), nhưng ledger Keychain — tồn tại đúng để chống
"gỡ cài + cài lại để redeem lại key cũ" — không còn ghi nhận nó. Người dùng gỡ
cài + cài lại app sau đó **redeem lại được chính key đã dùng**, được cộng
thêm 1 cửa sổ VIP nữa (bị chặn trần bởi `maxVipStackDuration`, nhưng vẫn là
một lần tái sử dụng trái ý đồ "one-time-use").

**Đã tự verify:** đọc lại `_redeemed_key_ledger.dart` toàn bộ 88 dòng, xác
nhận không có mutex/queue nào bọc quanh `read`→`write`.

---

### 2. MAJOR — nhánh `onFailed` của cả 4 loại fullscreen ad AdMob thiếu guard đối xứng với `onLoaded`, rò event vào analytics sau khi adapter đã dispose

**File:** `lib/src/adapters/admob_adapter.dart:913-924` (App Open; y hệt ở
`loadInterstitial` 1215-1226, `loadRewarded` 1399-1410,
`loadRewardedInterstitial` 1614-1625)

```dart
onFailed: (code, message) {
  SafeLogger.w(_logTag, 'loadAppOpen $tag ❌ code=$code msg=$message');
  _appOpenAd = null;
  appOpenSlot.markFailed();
  _emit(AdLoadEvent(
    providerTag: tag,
    type: AdSlotType.appOpen,
    placement: AdPlacement.splash,
    success: false,
    errorCode: code,
  ));
},
```

So với `onLoaded` ngay phía trên (dòng 896-912) có
`if (_discardIfDisposed(ad, 'loadAppOpen')) return;` trước khi chạm slot/emit
— hoàn toàn không có guard tương đương ở nhánh fail. Đã grep xác nhận
`_discardIfDisposed` (định nghĩa dòng 777-785, dùng cờ `_fullscreenDisposed`
set tại dòng 565 trong `dispose()`) chỉ được gọi ở 4 nhánh `onLoaded`, không
bao giờ ở `onFailed`. Cũng xác nhận `dispose()` **không** clear
`eventSink` (grep toàn file, không có `eventSink = null`) — field này là
`_emit` của `AdManager` (`ad_manager.dart:2539: adapter.eventSink = _emit`),
sống độc lập với vòng đời adapter.

**Kịch bản lỗi:** host gọi `destroy()`/chuyển provider trong lúc 1 request
load đang bay tới Google (đã gửi, chưa có phản hồi). Adapter cũ bị dispose,
nhưng ít lâu sau GMA gọi `onAdFailedToLoad` cho request cũ đó trên **instance
adapter đã chết** → `markFailed()` ghi field thường (không bị chặn — field
này không qua `_disposed` guard của `_SlotStateNotifier`, chỉ `state.value`
mới có guard đó từ round-14) rồi `_emit(...)` vẫn gọi được `eventSink` (trỏ
tới `AdManager._emit` còn sống) → **1 event fail của adapter đã chết bị ghi
vào `_eventLog` vĩnh viễn và broadcast lên stream `events` công khai**, y như
provider hiện tại vừa fail thật. Hệ quả cụ thể: `_selfCheckLoad`
(`ad_manager.dart:663-667`, dùng cho `runIntegrationSelfCheck`) chờ **event
đầu tiên khớp `type`**, không phân biệt generation adapter — self-check có
thể bị "cướp" bởi event fail của adapter cũ, báo sai kết quả dù load mới
đang chạy tốt.

Không crash (đã kiểm tra: setter của `_SlotStateNotifier.value` đã có guard
`_disposed` từ round-14, silently drop thay vì throw) — đây là rò rỉ dữ liệu
analytics/compliance-report, không phải crash.

**Đã tự verify:** đọc lại `admob_adapter.dart` dòng 870-990 (App Open) trực
tiếp, xác nhận cấu trúc `onLoaded` có guard còn `onFailed` không có; grep xác
nhận `_discardIfDisposed`/`eventSink` như mô tả.

---

### 3. MAJOR (biên giới BLOCKER) — `AdManager().destroy()` có thể chạy trong lúc rewarded ad AppLovin đang show, làm mất reward người dùng đã kiếm được

**File:** `lib/src/adapters/applovin_adapter.dart:793-838` (trong `dispose()`)

```dart
// Order matters: clear native listeners FIRST so any callback fired
// mid-destruction ... is silently dropped instead of mutating slot
// state on a half-disposed adapter.
try {
  _bridge.setAppOpenAdListener(null);
  _bridge.setInterstitialListener(null);
  _bridge.setRewardedAdListener(null);
  _bridge.setWidgetAdViewAdListener(null);
} catch (e) { ... }
...
_rewardedDone?.call(RewardResult.skipped);
_rewardedDone = null;
```

`dispose()` null hoá `_rewardedAdListener` của bridge **trước** khi resolve
`_rewardedDone` bằng `RewardResult.skipped`. Plugin `applovin_max` (đã đọc
source thật tại `~/.pub-cache/hosted/pub.dev/applovin_max-4.6.4/lib/applovin_max.dart:122-125`)
dereference `_rewardedAdListener` **tại thời điểm dispatch** (khi platform
channel nhận message `OnRewardedAdReceivedRewardEvent`), không capture lúc
show bắt đầu. Nếu native side đã bắn event reward và nó đang nằm trong hàng
đợi channel đúng lúc `dispose()` chạy `setRewardedAdListener(null)` (cùng 1
isolate, race thuần theo thứ tự event-loop) → event bị `?.call` nuốt im lặng,
không log, không exception.

**Đã grep xác nhận** `AdManager.destroy()`/`_destroy()`
(`ad_manager.dart:4782-5136`) **không có bất kỳ check nào** cho
`rewardedSlot.isShowing` trước khi bắt đầu teardown — `_teardownBlocksShow`
(dòng 5276) chỉ chặn show **mới** bắt đầu trong lúc teardown đang chạy, không
làm gì với 1 show đã đang diễn ra khi `destroy()` bắt đầu.

**Kịch bản lỗi:** user đang xem rewarded video (đã earn reward, native đã bắn
sự kiện), đúng lúc đó code khác gọi `AdManager().destroy()` (API công khai,
đã document — dùng khi đổi provider/logout/reset SDK) → reward event bị nuốt,
`_rewardedDone` resolve `skipped` (báo host "chưa earn" dù user đã hoàn
thành), và native fullscreen activity/VC của rewarded ad **không bị dismiss**
(dispose chỉ teardown widget AdView banner/mrec, không đụng tới fullscreen ad
đang show) — ad tiếp tục chạy trên màn hình nhưng không còn ai ở phía Dart sở
hữu nó.

**Đã tự verify:** đọc lại `applovin_adapter.dart:780-849` trực tiếp; grep
`_teardownBlocksShow`/`isShowing`/`_destroyInFlight` trong `ad_manager.dart`
xác nhận không có guard chặn teardown bắt đầu khi đang show.

---

### 4. MAJOR — dialog consent nội bộ (`autoShowConsentDialog`) dùng `Future.delayed` không bị huỷ khi `destroy()` chạy, có thể áp consent/config CŨ lên session MỚI

**File:** `lib/src/core/ad_manager.dart:1596-1663` (`_maybeScheduleConsentDialog`),
đối chiếu `destroy()` dòng 5015.

```dart
_consentDialogScheduled = true;
final delay = cfg.consentDialogPostSplashDelay;
Future.delayed(delay, () async {
  if (mgr.hasBeenAsked) { ... return; }
  ...
  await mgr.showDialog(ctx, config: cfg, ...);   // cfg = config CŨ, capture lúc schedule
  _consent = mgr.adConsent;
  _consentExplicitlySet = true;
  _footgunBlocked = false;
});
```

`_consentDialogScheduled` chỉ được set `true` (dòng 1624) và `false` (dòng
5015 trong `destroy()`) — grep toàn file xác nhận đây là 2 nơi duy nhất chạm
biến này, và **không có `Timer` nào được lưu để `cancel()`** — `Future.delayed`
là fire-and-forget, `destroy()` chỉ reset cờ bookkeeping, không hủy closure
đang chờ.

**Kịch bản lỗi:** host dùng dialog nội bộ mặc định (`autoShowConsentDialog:
true`, README quảng cáo đây là tính năng chính "Built-in Cupertino consent
dialog, auto-shown post-splash"), gọi `destroy()` rồi `initialize()` với
**`AdConfig` khác** (ví dụ đổi `testDeviceIds` theo tài khoản/môi trường —
pattern đổi config đã được chính code này xử lý tường minh ở nơi khác, xem
comment "Round-25 QC round 7" về `destroy()` rồi `initialize()`) trong vòng
`consentDialogPostSplashDelay` (mặc định khá ngắn). Closure cũ vẫn fire với
`cfg` CŨ đã capture → `mgr.showDialog(ctx, config: cfg_cũ, ...)` → gọi
`applyConsentToProviders(..., config: cfg_cũ)` → theo
`ad_consent.dart:70-75` (đã đọc, tự comment ghi rõ):
`MobileAds.instance.updateRequestConfiguration` **REPLACE TOÀN BỘ**
`RequestConfiguration` — bao gồm `testDeviceIds` — bằng giá trị của config
CŨ, đè lên session MỚI đang chạy.

Hậu quả cụ thể: nếu config cũ có `testDeviceIds` khác config mới (ví dụ máy
QA test app A rồi chuyển sang cấu hình app B), request configuration của
session mới bị stomp bằng danh sách test-device sai — có thể khiến máy QA
**không còn được coi là test device** (risk tạo real impression ngoài ý muốn,
đối lập với chủ đích `kQaTestDeviceHashes`) hoặc ngược lại.

**Đã tự verify:** đọc lại `ad_manager.dart:1596-1665` trực tiếp; grep
`_consentDialogScheduled` xác nhận chỉ 2 điểm chạm, không có cơ chế huỷ.

---

### 5. MAJOR — khoảng hở giữa "AdMob nhận consent mới" và "AppLovin nhận consent mới" trong đường consent nội bộ (`ConsentManager`/dialog mặc định)

**File:** `lib/src/consent/consent_manager.dart:185-191` (`_setInternal`), đối
chiếu `lib/src/adapters/applovin_adapter.dart:924-929` và
`ad_manager.dart:3567-3608` (`_syncConsentToAdapter`).

```dart
Future<void> _setInternal(ConsentSettings s, {AdConfig? config}) async {
    _current = s;
    _settingsListenable.value = s;   // (A) đồng bộ — trigger _syncConsentToAdapter NGAY
    await _persist();                // (B) await THẬT — round-trip SharedPreferences
    await _applyToProviders(config); // (C) applyConsentToProviders — gọi AppLovinMAX.setHasUserConsent
}
```

`ValueNotifier.value=` ở (A) gọi `notifyListeners()` đồng bộ →
`AdManager._syncConsentToAdapter` chạy ngay, gọi
`_adapter?.applyConsent(latest)`. Với **AdMob**, `applyConsent` set field
`_nonPersonalizedAds`/`_restrictedDataProcessing` — áp dụng ngay tại (A), an
toàn. Nhưng `AppLovinAdapter.applyConsent` (`applovin_adapter.dart:924-929`)
là **no-op tường minh** (comment: "forwarded via the static `AppLovinMAX`
privacy APIs in `applyConsentToProviders`") — nghĩa là consent thật của
AppLovin (`AppLovinMAX.setHasUserConsent(false)`) chỉ được gọi ở bước (C),
**sau** `await _persist()`. Trong khoảng (B)→(C), không có bất kỳ
`_updateCanRequestAds(false)` nào được gọi (grep toàn `consent_manager.dart`
— không có), nên `AdManager.canRequestAds` vẫn `true`, và bộ retry/refill
tích cực của SDK (`_retryRefillAds`) có thể bắn 1 request AppLovin ngay trong
khoảng hở đó, dùng consent **cũ** (trước khi user reject).

**Vì sao đây là finding mới, không phải round 21/22 đã fix:** cơ chế
"đóng gate trước khi apply" (`_applyPrivacyOptionsResult`,
`ad_manager.dart:4115-4144`, đã vá 3 vòng QC round-13) **chỉ được nối vào
đường UMP** (`requestUmpConsent()`/`requestPrivacyOptionsFlow()`), không được
nối vào `ConsentManager.set()/reset()` — tức đường dialog nhị phân mặc định
của chính SDK này (tính năng được README quảng cáo là cách "GDPR-compliant
consent UI không cần tích hợp CMP bên thứ 3"). Cùng 1 package có 2 đường
consent hợp pháp, một được bảo vệ kỹ (UMP), một thì không (dialog mặc định).

**Mức độ:** cửa sổ hẹp (1 round-trip ghi SharedPreferences, thường vài ms),
xác suất trúng thấp nhưng có thật và tái lập được bằng cách tạo delay nhân
tạo trong storage (hoặc thiết bị chậm/low-end — Android low-end rất phổ biến
ở thị trường mà app này target). Vì đây đúng lớp lỗi mà round 21/22 coi là đủ
nghiêm trọng để vá cho đường UMP, tôi giữ nguyên mức MAJOR cho đường còn lại
chưa được vá.

**Đã tự verify:** đọc lại `consent_manager.dart` toàn bộ 192 dòng, đọc lại
`_syncConsentToAdapter` toàn bộ (`ad_manager.dart:3567-3631`), xác nhận
`_adapter?.applyConsent()` gọi đồng bộ tại (A) nhưng AppLovin no-op; grep xác
nhận `_updateCanRequestAds` không xuất hiện trong `consent_manager.dart`.

---

### 6. MAJOR — `AdReadinessSplashController._goReady()` có thể gọi `onReady` (callback điều hướng của host) sau khi controller đã `dispose()`, gây crash "deactivated widget"

**File:** `lib/src/widget/ad_readiness_splash_controller.dart:141-162`

```dart
void _goReady() {
    if (_navigated) return;
    _navigated = true;
    ...
    _onReady?.call();
}

void dispose() {
    _hardCap?.cancel();
    _hardCap = null;
    final listener = _busListener;
    if (listener != null) SimpleEventBus().remove(listener);
    AdManager().markSplashInactive();
    // KHÔNG set _navigated = true, KHÔNG clear _onReady/_context
}
```

**Kịch bản lỗi:** splash gọi `start()`, `_showSplashAppOpen()` được kích hoạt
(init xong + `showAppOpenOnReady`), gọi `AdManager().loadAppOpenAd(onAdLoaded:
...)` — bất đồng bộ, đang chờ ad load. Trước khi callback trả về, splash
`State` bị dispose thật (user background/kill app giữa splash, hoặc pop màn
hình) → host gọi `controller.dispose()` theo đúng doc-comment của chính file
này — nhưng `dispose()` không đặt `_navigated = true`. Khi callback
`onAdLoaded` fire trễ: check `_navigated` vẫn `false` → check
`ctx.mounted` (dòng 120) — `false` vì context đã deactivate → gọi `_goReady()`
→ `_goReady()` set `_navigated = true`, gọi `_onReady?.call()` — đây chính là
closure host truyền vào `start()` (ví dụ `_goHome` gọi
`Navigator.of(context).pushReplacement(...)` — đúng mẫu trong doc-example của
file này, không có check `mounted`) — chạy trên `context` đã deactivate →
Flutter throw `"Looking up a deactivated widget's ancestor is unsafe."`.

Đây là race có thật, không phải giả thuyết: `dispose()` vốn được thiết kế để
"an toàn ngay cả khi `onReady` chưa từng fire" (theo chính doc-comment dòng
150-155), nhưng thiếu đúng 1 dòng (`_navigated = true`) để giữ đúng lời hứa
đó khi có 1 callback bất đồng bộ (ad load) đang treo lúc dispose.

**Đã tự verify:** đọc toàn bộ file 164 dòng trực tiếp, xác nhận `dispose()`
không set `_navigated` và không null hoá `_onReady`/`_context`.

---

## Các mục đã audit lại, không tìm thấy vấn đề mới (đã tự đọc, không chỉ tin agent)

- Ed25519 verify (`signed_vip_key.dart`, 379 dòng) — uỷ quyền cho thư viện
  `cryptography`, không có nhánh chấp nhận signature rỗng.
- `_first_install_guard.dart` (207 dòng) — bảng bypass-matrix trong chính
  file khớp với README "Known limitations", không tìm thêm đường bypass mới
  trên iOS không cần "Erase All Content".
- Dispose/leak của banner/mrec/native AdMob + AppLovin — guard identity
  (`identical(...)`), watchdog Timer bị cancel đúng theo `AdSlot.dispose()`.
- `_retryRefillAds` — guard VIP nằm ngay đầu hàm, mọi call site đều được bao
  phủ.
- `bypassSafety` — chỉ bỏ qua cap/throttle, không bỏ qua VIP/consent/invalid-
  traffic-pause/fullscreen-mutex.
- COPPA (`tagForChildDirectedTreatment`/`isAgeRestrictedUser`), ATT ordering,
  fail-closed khi UMP form lỗi mạng (chỉ fail-open cho đúng 1 case hẹp:
  `MissingPluginException` ở debug/test build, không phải lỗi mạng thật).
- `banner_ad_widget.dart`/`mrec_ad_widget.dart`/`native_ad_widget.dart`/
  `ad_loading_dialog.dart` — không còn `setState` sau dispose nào không qua
  `ValueListenableBuilder`; M4/M5 (round cũ) vẫn còn hiệu lực trong source
  hiện tại.

---

## Kết luận

SDK đã qua 25+ vòng audit rất kỹ (mutation-testing từng fix, 3 reviewer độc
lập song song ở nhiều round) — chất lượng nền tảng tốt, 2 vấn đề bảo mật VIP
lớn nhất (MJ9 clock rollback, CRL laundering) đã đóng đúng cách. Round này
tìm thêm **6 finding MAJOR mới** (không có BLOCKER mới), tất cả đều là lỗ hổng
hẹp/race-window chứ không phải lỗi thiết kế nền tảng:

- 2 finding (#3, #6) là **crash/mất-tiền-thật cho user** khi dispose xảy ra
  đúng lúc 1 luồng bất đồng bộ (rewarded show, ad load) đang treo — nên fix
  trước khi production, vì đúng use-case người dùng thoát app giữa splash
  hoặc host code gọi `destroy()` không đúng lúc là hoàn toàn thực tế, không
  cần điều kiện hiếm.
- 2 finding (#4, #5) là **lỗ hổng compliance narrow-window** trên đúng con
  đường consent mặc định mà README quảng cáo là giải pháp GDPR không cần CMP
  bên thứ 3 — nên fix trước khi triển khai ở EEA quy mô lớn, dù xác suất
  trúng window thấp.
- 2 finding (#1, #2) là rò rỉ nhẹ hơn (1 lần tái dùng VIP key hiếm gặp, rò
  event analytics) — có thể triển khai production trước, fix ở release kế
  tiếp.

**Khuyến nghị:** ĐƯỢC đưa vào production app thật, với điều kiện:
1. Fix #3 và #6 trước khi ship (cả hai đều có thể gây crash/mất-tiền-thật
   người dùng thấy trực tiếp, không phải rủi ro lý thuyết).
2. Fix #4 và #5 trước khi bật `autoShowConsentDialog`/nhắm thị trường EEA quy
   mô lớn — đây là đúng con đường compliance chính của sản phẩm.
3. #1, #2 có thể xếp sau, không chặn release đầu, nhưng nên vào changelog
   gần nhất vì #1 làm suy yếu đúng lời hứa "one-time-use" của tính năng VIP.
4. Giữ nguyên toàn bộ "deliberate non-fix" đã liệt kê ở baseline round 23 —
   không có bằng chứng mới nào trong round này lật lại các quyết định đó.
