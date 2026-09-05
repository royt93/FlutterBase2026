# Audit độc lập — `applovin_admob_sdk` (round 37, Claude)

**Ngày:** 2026-09-04. **Phạm vi:** toàn bộ `packages/ad_sdk/lib/src/` (~31.000 dòng), `example/`, `README.md`.
**Phương pháp:** 8 nhánh đọc song song, mỗi nhánh đọc trọn một nhóm file end-to-end (không sample), không
được đọc/tin bất kỳ kết luận nào trong `doc/audit/*.md` (36 vòng trước) — mọi finding dưới đây tự trace lại
cơ chế từ source hiện tại. Sau đó tự tay đọc lại source để verify các finding quan trọng nhất trước khi đưa
vào báo cáo này (không đưa nguyên văn báo cáo của nhánh con vào mà không kiểm chứng).

Ngoài 8 nhánh của chính mình, round này còn chạy song song 2 CLI độc lập khác (Codex, Gemini/agy) trên cùng
source — xem `audit_codex.md`, `audit_gemini.md`. Verdict cuối cùng tổng hợp cả 3 nguồn nằm ở
`audit_round37_consolidated.md`.

---

## MAJOR

### C1 — `AdMobAdapter`: dispose ad đang hiển thị khi phát hiện cache "hết hạn", có thể kẹt vĩnh viễn slot fullscreen

**File:** `lib/src/adapters/admob_adapter.dart` — cùng pattern lặp lại ở cả 4 format:
- `loadAppOpen()` dòng 880-891
- `loadInterstitial()` dòng 1221-1230
- `loadRewarded()` dòng ~1461-1470
- `loadRewardedInterstitial()` dòng 1722-1732

**Cơ chế (đã tự đọc lại source, xác nhận đúng):**

```dart
if (_interstitialAd != null) {
  if (isAdFresh(interstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
    return; // fresh — keep it
  }
  _disposeAd(_interstitialAd, 'inter-expired');   // <-- KHÔNG check isShowing
  _interstitialAd = null;
  interstitialSlot.lastLoadedAt = null;
}
if (!interstitialSlot.beginLoad()) return;  // check isShowing chỉ tới ĐÂY, đã quá muộn
```

`beginLoad()` (`lib/src/state/ad_slot.dart:157`) có check `if (isLoading || isShowing) return false` — nhưng
check này chỉ chạy SAU khi dòng dispose ở trên đã thực thi. Nếu `_interstitialAd` (hay `_appOpenAd`/
`_rewardedAd`/`_rewardedInterstitialAd`) đang là ad THẬT SỰ đang hiển thị trên màn hình (`interstitialSlot.
isShowing == true`) và đã quá hạn `_fullscreenExpiryHours` (= **1 giờ** cho interstitial/rewarded/rewarded-
interstitial, dài hơn cho App Open) kể từ lúc load — code vẫn dispose thẳng ad đó, null hoá listener native.
Callback dismiss thật từ native SDK (nếu có tới) sẽ rơi vào khoảng trống vì listener đã bị gỡ.

**Vì sao đây KHÔNG phải rủi ro lý thuyết suông — đã đọc `ad_slot.dart:305-330` để xác nhận:** codebase tự tài
liệu hoá rất rõ rằng trạng thái `showing` có thể kéo dài bất định sau khi `markDisplayed()` xác nhận hiển thị
— ví dụ "rewarded ad user pauses" hoặc "iOS ad vẫn present sau khi click-out sang App Store" — và **CHỦ Ý
không có watchdog force-release** cho giai đoạn này, vì force-release có thể "tear down ad đang sống và
stack thêm 1 fullscreen ad khác lên trên, còn tệ hơn cái hang nó định sửa". Đây là quyết định thiết kế đúng
đắn cho trường hợp "native SDK tự làm rơi callback" — nhưng nó ngầm giả định KHÔNG có ai chủ động dispose ad
đang showing từ phía Dart. `loadInterstitial()`/`loadRewarded()`/`loadRewardedInterstitial()`/`loadAppOpen()`
lại chính là code TỰ VI PHẠM giả định đó.

**Đường gọi thật khiến bug này reachable, không chỉ lý thuyết:** `AdManager().loadInterstitial()` (public
API, `ad_manager.dart:6274`) không hề gate theo state của `interstitialSlot` trước khi gọi
`ad.loadInterstitial()` — một host app hoàn toàn hợp lệ khi tự ý gọi API preload này (không có tài liệu nào
cấm gọi trong lúc interstitial khác đang hiển thị). Periodic refill (`_retryRefillAds()`,
`ad_manager.dart:7523`) thì AN TOÀN vì có gate `isIdle || isCooldown` trước khi gọi — nhưng đó không phải
đường gọi duy nhất.

**Kịch bản tái hiện:** interstitial được show (video dài, hoặc user click-out sang trình duyệt/App Store rồi
quay lại — slot vẫn `showing` suốt thời gian đó) → hơn 1 giờ trôi qua kể từ lúc load (khả thi thật với ad
click-out kéo dài, hoặc app bị background lâu với ad activity vẫn còn) → một lời gọi `AdManager().
loadInterstitial()` khác (host tự gọi, hoặc bất kỳ đường gọi nào không qua `_retryRefillAds`'s gate) → ad
đang hiển thị bị dispose ngầm → callback dismiss không bao giờ tới → `interstitialSlot` kẹt `showing` vĩnh
viễn (không có watchdog nào phục hồi giai đoạn này, theo đúng thiết kế đã nêu) → toàn bộ interstitial (hoặc
rewarded/rewarded-interstitial/app-open tương ứng) chết cho tới khi user tự khởi động lại app.

**Mức độ:** MAJOR — reachable qua API public hợp lệ, hậu quả nghiêm trọng (kẹt vĩnh viễn 1 ad type, đúng lớp
lỗi mà `ad_slot.dart`'s comment gọi là "one wedged interstitial meant zero interstitials until app restart"
— nhưng lần này do chính SDK tự gây ra, không phải do native SDK swallow callback). Không xếp BLOCKER vì cần
kết hợp 2 điều kiện cụ thể (ad showing lâu hơn 1h + có lời gọi load lại đúng lúc đó), không xảy ra trong mọi
phiên sử dụng bình thường.

**Fix gợi ý:** thêm `&& !slot.isShowing` vào điều kiện dispose-vì-hết-hạn ở cả 4 hàm.

---

### C2 — Daily cap / per-placement daily cap bị vô hiệu hoá hoàn toàn bằng cách lùi ngày hệ thống

**File:** `lib/src/utils/ad_preferences.dart:104-113` (`getDailyAdCount`), `:136-141`
(`incrementDailyAdCount`), `:152-169`/`:173-179` (per-placement). Dùng bởi `ad_safety_config.dart:479-492,
569-574`.

**Cơ chế:** ranh giới "ngày" là so sánh chuỗi `_todayUtc()` với ngày đã lưu; khác nhau (theo BẤT KỲ hướng
nào) → reset counter về 0:

```dart
final today = _todayUtc();
final saved = _prefs?.getString(_keyDailyDate) ?? '';
if (saved != today) {
  _prefs?.setString(_keyDailyDate, today);
  _prefs?.setInt(_keyDailyAdCount, 0);
  return 0;
}
```

Round-31 đã vá lỗ hổng "đổi múi giờ" bằng cách chuyển sang UTC — nhưng đó chỉ đóng lỗ hổng đổi *cách diễn
giải* thời gian, không đóng lỗ hổng lùi *giá trị* đồng hồ thật (Settings → Date & Time → tắt Automatic → lùi
ngày). Trong khi đó, VIP/trial ĐÃ có cơ chế chống chính xác việc này (high-water-mark tại
`ad_preferences.dart:374-408`, dùng bởi `VipManager._effectiveNow()`) — nhưng cơ chế đó không được tái sử
dụng cho daily-cap counter (grep xác nhận `getVipMaxObservedClockMs` không xuất hiện ở `ad_safety_config.dart`
hay bất kỳ nơi nào tính daily count).

**Kịch bản:** xem đủ 5/5 interstitial hôm nay → lùi ngày hệ thống về hôm qua → `dailyCapReached()` trả `false`
→ xem tiếp 5 ad nữa ngay lập tức, lặp vô hạn số lần trong "một ngày thật". Per-placement cap bị vô hiệu cùng
lúc do dùng chung cơ chế.

**Mức độ:** MAJOR — vô hiệu hoá hoàn toàn cơ chế safety-cap chính (được thiết kế bảo vệ tài khoản AdMob khỏi
invalid-traffic), chỉ cần một thao tác Settings công khai, không cần root. Không có test nào cho kịch bản này
(`ad_preferences_test.dart`/`ad_safety_config_test.dart` chỉ test clock-rollback cho VIP, không test daily
counter).

**Fix gợi ý:** áp high-water-mark tương tự VIP cho `_todayUtc()`/`_keyDailyDate`.

---

### C3 — `Backoff.compute()`: tràn số nguyên trong `math.pow(2, n)` làm exponential backoff sụp về mức tối thiểu sau ~51 lần fail liên tiếp

**File:** `lib/src/state/backoff.dart:23`.

```dart
final shifted = baseMs * math.pow(2, consecutiveFailures - 1).toInt();
return shifted.clamp(baseMs, maxMs);
```

**Cơ chế (đã tự verify bằng tính toán độc lập):** Dart `int` là 64-bit, `math.pow(int, int)` trả `int` và
**tràn số kiểu two's-complement âm thầm, không throw**. Với `baseMs=15000` (mặc định), phép nhân
`15000 * 2^(n-1)` vượt `int64` max (`9,223,372,036,854,775,807`) khi `n-1 ≥ 50`, tức `n ≥ 51`
(`log2(int64_max/15000) ≈ 49.13`). Từ đó `shifted` trở thành số âm/hỗn loạn; `.clamp(baseMs, maxMs)` trên số
âm trả về **cận dưới `baseMs`** (15 giây) thay vì giữ trần `maxMs` (30 phút) như thiết kế.

**Kịch bản:** một slot fail liên tục (ad unit cấu hình sai, tài khoản AdMob tạm khoá, network outage dài
ngày). Sau ~11 lần fail đã đạt trần 30 phút/lần. Từ lần fail thứ 11 tới 51 mất ~20 giờ liên tục — hoàn toàn
khả thi với thiết bị always-on hoặc mất mạng qua đêm. Ngay khi chạm ngưỡng tràn số, backoff bất ngờ sụp về 15
giây — SDK bắt đầu retry dồn dập mỗi 15s đúng lúc mạng/ad-network đang có vấn đề kéo dài, ngược hẳn mục đích
chống invalid-traffic của cơ chế backoff.

**Bằng chứng đây là bug thật chưa được rà lại:** cùng codebase, `ad_safety_config.dart._triggerSuspiciousPause`
từng có CHÍNH XÁC lỗi này và đã được fix ở round-31 (clamp exponent tối đa 6 trước khi shift) — nhưng fix đó
không lan sang `Backoff.compute()`. Grep xác nhận đây là chỗ DUY NHẤT gọi `math.pow(int, int)` trong toàn bộ
`lib/`; mọi chỗ khác dùng `math.pow(double, double)`, an toàn. Test hiện có chỉ cover `consecutiveFailures`
tới 10.

**Mức độ:** MAJOR — tự phục hồi khi có 1 lần load thành công (không crash/mất dữ liệu) nên không phải BLOCKER,
nhưng đánh đúng kịch bản "mạng lỗi kéo dài" mà cơ chế backoff sinh ra để bảo vệ.

---

### C4 — `AdScreenState`: double-tap rewarded/rewarded-interstitial có thể mở 2 dialog xác nhận chồng nhau, 1 flow fail âm thầm

**File:** `lib/src/core/ad_manager.dart:6980` (`canShowRewardedInterstitialAd`), `:7014`
(`canShowRewardedAd`) — chỉ check `AdLoadingDialog.isShowing`, KHÔNG check `AdScreenRouteLogger.isDialogOnTop`
(so với `_fullscreenBusyReason`, dùng cho lệnh show thật, có check cả hai — `ad_manager.dart:1481-1515`).

**Cơ chế:** `AdScreenState.showRewardedAd`/`showRewardedInterstitialAd` gọi `canShow*()` (peek nông) làm
pre-check, rồi mở `_showRewardDisclosure(...)` (một `showDialog` thật) nếu có disclosure. Double-tap trong
lúc dialog xác nhận đầu tiên còn mở → `canShow*()` vẫn `true` (không biết về `isDialogOnTop`) → mở dialog xác
nhận THỨ HAI chồng lên. Khi user confirm dialog trên cùng, cả 2 flow đều cố mở `AdLoadingDialog`; flow thứ 2
bị `_isShowing` guard chặn → gọi thẳng `AdManager().showRewardedAd()` → bị `_fullscreenBusyReason` chặn (do
dialog buffer của flow 1 hoặc `isDialogOnTop`) → `onEarnedReward(false)` **âm thầm, không toast báo lỗi**.
Đã có tiền lệ: `test/ad_manager_core_test.dart:1103-1145` ghi rõ "Round-32 audit (MAJOR)" fix đúng lớp lỗi
này cho tín hiệu `AdLoadingDialog.isShowing`, nhưng không mở rộng sang `AdScreenRouteLogger.isDialogOnTop`.
`canShowInterstitial()` (`ad_manager.dart:6393`) cùng lỗ hổng ở mức nhẹ hơn.

**Mức độ:** MAJOR — trải nghiệm người dùng sai (1 trong 2 lần confirm "biến mất" không rõ lý do), không có
test cover trường hợp "double-tap khi disclosure đang mở" hay "dialog thường của host đang mở".

**Fix gợi ý:** thêm `AdScreenRouteLogger.isDialogOnTop` vào 3 hàm `canShow*()`, hoặc thêm cờ tái nhập
instance-level bao trọn `showRewardedAd`/`showRewardedInterstitialAd`.

---

### C5 — `AdScreenRouteLogger.resetState()` xoá `popupDepth` vô điều kiện khi `destroy()` được gọi trong lúc có dialog thật đang mở

**File:** `lib/src/core/ad_route_observer.dart:86-89`, gọi từ `ad_manager.dart:5457` bên trong `destroy()`.

**Cơ chế:** nếu host gọi `AdManager().destroy()` (re-init provider, đổi consent flow...) trong lúc một dialog
KHÔNG-thuộc-SDK đang mở, `_popupDepth` bị ép về 0 dù dialog vẫn hiển thị → `isDialogOnTop == false` sai →
`showAppOpenAdOnResume` không còn skip → App Open có thể xếp chồng lên dialog khi app resume. Tác giả đã tự
nhận ra và né đúng vấn đề này cho `umpFormOnScreen` (comment `ad_manager.dart:5462-5468`: "form đó không bị
`destroy()` dismiss, reset counter sẽ để lộ App Open đè lên form consent còn sống") nhưng KHÔNG áp dụng logic
tương tự cho `AdScreenRouteLogger`.

**Mức độ:** MAJOR (edge case hẹp — cần chuỗi: dialog mở + host gọi `destroy()` + reinit + app resume đúng lúc
đó), đúng loại lỗi SDK đã tự nhận diện và né tránh ở chỗ khác trong cùng file.

---

### C6 — `VipRedeemScreen` (widget VIP dựng sẵn) hoàn toàn không được nhắc trong README.md

**File:** `lib/src/vip/vip_redeem_screen.dart` (public export qua `applovin_admob_sdk.dart:93`), dùng thật
trong `example/lib/main.dart:564-580` (label "Shared VipRedeemScreen (identical to host)"). `grep -n
VipRedeemScreen README.md` → 0 kết quả, kể cả trong section "VIP system" (README.md:993-1456) vốn chỉ dạy raw
API `redeemSignedKey`/`redeemVip`.

**Mức độ:** MAJOR (doc drift) — dev đọc README sẽ tự viết lại UI trùng lặp với widget đã tồn tại sẵn, đúng
kiểu trùng lặp mà widget này sinh ra để tránh.

---

## MINOR

- **VIP (accepted-by-design, test-covered):** Android không có durable one-time-use ledger/first-install-guard
  (chỉ SharedPreferences, mất khi Clear Storage/uninstall+no-backup) — `_redeemed_key_ledger.dart:39,83,99`,
  `_first_install_guard.dart:138-145`. Bảo vệ duy nhất là Android Auto Backup, host-app-optional, SDK không
  enforce/warn khi thiếu. Trùng với F-01 của cả Codex và Gemini — 3 nguồn độc lập, độ tin cậy cao.
- **VIP (accepted-by-design, test-covered):** M6 plaintext-fallback clamp có lỗ khi secure-storage READ throws
  (khác return null) — `lastReadWasUntrustedFallback` không set đúng → fallback entry (chỉ bảo vệ bằng
  checksum FNV-1a có salt lộ trong source pub.dev) được tin vô điều kiện, không bị clamp 24h —
  `_vip_entries_store.dart:101-102`. Có test tên "a fallback grant is honoured in full when secure storage is
  broken" xác nhận đây là trade-off chủ ý, không phải oversight.
- **Consent:** `SimpleEventBus` replay stale init result cho listener đăng ký muộn khi re-init KHÔNG qua
  `destroy()` — `event_bus.dart:18-34`, `ad_manager.dart:2422-2445`.
- **Consent:** không có self-check nếu splash tự viết tay quên gọi `markSplashInactive()` → App Open resume bị
  tắt vĩnh viễn + built-in consent dialog không bao giờ schedule. An toàn theo hướng bảo thủ (ít ads hơn,
  không phải consent-bypass) nhưng là footgun sản phẩm không có cảnh báo.
- **Adapter:** Native ad KHÔNG nằm trong cơ chế `InlineAdVisibility` (chỉ banner/MREC có) — mức thấp vì native
  không auto-refresh nên không rủi ro billing, chỉ visual layering khi bị fullscreen ad che.
- **Compliance (đã verify byte-for-byte đúng spec IAB cho phần NÓ CÓ đọc):** GPP chỉ decode US-National
  (section 7), không đọc state-specific section (CA=8, VA=9, CO=10, UT=11, CT=12...) và trong section 7 cũng
  chỉ đọc `SaleOptOut`/`SharingOptOut`, bỏ qua `TargetedAdvertisingOptOut` — `iab_storage.dart:204-254`. Chủ ý
  (comment: thà không đọc còn hơn đọc sai). Trùng với M-01 (Codex) và F-05 (Gemini) — 3 nguồn độc lập.
- ~~**AppLovin COPPA động giữa phiên**~~ — **FALSE POSITIVE, phát hiện sau khi bắt tay implement fix.**
  `ad_consent.dart:154-170` đúng là chỉ log warning — nhưng đó không phải điểm dừng: caller của nó,
  `AdManager.setConsent()` (`ad_manager.dart:3915-3963`, đánh dấu "R10-B"/"MJ7 round 5 audit"), ĐÃ có sẵn
  hard-stop đồng bộ (`_updateCanRequestAds(false)` ngay khi flag đổi) + tự động `initialize()` lại để rebuild
  adapter AppLovin với flag mới — có test riêng (`test/ad_manager_core_test.dart` group "COPPA hard-stop")
  đã pass từ trước. Cả 2 nhánh Claude, Codex (gián tiếp) và Gemini (F-02) đều bỏ sót vì chỉ đọc
  `ad_consent.dart`, không trace ngược lên call site thật. Không cần sửa gì — xem
  `audit_round37_consolidated.md` để biết chi tiết.
- **Example app:** `example/lib/main.dart:798` `onComplete: (success, gaid) {}` no-op trong khi README's
  canonical snippet có `debugPrint`.
- **Widget:** gap `IndexedStack` đã biết từ round-31 (document ngay trong doc-comment của
  `banner_ad_widget.dart:24-32`) — banner/MREC trong `IndexedStack` không đổi `TickerMode` khi ẩn tab, tiếp
  tục refresh/request ad ở tab ẩn nếu host không tự bọc `Visibility(maintainState: true)`. Real, reachable
  (pattern bottom-nav rất phổ biến), NHƯNG đã có tài liệu + workaround trong code — gap thật là workaround đó
  KHÔNG được nhắc tới trong README's integration contract, chỉ nằm trong doc-comment nội bộ.

## Sạch — đã đọc kỹ, không có vấn đề

- App Open resume lifecycle (race lifecycle-event vs async callback đã đóng kỹ qua nhiều vòng).
- Retry/refill/prefetch leak timer/subscription — không tìm thấy leak thật.
- Trial mode 1 ngày dùng chung cơ chế high-water-mark của VIP — lùi đồng hồ KHÔNG kéo dài được trial (khác
  hẳn C2, vốn là daily-cap counter riêng biệt không dùng cơ chế này).
- Consent commit atomicity (đã fix đúng, verify qua test thật mock `PlatformException`), `bypassSafety` scope
  không leak, preload-before-consent ordering không có path load ad trước khi biết consent.
- Đối xứng adapter theo loại ad, memory leak listener/callback native, late-callback identity check (cả 2
  adapter cùng mức bảo vệ), COPPA/TFUA ordering, offline handling, revenue tracking không leak PII.
- Ed25519 verify không có "fail→allow" path, private key không có trong repo/binary, cross-protocol confusion
  (AVP1/AVP2/CRL1) domain-separate đúng, rollback attack bị chặn bởi dual-clock, stacking cap không
  overflow, `bypassVipGuard` scope đúng, CRL laundering qua stacking đã bị chặn.
- banner/mrec dispose, native ad không có RouteAware (chủ ý), `ad_loading_dialog` identity guard,
  `showInterstitialAd` (đồng bộ, double-tap được chặn chắc), `adaptive_ad_surface` rotation.
- Mọi bước còn lại của integration contract trong example app (setNavigatorKey order, route observers, init
  trong splash không phải main(), listener-before-init, splash hard-cap, mọi demo page extend
  AdScreen/AdScreenState đúng, VIP demo key không leak secret, pubspec version khớp).
- Remote-config-driven safety override (validate/clamp đầy đủ, dryRun bị chặn kép ở release), crash guard,
  bootstrap ATT→UMP→init order, event bus (single-threaded, không race thật), state machine AdSlot (watchdog
  cho `loading`/`showing`-confirm, không deadlock/unreachable state ngoài C3).
- TCF v2.2 Purpose 1+3+4 all-required, UK dùng chung EEA framework, CCPA US Privacy String field-position
  đúng spec, COPPA set trước mọi ad request trên AdMob, ATT ordering đúng Apple guideline, fail-open CHỈ với
  `MissingPluginException` — mọi lỗi khác fail-closed đúng hướng compliant.

---

## Verdict (8 nhánh nội bộ, trước khi tổng hợp)

**KHÔNG sẵn sàng production nếu ship nguyên trạng.** 6 MAJOR (C1-C6) đều là bug thật, reachable, có fix rõ
ràng và không cần refactor lớn — ước tính 1-2 ngày dev để vá hết + viết test hồi quy. Không có BLOCKER thật
theo tiêu chí ban đầu (đã downgrade B-01 của Codex — xem `audit_codex.md` phần verify) — **nhưng xem phần 2
dưới đây, chạy độc lập bằng `claude -p --dangerously-skip-permissions`, đã tự tìm ra và tôi tự verify là
BLOCKER thật.**

---

# Phần 2 — Audit độc lập thứ hai (Claude, chạy qua CLI `claude -p --dangerously-skip-permissions`)

Chạy trên bản copy read-only riêng (rsync, không có quyền ghi working tree thật), không đọc `doc/audit/`,
không chia sẻ ngữ cảnh với 8 nhánh ở Phần 1 — một lượt đọc hoàn toàn độc lập thứ hai của cùng source, do
CHÍNH TÔI (mô hình Claude) thực hiện nhưng ở một tiến trình/phiên riêng biệt. Báo cáo dưới đây nguyên văn,
kèm ghi chú verify của tôi ở cuối mỗi mục quan trọng.

## BLOCKER

### B1 — AdMob adapter dispose ad đang hiển thị khi "hết hạn cache", kẹt vĩnh viễn slot fullscreen

**File:** `admob_adapter.dart:879-891` (App Open), lặp lại ở `loadInterstitial` (~1221-1230), `loadRewarded`,
`loadRewardedInterstitial`.

**Cơ chế:** Khi `load*()` được gọi lại và thấy ad cache cũ đã vượt `_fullscreenExpiryHours` (App Open: nhiều
giờ; Interstitial/Rewarded: **1 giờ**), code gọi `_disposeAd()` ngay lập tức, không kiểm tra `slot.isShowing`
— chỉ `beginLoad()` (chạy sau đó) mới có check này. Nếu ad đang thực sự show trên màn hình, callback dismiss
sẽ không bao giờ tới nữa → `AdSlot` đứng mãi ở `showing` → không bao giờ load được ad mới cho format đó nữa,
tới khi restart app.

**Kịch bản:** interstitial load, ready nhưng chưa show ngay → show ở phút 55 → user ở lại màn hình ad lâu
(video dài, click-out sang App Store rồi quay lại, app background trong lúc ad hiện) → phút 65 (vượt 1h), một
lệnh refill/preload nào đó gọi `loadInterstitial()` lại → thấy cache hết hạn → dispose ngay ad đang show →
callback dismiss không bao giờ tới → slot kẹt vĩnh viễn.

**➜ GHI CHÚ VERIFY (Claude, Phần 1) — XÁC NHẬN ĐÚNG 100%, đây CHÍNH XÁC là finding C1 ở Phần 1 của báo cáo
này, được 2 lượt audit độc lập hoàn toàn (không chia sẻ ngữ cảnh) tự tìm ra cùng một bug.** Đã tự đọc lại
source (xem C1 ở trên) — dispose không check `isShowing` là có thật ở cả 4 hàm, đường gọi reachable qua
`AdManager().loadInterstitial()` public API, và `ad_slot.dart:305-330`'s comment tự xác nhận KHÔNG có
watchdog phục hồi giai đoạn `showing` sau khi đã `markDisplayed()` — nghĩa là một khi bug này kích hoạt, slot
kẹt thật sự vĩnh viễn (không có cơ chế tự chữa nào khác). **Tôi nâng mức từ MAJOR (đánh giá ở Phần 1) lên
BLOCKER** khi 2 nguồn độc lập cùng tìm thấy chính xác cùng cơ chế cùng finding — mức độ đồng thuận + hậu quả
(mất vĩnh viễn 1 loại ad, ảnh hưởng doanh thu trực tiếp) đủ nghiêm trọng để không chờ dịp khác.

## MAJOR

### M1 — Adapter throw giữa `showInterstitial`/`showRewardedInterstitialAd`/`showAppOpenAd` không bao giờ gọi callback của host → UI host kẹt vĩnh viễn

**File:** `ad_manager.dart:6372-6390` (`showInterstitial`, không try/catch), `:6940-6977`
(`showRewardedInterstitialAd`, không try/catch), `:6058-6079` (`showAppOpenAd`, có try/catch nhưng chỉ reset
inline-hidden rồi `rethrow`, không gọi `onAdDismiss`). `showRewardedAd` đã được harden đúng cách này từ
"Round-29 audit (BLOCKER)" nhưng fix không lan sang 3 sibling call site còn lại. **Chưa tự verify lại** (nằm
ngoài phạm vi 8 nhánh Phần 1) nhưng logic mô tả khớp với pattern đã biết trong codebase (showRewardedAd's
existing fix), độ tin cậy cao.

### M2-M4 — VIP Android (ledger no-op, forge-bypass qua secure-storage read-error, trial reset qua Clear Storage)

Trùng hoàn toàn với finding VIP đã verify ở Phần 1 và ở cả `audit_codex.md`/`audit_gemini.md` — 4 nguồn độc
lập cùng thấy, accepted-by-design, xem chi tiết ở mục MINOR của Phần 1.

### M5 — `IncidentRecorder`/`IncidentBundle` là tính năng mồ côi, tham chiếu method không tồn tại

**File:** `compliance/incident_recorder.dart:66-91`, `tool/incident_replay.dart:2-3`. `tool/incident_replay.dart`
gọi `AdManager().exportSignedIncidentBundle()` — method này không tồn tại trong `ad_manager.dart`. Chưa tự
verify (không thuộc phạm vi 8 nhánh Phần 1) nhưng đây là claim cụ thể, dễ verify (`grep exportSignedIncidentBundle
lib/`) — nên chạy grep này trước khi xoá/sửa gì.

### M6 — Consent dialog Allow/Reject bất đối xứng độ nổi bật — dark-pattern rủi ro nếu dùng làm consent UI chính cho EEA

**File:** `consent/consent_dialog.dart:275-379`. Kích thước nút bằng nhau (đã fix round-29) nhưng trọng lượng
thị giác lệch (Allow: gradient đặc + shadow; Reject: outline nhạt). SDK không ngăn host dùng dialog này làm
consent UI GDPR duy nhất (tắt UMP). Nếu vậy, EDPB Guidelines 03/2022 về "equal prominence" áp dụng.

### M7 — COPPA flag đổi giữa phiên không tắt cá nhân hoá AppLovin — RÚT LẠI, FALSE POSITIVE

Ban đầu trùng với F-02 (Gemini), tôi cũng đồng ý nâng MAJOR. Nhưng khi bắt tay implement fix đã chọn, phát
hiện `AdManager.setConsent()` (`ad_manager.dart:3915-3963`, "R10-B"/"MJ7") đã có sẵn hard-stop đồng bộ +
auto-reinit hoàn chỉnh, test riêng ("COPPA hard-stop" group) đã pass từ trước. Cả `ad_consent.dart` (nơi mọi
nguồn dừng lại đọc) lẫn caller thật của nó đều đã tồn tại — chỉ là 4/4 nguồn audit độc lập không trace tới
caller. Không cần sửa gì. Xem `audit_round37_consolidated.md`.

### M8 — Splash hard-cap timer không dismiss `AdLoadingDialog` khi race với buffer window — RÚT LẠI, FALSE POSITIVE

Đã viết test tái hiện chính xác race này (`test/ad_readiness_splash_controller_test.dart`, mở rộng test
round-31 có sẵn: hard cap 100ms bắn giữa lúc buffer 1000ms đang chờ). Kết quả: `AdLoadingDialog.isShowing`
đã là `false` — KHÔNG kẹt. Đọc `ad_loading_dialog.dart:159+` (`showAdBuffer`) xác nhận: dialog tự dismiss qua
`Future.delayed(bufferMs)` nội bộ, được key bằng generation token riêng của chính nó, hoàn toàn độc lập với
`_navigated`/hard-cap của splash controller. Dialog có thể hiện tối đa `bufferMs` (mặc định 1s) trên màn hình
mà host đã navigate tới — là một glitch thị giác ngắn, không phải "kẹt vĩnh viễn" như mô tả ban đầu. Không
cần sửa gì; đã giữ lại test làm regression-guard cho tính chất này (đổi comment cho đúng bản chất).

### M9 — `AdLoadingDialog.show()` không có watchdog/timeout riêng; M10 — nhãn "Ad" trên native/banner/mrec có thể chưa đủ nổi bật (cần verify UI thật); M11 — late native callback có thể "hồi sinh" state banner sai sau watchdog 30s

Xem nguyên văn ở file gốc `claude/AUDIT_REPORT.md` trong scratch của round này — chưa tự verify, độ tin cậy
trung bình (M10 tự nhận cần verify UI thật; M9/M11 là claim cụ thể, dễ kiểm bằng cách đọc đúng dòng đã trích).

## MINOR (N1-N17) — không lặp lại ở đây, đã trùng phần lớn với Phần 1/Gemini/Codex

Đáng chú ý thêm 2 điểm MỚI không nguồn nào khác nhắc tới:
- **N7:** GAID và VIP-key literal bị log ở level `verbose` (`ad_manager.dart:2231`, `vip_manager.dart:1134,
  1136,1147,1734`) — rò rỉ nếu host bật verbose ở release hoặc có `onLog` sink cắm Crashlytics/Sentry. Mặc
  định release là `warning` nên rủi ro thấp nhưng đáng note.
- **N6:** safety-cap counters (daily/suspicious/placement) lưu plain SharedPreferences không checksum — cùng
  attacker model VIP dùng root, nhưng không được bảo vệ tương đương. (Đây khác C2 — C2 là bug logic lùi
  ngày; N6 là thiếu checksum chống sửa trực tiếp file bằng root, mức độ nhẹ hơn nhiều vì cần root.)

## Verdict (Phần 2, độc lập)

**CONDITIONAL — không dùng thẳng cho production ngay, cần vá tối thiểu B1 + M1 trước khi ship.** Điểm tự tin
7/10 (chưa audit code native Android/iOS, vài finding UI cần xác nhận trên thiết bị thật).
