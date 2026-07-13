# Audit toàn diện SDK quảng cáo `applovin_admob_sdk` (2026-07-13)

> Người audit: Claude (Sonnet 5) · Ngày: 2026-07-13
> Phạm vi: `packages/ad_sdk/lib/` (SDK 1.0.24, path-override đang active) + host usage (`lib/mckimquyen/widget/vip/`, `splash/`, `common/const/ad_keys.dart`) + native config (Android/iOS, cả app root và `packages/ad_sdk/example/`).
> Phương pháp: **KHÔNG** review lại từ đầu. Đây là bản audit thứ 6 của repo này (sau `audit_claude.md` 05/07, `audit_partner_lead_20260710.md`, `policy_crosscheck_20260711.md`, `audit_full_20260711.md`, `audit_gemini.md`). Ba mươi task T01–T30 từ audit đầu tiên đã được đánh dấu `done` (`doc/task/done/`). Round này = **verify tươi 7 subagent song song**, mỗi agent bị yêu cầu đọc trực tiếp code hiện tại và trích dẫn file:line, không được tin lời audit cũ — mục đích là bắt các trường hợp "task đóng nhưng code chưa thực sự fix" hoặc "đã fix nhưng regress".
>
> **File này thay thế hoàn toàn bản 2026-07-05** (đã lỗi thời — thời điểm đó VIP còn dùng base64 map, chưa có T01-T30).

---

## 0. Tóm tắt điều hành

Đối chiếu lại 7 yêu cầu gốc của partner, sau khi verify tươi từng dòng code:

| # | Yêu cầu | Trạng thái hôm nay | So với audit 05/07 |
|---|---|---|---|
| 1 | Provider AdMob/AppLovin, Android + iOS | 🟢 Đạt — ad-unit-id tách platform thật, có validate format | Đã đóng (T15/T16) |
| 2 | Work có mạng / không mạng | 🟡 Đạt phần lớn — reconnect nhanh đã có, còn 2 gap nhỏ | Đóng phần lớn (T08 xong), T09/T10 còn sót |
| 3 | Ad types chuẩn, đúng vòng đời, no memory leak | 🟡 Tốt — 1 leak thật còn sống (`_eventStream`), 2 gap nhỏ khác | T11/T14 xong, T13 **chưa xong thật** |
| 4 | Trial mode 1 ngày | 🟢 Đạt — chống clock-rollback thật, có footgun warning | Đóng (T17) |
| 5 | Kích hoạt VIP by code, không backend | 🟢 Đạt — Ed25519 signed-key, mạnh nhất có thể cho no-backend | Đóng (T18/T19/T30) |
| 6 | Consent mọi quốc gia, chuẩn AppLovin + AdMob | 🟢 Đạt — toàn bộ 9 điểm verify pass | Đóng (T01-T07), 1 gap vận hành đã biết |
| 7 | Tuân thủ policy AdMob/AppLovin | 🟢 Đạt — cross-check với policy thật (07/11) không có mismatch nghiêm trọng | Đóng |

**Kết luận ngắn gọn:** Toàn bộ nhóm **P0 chặn phát hành** của audit 05/07 (consent tự chế, npa, impression-trước-consent, network không auto-recover, VIP base64 dễ decompile) **đã được xử lý và verify thật** — không phải chỉ "task được đóng trên giấy". SDK **đủ điều kiện đưa vào production** với AppLovin làm provider chính. Các gap còn lại đều là **P1/P2**, không phải rào cản pháp lý/bảo mật.

---

## 1. Consent & Compliance (REQ 6+7) — 🟢 Verify pass toàn bộ

Agent verify độc lập đọc `ump_consent.dart`, `ad_manager.dart`, `ad_consent.dart`, `att_consent.dart`, splash flow (host + example), `doc/UMP_SETUP.md`. Kết quả cả 9 điểm:

1. **UMP flow đúng chuẩn** — `requestConsentInfoUpdate → getConsentStatus → load/show form → canRequestAds()` (`ump_consent.dart:74-162`). `autoRequestUmpConsent` vẫn opt-in (`ad_config.dart:260`, mặc định `false`, có doc giải thích rõ tại sao).
2. **Mọi load path gate theo `_canRequestAds`** — `ad_manager.dart` dòng 1228/1263/1432/1461/1546/1659 đều check `!_canRequestAds` trước khi load/show app-open/interstitial/rewarded/banner.
3. **`npa` forward cho AdMob khi consent=false** — xác nhận qua doc comment `ad_consent.dart:58-60`, tách riêng khỏi AppLovin forwarding (`setHasUserConsent`/`setDoNotSell`, dòng 75-76).
4. **Splash: consent chạy TRƯỚC impression đầu tiên** — cả host (`splash_screen.dart`: ATT ~170-176 → UMP 184-197 → `initialize()` 212 → load app-open) và SDK example (`main.dart:391,400,408`) đúng thứ tự.
5. **ATT trước UMP** — `att_consent.dart:85-88` doc comment xác nhận, khớp code splash thật.
6. **AppLovin COPPA gap** — SDK 4.x không có API forward age-restricted signal; đây là giới hạn thật của native SDK, **đã được log cảnh báo rõ ràng** (`ad_consent.dart:77-89`), không phải bug ẩn.
7. **Privacy Options re-consent** — `AdManager().showPrivacyOptions()` (`ad_manager.dart:1077`) + host wiring thật qua `vip_screen.dart:23` → nút hiển thị trong `VipRedeemScreen` khi callback non-null. Đây là entry point **có thể chạm tới được**, không chỉ plumbing chết.
8. **CCPA ≠ COPPA** — `isAgeRestrictedUser` (COPPA/TFUA) và `doNotSell` (CCPA) đã tách biệt hoàn toàn (`ad_consent.dart:40-44,104-109`).
9. **UMP form production chưa publish** — vẫn là gap **vận hành** (không phải code), nhưng **đã tài liệu hoá rõ** trong `doc/UMP_SETUP.md:35` ("Saving a draft is NOT enough — must be Published"). Đây là việc thao tác tay trên AdMob console, ngoài phạm vi code — checklist trước khi launch phải có bước này.

**Không tìm thấy gì mới bất thường.** Đây là mảng **sạch nhất** trong toàn bộ audit.

---

## 2. Network / Offline (REQ 2) — 🟡 Đóng phần lớn, còn 2 gap thật

1. **Connectivity listener + fast-path reconnect — ĐÃ FIX THẬT.** `ad_manager.dart:1992-2032`, `_startConnectivityWatch()` dùng `.listen()` thật (không phải đọc 1 lần), debounce 800ms, gọi `_retryRefillAds()` + `preloadBanner()` + bump `initRevision` khi false→true. Timer 5 phút cũ vẫn còn nhưng giờ chỉ là **fallback chậm**, path chính là listener.
2. **Banner: chưa có UI phân biệt "offline" — CÒN GAP THẬT.** `banner_ad_widget.dart:94-97,216`: khi offline, banner return `SizedBox.shrink()` — **y hệt** trường hợp VIP-active, consent-chưa-có, đang cooldown. User (và bất kỳ ai QA bằng mắt) không phân biệt được "đang offline" với "cố tình ẩn ad". Reload khi có mạng lại thì **đã hoạt động đúng**, không bị storm postFrameCallback (`_initScheduled` guard dòng 195-201 chặn tốt).
3. **`isConnected` vẫn optimistic mặc định khi exception/lần đầu — MÂU THUẪN VỚI TUYÊN BỐ CỦA T10.** `ad_manager.dart:1190-1204`: catch exception → trả `_lastConnected`, nhưng `_lastConnected` **seed mặc định là `true`** (dòng 328, comment ghi rõ "Seeded true (optimistic)... deliberate"). Nghĩa là: máy vừa khởi động, chưa có event connectivity nào bắn, `ConnectionNotifierTools` throw exception → SDK vẫn coi là **có mạng**. Đây là **quyết định có chủ ý** (comment giải thích lý do: broken detector không nên block ads vĩnh viễn), nhưng **mâu thuẫn với chính tên/mô tả của task T10** ("pessimistic fast-retry") — cần làm rõ lại trong doc task, không phải fix code (hành vi hiện tại có lý do hợp lý, chỉ là tài liệu nói sai).
4. Test hiện có (`connectivity_refill_test.dart`, `connectivity_resilience_test.dart`) verify tốt cơ chế refill/flap-debounce, nhưng **không** test path exception thật của `ConnectionNotifierTools` lẫn UI offline-state — 2 gap trên sẽ không bị test bắt nếu regress thêm.
5. Airplane-mode từ đầu session: không crash/hang, các load path đều `onAdLoaded?.call(false)` gracefully — nhưng do gap #3, lần check đầu tiên vẫn có thể lạc quan `true` và thử load thật 1 lần trước khi lùi lại.

**Khuyến nghị:** (a) thêm state "offline" riêng cho banner (khác `SizedBox.shrink()` chung), (b) làm rõ lại doc T10 rằng optimistic-on-first-check là chủ đích chứ không phải bug còn sót, hoặc cân nhắc seed `_lastConnected` pessimistic nếu muốn khớp đúng mô tả gốc.

---

## 3. Vòng đời & Memory leak (REQ 3) — 🟡 Phần lớn tốt, 1 leak thật còn sống

1. **Double-show race (interstitial/rewarded) — FIX THẬT, kỹ hơn cả kỳ vọng ban đầu.** Không chỉ null-out object mà dùng hẳn state machine `AdSlot.beginShow()` (ready→showing) check *trước* native `show()` ở mọi path — `applovin_adapter.dart:603-636,778-818`, `admob_adapter.dart:358-370,678-690`.
2. **Banner postFrameCallback pile-up — FIX THẬT** (`_initScheduled` guard, `banner_ad_widget.dart:195-202`). Nhưng **dispose banner cũ trước khi tạo mới — CHƯA ĐẦY ĐỦ**: path refresh/resume-recovery (`applovin_adapter.dart:970-977`) chỉ null rồi preload lại, chưa dispose tường minh native `AdView` cũ — chỉ dispose thật ở lúc `dispose()` toàn adapter. Gap nhỏ, có thể tích tụ native view nếu reconnect lặp nhiều lần trong 1 session.
3. **`_eventStream` KHÔNG BAO GIỜ được close() trong `destroy()` — BUG THẬT, mâu thuẫn trực tiếp với tuyên bố T13 đã đóng.** Guard `if (_eventStream.isClosed) return;` trong `_emit()` hiện là **dead code** vì không có nơi nào gọi `.close()`. Rò rỉ mỗi lần `destroy()` → `initialize()` lặp lại (hot-restart nhiều lần, test suite, hoặc kịch bản multi-init). `AdLoadingDialog.resetState()` + `AdScreenRouteLogger.resetState()` thì **đã** được gọi đúng trong `destroy()` — phần đó fix thật.
4. **AppLovin native listener cleanup trong `destroy()` — FIX THẬT** (`applovin_adapter.dart:163-180`, set về `null` theo đúng thứ tự trước `destroyWidgetAdView`).
5. **Timer conversions ML1/ML2 — FIX THẬT**, cancel đúng trong dispose/destroy. Riêng ad-retry loop vẫn dùng `Future.delayed` + generation-counter (không phải object `Timer`), nhưng cancel logic đúng — chỉ là pattern khác, không phải leak.
6. **T29 splash race — FIX MỘT PHẦN.** Guard giữa ATT→UMP→`initialize()` đã bỏ (đúng ý đồ fix), nhưng vẫn còn 1 `mounted` check ở tầng ngoài cùng (`splash_screen.dart:160`) gate cả block init — nếu hard-cap timer bắn trước khi block này chạy, cùng loại lỗi (init bị skip) vẫn có thể xảy ra, chỉ ở cửa sổ hẹp hơn. Chưa có test tự động cho race này.
7. **Memory-leak test — CÓ THẬT, không hời hợt.** `banner_leak_regression_test.dart`: 25 chu kỳ mount/unmount, assert RouteObserver subscriber state thật + không exception + số lần load bị chặn trần. Tuy nhiên chỉ cover leak vector RouteAware — **không** cover gap #3 (`_eventStream`) hay gap #2 (banner native view refresh).
8. **`late`/`!` — SẠCH.** 0 `late` thật, 4 chỗ `!` còn lại đều an toàn (sau `??=` hoặc null-check cùng biểu thức).

**Khuyến nghị ưu tiên:** fix gap #3 (`_eventStream.close()` trong `destroy()`) — 1 dòng, rủi ro thấp, nên làm trước khi audit tiếp theo coi T13 là "done" thật.

---

## 4. Provider parity (REQ 1) — 🟢 Đạt, 1 bug native config

1. **Ad-unit-id tách platform — THẬT, không chỉ ở tầng SDK.** `ad_config.dart:74-84` (`resolvePlatformAdUnitId`) + `AdKey.appLovinAndroid`/`AdKey.appLovinIos` trong `lib/mckimquyen/common/const/ad_keys.dart` có **4 unit ID khác nhau thật** cho mỗi platform (banner/interstitial/appOpen/rewarded) — không phải chỉ SDK hỗ trợ mà app không dùng.
2. **Validate ad-unit-id — FIX THẬT.** `ad_manager.dart:144-190`: regex AdMob format + cảnh báo rỗng + cảnh báo lẫn lộn provider, chạy trong `releaseFootgunWarnings` (chỉ ở release build).
3. **T21 load-time safety cap — FIX THẬT.** `ad_safety_config.dart:308-309` (`dailyCapReached()`) được check ngay đầu `loadAppOpenAd/loadInterstitial/loadRewardedAd/_retryRefillAds` — không còn phí ad-request khi đã chạm trần ngày, đúng mô tả task.
4. **BUG THẬT (mới phát hiện, ngoài phạm vi T15-T21): AdMob Application ID giống hệt nhau ở Android và iOS.** `android/app/src/main/AndroidManifest.xml:53-55` và `ios/Runner/Info.plist:52-53` cùng giá trị `ca-app-pub-3612191981543807~9731053733`. AdMob console cấp App ID **riêng** cho mỗi platform app entry — nhiều khả năng ID của iOS đang bị dán nhầm ID của Android. Rủi ro hiện tại **thấp** vì provider runtime đang cố định là `AdProvider.appLovin` (AdMob dormant, dùng test-unit-id công khai — xem `ad_keys.dart` comment "safe to ship because AdMob is never actually called"), nhưng **bắt buộc phải sửa trước khi bao giờ flip sang AdMob**.

---

## 5. Trial mode 1 ngày (REQ 4) — 🟢 Đạt, verify thật

- `FirstInstallVipGrace.day` + chống clock-rollback thật: `vip_entry.dart:30-34`, `isActive` check `now.isBefore(grantedAt)` trước — comment ghi rõ "T17 anti clock-rollback". `grantedAt` bất biến từ lúc cấp, lùi đồng hồ → entry bị coi là chưa active, không "sống lại".
- Footgun warning khi grace bị tắt trong release: `ad_manager.dart:132-139`, chỉ bắn ở non-debug, message rõ ràng "no ad-free trial window".

Không tìm thấy gap mới.

---

## 6. VIP by code (REQ 5) — 🟢 Đạt, mạnh nhất có thể cho no-backend

Đã chuyển hẳn từ base64 map (audit 05/07 CRITICAL) sang **Ed25519 signed-key**:

1. **Key format** `AVP1.<payload_b64url>.<sig_b64url>`, payload = `<seconds>|<keyId>`. Verify qua `verifySignedVipKey()` (`signed_vip_key.dart:71-119`) dùng public key nhúng trong app (`kVipPublicKeyBase64`). Private key **chỉ** tồn tại ở tool mint offline (`packages/ad_sdk/tool/vip_mint.dart`, không ship trong app bundle) — grep xác nhận 0 private key bytes trong repo/app.
2. **Robustness:** `duration <= 0` bị chặn (assert debug + no-op release), purge expired eager ở nhiều điểm (`vip_manager.dart:192,272-273,323`), không chỉ lazy.
3. **Storage hardening (T30) — cửa sổ bypass đã đóng thật.** `ad_preferences.dart:124-189`: format `<checksum>|<json>` (FNV-1a, tự nhận là "deterrent, not cryptographic"). Có cờ `_keyVipEntriesChecksumMigrated` riêng — raw JSON chỉ được trust **1 lần** (migration), sau đó tái xuất hiện raw JSON bị coi là tamper và reject. Đây chính xác là fix mà audit trước yêu cầu (đóng cửa sổ vĩnh viễn thành cửa sổ 1 lần).
4. **Giới hạn cố hữu, đã tài liệu hoá trung thực:** cùng 1 key hợp lệ có thể redeem trên nhiều thiết bị/nhiều người (không có global one-time-use nếu không có server) — đây là đánh đổi toán học của "no backend", không phải lỗi. Được chặn phần nào bởi per-device redeem list + iOS Keychain ledger (`_redeemed_key_ledger.dart`, sống sót qua uninstall/reinstall trên iOS). README (`packages/ad_sdk/README.md:634-640`) nói thẳng giới hạn này ra, không giấu.
5. Cap 90 ngày (`maxVipStackDuration`) vẫn enforce đúng mọi lúc stack.

**Đánh giá:** đây là mức bảo mật **tối đa có thể đạt được với ràng buộc no-backend tuyệt đối** mà bạn yêu cầu. Rủi ro còn lại (root/jailbreak tamper bộ nhớ tiến trình, hoặc 1 key bị leak dùng chung nhiều máy) nằm ngoài khả năng của bất kỳ giải pháp client-only nào.

---

## 7. Tính năng mới nhất (chưa từng được audit trước đây)

Git log 3 commit gần nhất tại thời điểm audit: `e22ab85` (SSV+crash-guard, message), `510e291` (inspector), `b0b8195` (test docs).

- **Phát hiện thú vị:** `e22ab85` thực ra **rỗng** về code (chỉ đổi `.claude/settings.local.json` + doc test-result) — code SSV/crash-guard thật nằm ở 1 commit trước đó (`4924c20`, cùng message, có thể do rebase/duplicate), đã có test (`reward_ssv_test.dart` 401 dòng, `ad_crash_guard_test.dart`) và **đã pass** trong lần chạy `flutter test` (514/514).
- **SSV (server-side verification cho rewarded ads)** — đây **không phải** backend VIP, mà là plumbing chuẩn AdMob/AppLovin để đối tác tự verify reward ở server của họ. `ad_manager.dart:1617-1627` ghi rõ "SDK does NOT run a server and does NOT verify anything itself". Params `ssvCustomData`/`ssvUserId` mặc định `null`, không phá behavior cũ. **Hiện chưa được host app hoặc example wire thật** (grep 0 hit trong `lib/`) — tính năng có sẵn, đã test, nhưng "trơ" cho tới khi có URL server thật từ đối tác.
- **Crash guard** (`ad_crash_guard.dart`, 75 dòng) — bắt lỗi có chủ đích chỉ khi stack trace thuộc về package của SDK (`isSdkAttributable`, check substring `package:applovin_admob_sdk/`), tự động force-transition slot bị kẹt về cooldown thay vì để crash lan ra. Lỗi không thuộc SDK vẫn được chain tiếp cho handler cũ — không che giấu bug của host app. Thiết kế tốt, có test riêng.
- **Ad inspector (example app, 2026-07-13)** — chỉ là nút gọi thẳng `AppLovinMAX.showMediationDebugger()` / `MobileAds.instance.openAdInspector()`, không phải UI tự chế. **Không có gate `kDebugMode`** — rủi ro thấp *hiện tại* vì chỉ tồn tại trong `packages/ad_sdk/example/` (không phải app thật lên store), đúng convention "demo tính năng mới nằm ở example, không ở host app". **Nếu sau này copy pattern này sang host app, bắt buộc phải gate `kDebugMode` trước** — inspector của AdMob/AppLovin là công cụ QA nội bộ, không nên lộ ra người dùng cuối.

---

## 8. Ad-type coverage & Android/iOS parity (REQ 1+3) — 🟢 Đạt, vài gap testability nhỏ

- Cả 4 format (Banner/Interstitial/AppOpen/Rewarded) implement đầy đủ ở **cả 2 adapter** (`admob_adapter.dart`, `applovin_adapter.dart`), đúng interface `AdProviderAdapter`.
- App Open có watchdog timeout 90s thật ở cả 2 adapter; Interstitial/Rewarded/Banner **không có timeout riêng** — đây là giả định có chủ đích ("native callback đáng tin cậy", có comment giải thích), rủi ro thấp trừ khi native SDK bị treo.
- Dismiss → preload ad tiếp theo: tập trung đúng ở `ad_manager.dart` (interstitial dòng 1513, rewarded dòng 1747), AppLovin không load trùng nhờ guard `isReady`/`isLoading`.
- Banner RouteAware pause/resume đúng (`banner_ad_widget.dart`: subscribe route, pause `didPushNext`, resume `didPopNext`).
- App Open không chồng lên dialog: `ad_manager.dart:1333` check `AdLoadingDialog.isShowing || AdScreenRouteLogger.isDialogOnTop` trước khi show on-resume.
- Native config (APPLICATION_ID/AD_ID/INTERNET/ACCESS_NETWORK_STATE cho Android; GADApplicationIdentifier/AppLovinSdkKey/NSUserTrackingUsageDescription/SKAdNetworkItems cho iOS) đầy đủ ở **cả 4 nơi**: root app (Android+iOS) và example app (Android+iOS).
- **Gap nhỏ, không chặn production:**
  - Example app chọn provider bằng `--dart-define` compile-time, không runtime — 1 lần chạy chỉ test được 1 provider, khó so sánh song song.
  - Example app không có nút "Show" trực tiếp cho App Open (phải background app để trigger) — gap về khả năng test thủ công, không phải bug SDK.
  - `packages/ad_sdk/example/ios/Podfile` — dòng `platform :ios, '13.0'` đang bị **comment out**, lệch với root app (`ios/Podfile:2` đang active) — nên uncomment cho nhất quán.

---

## 9. Đề xuất thứ tự xử lý (không có mục nào là P0 chặn phát hành)

> **Cập nhật 2026-07-13 (sau audit này):** cả nhóm P1 và 5/6 mục P2 bên dưới đã
> được xử lý — xem `doc/task/done/T3{1,3,4,5,6,7,8}-*.md` và `doc/feature.md`.
> T32 vẫn `todo/` do thiếu App ID iOS thật từ user. Danh sách gốc giữ nguyên bên
> dưới để tham chiếu lịch sử. `doc/audit/audit_codex.md` (audit độc lập, cùng
> ngày) khảo sát thêm policy/consent-ordering và tìm ra 2 gap ngoài phạm vi
> audit này, nay track ở `doc/task/todo/T40-*.md` và `T41-*.md`.

**P1 (nên làm trước lần audit kế tiếp):**
- ~~Đóng `_eventStream` trong `ad_manager.dart destroy()`~~ — ✅ T31 done.
- Sửa AdMob Application ID bị trùng Android/iOS trong native config — bắt buộc trước khi bao giờ flip sang AdMob. — 📋 **T32 vẫn todo**, chờ App ID iOS thật.
- ~~Thêm UI state "offline" riêng cho banner~~ — ✅ T33 done (`AdManager().isOfflineListenable`).

**P2 (dọn dẹp, không rủi ro cao):**
- ~~Làm rõ lại doc T10~~ — ✅ T36 done.
- ~~Dispose banner native view tường minh trước khi refresh/reconnect~~ — ✅ T34 done.
- ~~Đóng nốt `mounted` guard còn sót ở tầng ngoài splash~~ — ✅ T35 done.
- ~~Uncomment iOS 13.0 Podfile pin ở `example/ios/Podfile`~~ — ✅ T37 done.
- ~~Gate `kDebugMode` cho nút ad inspector~~ — ✅ T38 done.
- Publish UMP consent form thật trên AdMob console cho app ID production (thao tác tay, đã có checklist ở `doc/UMP_SETUP.md`) — vẫn cần làm tay, chưa track bằng task riêng.

---

## 10. Có nên đưa SDK này vào production app không?

**Có.** Toàn bộ 5 lỗ hổng CRITICAL/nghiêm trọng từ audit gốc (05/07) — consent tự chế không phải CMP hợp lệ, `npa` không forward, impression trước consent, network không auto-recover, VIP base64 decompile-được — đã được **verify thật là đã sửa**, không phải chỉ đóng task trên giấy. Cơ chế VIP-by-code hiện tại (Ed25519 signed-key) đạt mức bảo mật tối đa khả thi cho ràng buộc "không backend" mà bạn đặt ra; giới hạn còn lại (1 key dùng được nhiều máy) là đánh đổi toán học cố hữu, đã được tài liệu hoá trung thực chứ không giấu.

Các gap còn tồn tại (event-stream leak, banner offline UI, AdMob App ID trùng platform, vài chỗ testability ở example app) đều là **P1/P2 kỹ thuật**, không phải rủi ro pháp lý hay bảo mật, và không có gap nào đủ nghiêm trọng để trì hoãn phát hành. Khuyến nghị xử lý nhóm P1 ở trên trong 1-2 buổi làm việc trước khi release tiếp theo, nhưng không bắt buộc phải chặn ship hiện tại.
