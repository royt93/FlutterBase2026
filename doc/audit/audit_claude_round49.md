# Audit round 49 — độc lập, adversarial, chỉ đọc

**Ngày:** 2026-09-19
**Bản audit:** local worktree, đã publish pub.dev **3.0.1** (commit `5e63d6b`).
**Phương pháp:** không dùng codex/agy (không nằm trong yêu cầu round này). 6
sub-agent Claude chạy song song, mỗi cái phụ trách 1 hướng trong scope yêu
cầu, được brief kỹ về 46+ finding đã fix/đã chấp nhận ở round 1-48 để không
báo lại. Sau khi 6 agent trả kết quả, tôi tự đọc trực tiếp source, đối
chiếu số dòng, verify từng candidate finding trước khi đưa vào báo cáo này
— không tin báo cáo của agent tại mặt chữ.

**Không re-audit các mục đã biết/đã quyết định** (không lặp lại làm finding
mới):
- `android/app/private_key.pepk` leak trong git history — deferred, đã
  document ở `CLAUDE.md` (root), quyết định round 34.
- 4 hành vi VIP/QA hash bị flag nhầm là bug — là tính năng chủ ý (memory
  `vip-offline-gate-and-qa-hashes-are-features`).
- Trial bypass bằng đổi giờ máy / gỡ-cài-lại-Android / không có backend xác
  thực đồng hồ — tradeoff đã chấp nhận (memory `mj9-clock-fix-is-impossible-in-pure-dart`).
- R46-01/02/03, round 47/48's fix — đã re-verify lại đúng, không hồi quy.

## Tóm tắt

3 **MAJOR** mới, 1 **MINOR** mới. Không có BLOCKER. Dual-provider parity,
VIP signing/redemption, và consent gating theo vùng (EEA/UK/US-state/ROW)
đều audit lại từ đầu và **sạch** — không tìm được gì mới ngoài các fix đã
biết.

---

## MAJOR — M49-01: `clearSdkData(allIncludingEntitlements)` tự xoá luôn
lá chắn chống farm trial, cho phép cấp lại trial vô hạn lần mà không cần
gỡ cài đặt

**File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:1258-1259`,
`packages/ad_sdk/lib/src/utils/ad_preferences.dart:662-668` (`_entitlementKeys`),
`packages/ad_sdk/lib/src/vip/_first_install_guard.dart` (toàn file),
`packages/ad_sdk/lib/src/core/ad_manager.dart` (grant block trong
`initialize()`, điều kiện `!prefs.isFirstInstallGraceApplied()` +
`guard.hasAlreadyGranted()`).

`AdPreferences._entitlementKeys` (dòng 662-668) liệt `_keyFirstInstallApplied`
và `_keyFirstInstallAt` — 2 cờ đánh dấu "trial 1-ngày đã dùng" — vào nhóm dữ
liệu "entitlement" bị xoá khi gọi `clearSdkData` với scope
`allIncludingEntitlements`. Đồng thời, `ad_manager.dart:1258-1259` khi thấy
scope đó **cũng gọi `FirstInstallGuard().erase()`** — xoá luôn flag Keychain
trên iOS, chính là cơ chế được thiết kế riêng để sống sót qua gỡ-cài-đặt lại
(xem doc comment trong `_first_install_guard.dart`: "Keychain items persist
across uninstall on iOS by default, so reinstall on same device finds flag →
guard skips re-granting").

Kịch bản cụ thể:
1. Lần mở app đầu tiên, SDK cấp 24h VIP miễn phí (first-install grace), set
   cờ SharedPreferences + cờ Keychain (iOS).
2. Consuming app (đúng theo pattern SDK tự khuyến khích — xem
   `example/lib/main.dart` phần `ClearSdkDataDemoPage`) có nút "Xoá dữ liệu
   của tôi" gọi `AdManager().clearSdkData(scope:
   SdkDataErasureScope.allIncludingEntitlements, confirmedEntitlementErasure:
   true)` — đúng pattern Apple Store Guideline 5.1.1(v) (bắt buộc có nút xoá
   tài khoản/dữ liệu) và GDPR/CCPA "quyền xoá dữ liệu" gần như buộc app
   thật phải có.
3. Người dùng bình thường bấm nút đó (dialog xác nhận chỉ cảnh báo mất VIP
   **đã mua**, không nhắc gì đến trial).
4. Mở lại app (chỉ cần kill app trong recents + mở lại — **không cần gỡ cài
   đặt**). Splash gọi `initialize()` như mọi lần mở app. Cả hai điều kiện
   cấp trial (`!isFirstInstallGraceApplied()` và Keychain guard trống) giờ
   đều đúng → cấp lại 24h ad-free mới.
5. Lặp lại vô hạn lần, trên **cả Android lẫn iOS** — trong khi tradeoff
   trước giờ được chấp nhận (`_first_install_guard.dart`, round 39) chỉ áp
   dụng cho Android và cần thao tác gỡ-cài-đặt thật, không phải 1 cú tap.

Đây là bug mới, không phải bản sao của tradeoff đã chấp nhận: không cần đổi
giờ, không cần gỡ cài đặt, không cần backend — chỉ cần 1 tính năng SDK tự
dạy dev implement, và nó phá đúng cơ chế Keychain vốn được thiết kế riêng để
chặn chính hành vi này.

Đối chiếu: `RedeemedKeyLedger` (chống dùng lại key VIP) có doc comment ghi
rõ phải "survive revoke/reinstall in production" và cố tình **không** nằm
trong `revokeAll()` (`vip_manager.dart:1786-1791`) — đúng nguyên tắc SDK đã
áp dụng ở chỗ khác nhưng bỏ sót ở đây.

**Hướng sửa (không tự sửa, audit chỉ đọc):** bỏ `FirstInstallGuard`'s
Keychain flag (và có thể cả `_keyFirstInstallApplied`/`_keyFirstInstallAt`)
ra khỏi phạm vi `allIncludingEntitlements`, theo đúng cách `RedeemedKeyLedger`
đã được cố tình loại khỏi `revokeAll()`. VIP đang active thật (trả tiền) vẫn
bị xoá bình thường — đúng cái người dùng có quyền yêu cầu.

---

## MAJOR — M49-02: 3 hàm show full-screen ad trong `AdScreenState` thiếu
check `mounted`/`_isDisposed` ở callback hoàn tất → crash khi screen bị
dispose trong lúc ad đang hiển thị

**File:** `packages/ad_sdk/lib/src/core/ad_screen.dart:152-155`
(`showInterstitialAd`), `:298-300` (`showRewardedAd`), `:391`
(`showRewardedInterstitialAd`).

Cả 3 hàm đều check `mounted`/`_isDisposed` kỹ ở mọi bước *trước* khi gọi ad
thật (trước pre-check, trước/sau `AdLoadingDialog.showAdBuffer`, sau
disclosure dialog) — nhưng **không** check lại ở đúng chỗ quan trọng nhất:
callback báo ad đã đóng, có thể fire vài giây đến hàng chục giây sau khi
`showX()` được gọi — đủ thời gian để screen gọi hàm này bị pop/thay thế bởi
màn hình khác (deep link, session hết hạn, `pushNamedAndRemoveUntil`, …).

```dart
// dòng 152-155
AdManager().showInterstitial(
  placement: placement,
  onDoneFlow: (result) {
    onDone(result);          // không check mounted/_isDisposed
  },
);

// dòng 298-300
AdManager().showRewardedAd(
  ...
  onEarnedReward: (result) {
    onEarnedReward(result);  // không check mounted/_isDisposed
  },
);

// dòng 391
AdManager().showRewardedInterstitialAd(
  placement: placement,
  onDone: onDone,             // truyền thẳng, không bọc gì cả
);
```

Kịch bản cụ thể: `HomeScreen extends AdScreenState` gọi
`showInterstitialAd(onDone: (shown) { setState(() => _busy = false); if
(shown) Navigator.of(context).pushReplacementNamed('/next'); })`. Trong lúc
interstitial đang hiển thị (video creative, người dùng tương tác — có thể
kéo dài nhiều giây), một luồng khác của app (timer hết session, xử lý deep
link FCM, logout) gọi `pushNamedAndRemoveUntil('/login', ...)`, gỡ
`HomeScreen` khỏi tree → `dispose()` chạy, `_isDisposed = true`, `mounted ==
false`. Người dùng tắt ad xong, callback native fire → `onDoneFlow(shown)` →
gọi thẳng `onDone` của host trên widget đã dispose → `setState()` sau
dispose (crash `FlutterError`) và/hoặc `Navigator.of(context)` trên context
đã deactivate ("Looking up a deactivated widget's ancestor is unsafe").

Đối chiếu: file "anh em" `ad_readiness_splash_controller.dart` đã tự vá
đúng lớp bug này ở callback bất đồng bộ của chính nó (dùng cờ `_navigated`
check trong mọi callback trễ) — `ad_screen.dart` không áp dụng cùng kỷ luật
đó cho 3 completion callback này dù đã áp dụng ở mọi chỗ khác trong cùng
hàm.

Test hiện có (`test/ad_screen_test.dart`) không bắt được vì
`_ReadyAdapter.showInterstitial`/`showRewarded` gọi `onDone` **đồng bộ**
ngay trong lời gọi — không có test nào mô phỏng "widget dispose trong lúc ad
đang hiển thị, trước khi callback đóng ad bất đồng bộ fire".

**Hướng sửa (không tự sửa):** bọc `if (!mounted || _isDisposed) return;`
ngay trong 3 completion callback này trước khi forward cho host, giống
pattern đã dùng ở mọi nơi khác trong cùng file.

---

## MAJOR — M49-03: `AdSafetyConfig.resetSessionCounters()` xoá luôn số đếm
impression/click, làm gate chống CTR-fraud vĩnh viễn không bao giờ trip nếu
bị gọi lặp lại

**File:** `packages/ad_sdk/lib/src/core/ad_safety_config.dart:1053-1069`
(hàm `resetSessionCounters`), `:722-738` (gate CTR nó phá),
`packages/ad_sdk/example/lib/main.dart:3334-3339` (pattern SDK tự khuyến
khích), `test/ad_safety_reset_scope_test.dart` (khoảng trống coverage).

`resetSessionCounters()` là API public, được export
(`applovin_admob_sdk.dart`), và có sẵn nút demo trong ví dụ tham chiếu
("Reset session counters" — đúng kiểu UI mà `CLAUDE.md` nói consuming app
được khuyến khích copy). Doc comment của nó khẳng định "deliberately leaves
the invalid-traffic history alone: violation count, the active pause and
its persisted counter all survive" — đúng với 3 field đó, nhưng nó **cũng**
xoá về 0: `_totalImpressions`, `_totalClicks`, `_fullscreenImpressions`,
`_fullscreenClicks`, và reset `_ctrPauseTriggeredAtImpressionCount = -5`.

Gate chống CTR-fraud (dòng 722-738) chỉ tính CTR khi
`_fullscreenImpressions >= 5`. Gọi `resetSessionCounters()` lặp lại trước
khi tích luỹ đủ 5 impression làm gate này **không bao giờ được tính**, bất
kể CTR thật cao đến đâu.

Kịch bản cụ thể: host wire nút reset này vào một hành động hợp lệ nhưng
xảy ra thường xuyên (app-foreground, hoàn thành level, quay lại màn hình
chính — đúng như ví dụ SDK tự shipping gợi ý). Một thiết bị có CTR gần 100%
(auto-click malware, WebView bị compromise) chỉ cần có ít hơn 5 fullscreen
impression giữa mỗi lần reset là gate `_fullscreenImpressions >= 5` không
bao giờ đúng, CTR không bao giờ được compute, `_triggerSuspiciousPause`
không bao giờ chạy, `AdSafetyConfig.isSuspended` không bao giờ lên `true` —
đúng cơ chế đã được hardening riêng ở round 6/31/39 để bảo vệ tài khoản
AdMob của publisher. Cùng 1 lệnh gọi cũng xoá `_hourlyAdTimestamps` và
`_fullscreenAdsShownInSession`, nên chỉ còn throttle 60 giây + trần
5/ngày (persisted) đứng chắn — nghĩa là tối đa 5 fullscreen ad có thể ép
hiện trong dưới 5 phút trên 1 thiết bị đã có dấu hiệu fraud, hoàn toàn
không bị phát hiện.

Khác với `bypassSafety`/`bypassVipGuard` — 2 escape hatch đã document rõ —
đây không được nhắc là rủi ro ở đâu cả, và `test/ad_safety_reset_scope_test.dart`
hiện tại chỉ assert "pause đã trigger sẵn thì sống sót qua reset", chưa bao
giờ test "reset lặp lại có thể chặn CTR gate trip ngay từ đầu".

**Hướng sửa (không tự sửa):** tách riêng nhóm counter dùng cho CTR-fraud
detection (`_fullscreenImpressions`/`_fullscreenClicks`) ra khỏi nhóm
"session pacing" mà `resetSessionCounters()` được phép xoá — coi chúng là
1 phần "invalid-traffic history" giống violation count/pause counter, theo
đúng tinh thần M2 (round-6) đã tách `resetSession` khỏi
`resetSessionCounters` nhưng bỏ sót 2 field này.

---

## MINOR — M49-04: `ProviderFailoverAdvisor`/`FillRateMonitor` không lọc
mất-kết-nối, gây false-positive khi mạng chập chờn

**File:** `packages/ad_sdk/lib/src/monetization/provider_failover_advisor.dart:141-168`
(`_onEvent`), `packages/ad_sdk/lib/src/core/ad_manager.dart:966-981`
(`applyProviderFailover`), `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart:84-104`
(cùng lỗ hổng, mức độ nhẹ hơn).

`ProviderFailoverAdvisor._onEvent` tính mọi `AdLoadEvent(success:false)`
vào `_consecutiveFailures`, không hề tham chiếu `AdManager().isConnected`
hay mã lỗi. Pre-check offline đã đúng cách emit `AdSkipEvent` (không tính
vào counter này) nhưng 1 lệnh load *bắt đầu* lúc `isConnected` tạm thời
đúng rồi rớt mạng giữa chừng vẫn tạo ra `AdLoadEvent(success:false)` — không
phân biệt được với lỗi chất lượng provider thật.

Kịch bản: host bật `enableProviderFailoverAdvisor` (ngưỡng mặc định 5 lỗi
liên tiếp). Người dùng đi tàu/xe, mạng chập chờn — mỗi lần connectivity
plugin báo "connected" vài giây, timer backstop hoặc reconnect-debounce
refill bắn 1 lệnh load thật, rồi rớt mạng giữa chừng trước khi callback
native trả về. Đủ 5 lần như vậy trong 1 phiên, circuit breaker mở,
`shouldFailoverNextSession = true`, ghi xuống disk. Lần mở app kế tiếp
(mạng bình thường), nếu host gọi `applyProviderFailover(...)` trước
`initialize()`, sẽ được khuyến nghị đổi provider — chỉ vì mạng phiên trước
xấu, không phải vì eCPM/fill rate provider hiện tại thật sự kém.

Rủi ro bị chặn bởi: đây là tính năng opt-in, chỉ tạo ra khuyến nghị host
phải tự áp dụng, và tự phục hồi qua cooldown 5 phút/half-open probe có sẵn
— không phải crash hay mất dữ liệu, chỉ là tín hiệu tuning bị nhiễu.

---

## Đã audit lại từ đầu, không tìm được gì mới

- **VIP signing/redemption** (`vip_mint.dart`, `signed_vip_key.dart`,
  `vip_manager.dart`, `_redeemed_key_ledger.dart`) — payload đầy đủ được ký
  Ed25519 và verify đầy đủ, không tamper được field nào sau khi ký, không
  double-redeem cùng thiết bị (check+claim đồng bộ, không có `await` chen
  giữa), stacking clamp ~90 ngày không bypass được bằng redeem dồn dập,
  `bypassVipGuard` không tắt bất kỳ safety cap nào ngoài đúng phạm vi
  document.
- **Consent gating theo vùng** (EEA/UK/US-state/ROW) — gate `canRequestAds`
  đóng đồng bộ trước khi UMP flow tự động chạy, mọi entry point load đều
  đọc gate live tại thời điểm gọi chứ không cache; AdMob `RequestConfiguration`
  và cờ AppLovin đều tính từ cùng 1 hàm thuần (`_decideConsentOutcome`);
  không có branch "country null → mặc định unrestricted" vì SDK chủ động
  không tự tính vùng, giao hết cho UMP/GPP; R46-01 re-verify: `setDoNotSell`
  vẫn là caller duy nhất có `qualifiesAsConsentFlow: false`.
- **Dual-provider parity** (banner/interstitial/rewarded/app-open) — thứ tự
  callback reward-trước-dismiss đối xứng cả 2 provider, revenue của ad đã
  stale vẫn được emit (không âm thầm mất), cơ chế `_isStaleAd`/creativeId
  của AppLovin (bù cho listener global, khác AdMob per-instance callback)
  vẫn đúng qua round 23/29/31/42/45/46.
- **Policy compliance khác** — nhãn "Ad"/AdChoices luôn vẽ cùng lúc với nội
  dung ad thật, không có flag nào ẩn được; child-directed: AppLovin không
  có API runtime tương đương AdMob nên SDK chặn cứng toàn bộ AppLovin
  request khi `isAgeRestrictedUser == true` thay vì âm thầm phục vụ ad
  không an toàn cho trẻ em — đúng hướng, không có gap chéo provider.
- **Round-48 fix (reconnect-debounce timer)** — re-verify: cả 2 đường
  teardown (`destroy()` và reinit-without-destroy) đều cancel timer trước
  khi đụng `_adapter`; callback timer đọc live state, không giữ tham chiếu
  cũ nào có thể stale. Rà toàn bộ 31 điểm `Timer(`/`Timer.periodic(` trong
  SDK — không tìm được thêm timer nào cùng lớp bug "hành động dựa trên
  state cũ trước khi flap".

---

## Điểm đánh giá

**Production-readiness (đóng gói/docs/API ổn định để dev khác dùng): 8/10.**
API mặt ngoài ổn định qua nhiều round (golden file API surface được giữ
đồng bộ), docs/README/CHANGELOG đầy đủ, test suite lớn (400+ file, xem
CHANGELOG). Trừ điểm vì: pana score vẫn chưa max do trần Flutter
3.35.1/Dart 3.9.x (đã document, ngoài tầm kiểm soát round này), và
`clearSdkData`/`resetSessionCounters` là 2 API public có tên gọi rất trực
quan ("xoá dữ liệu", "reset counter") nhưng hành vi thật (phá luôn 2 cơ chế
bảo vệ khác) không rõ ràng từ tên/docstring — dev tích hợp dễ dính bug mà
không biết.

**Safety (an toàn để dùng trong app ad-monetized thật): 6.5/10.** Không có
BLOCKER, không có lỗ hổng crash-diện-rộng hay vi phạm chính sách nghiêm
trọng tức thời. Nhưng 3 MAJOR mới đều **reachable qua API public, dễ vô
tình kích hoạt bởi consuming app làm đúng theo hướng dẫn của chính SDK**
(nút xoá dữ liệu theo luật, nút reset session trong ví dụ mẫu, và bug
lifecycle phổ biến "ad đang hiện, user điều hướng đi nơi khác") — không
phải kịch bản hiếm/lý thuyết. M49-01 (trial farming) là rủi ro doanh thu
trực tiếp; M49-03 (CTR-fraud gate bị vô hiệu hoá) là rủi ro tài khoản AdMob
bị đình chỉ nếu 1 consuming app thật sự bị bot/click-farm nhắm tới; M49-02
là crash thật (không phải lý thuyết) trong pattern điều hướng rất phổ biến.
Khuyến nghị: fix cả 3 MAJOR trước khi khuyến khích thêm consuming app mới
tích hợp `clearSdkData`/`resetSessionCounters`.
