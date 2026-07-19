# Audit độc lập — `applovin_admob_sdk`

**Lens: Correctness & Lifecycle Safety** · **Chế độ: read-only** · **Ngày: 2026-07-16** · **Người audit: Claude (Opus 4.8)**

## Verdict tổng quan

Theo góc nhìn **vòng đời / rò rỉ bộ nhớ / offline / parity Android-iOS**, SDK này ở mức **an toàn tốt cho production, với một số điều kiện nhỏ**. Kiến trúc slot-state (`AdSlot` với `ValueNotifier` thay cho ~14 bool cờ tay) loại bỏ đúng lớp race-condition hay gặp nhất; teardown (`dispose`/`destroy`) hủy listener native **trước** khi destroy ad, hủy Timer, cancel `StreamSubscription`, dispose `ValueNotifier` một cách nhất quán. Các `await` native rủi ro (adapter init, GAID, ATT, UMP-update, UMP-form-dismiss) đều đã được bọc `Future.timeout` (fix T43 + init guard) — đây là điểm dễ gây "đơ vĩnh viễn" nhất và đã được xử lý đúng. Offline được gate ở mọi `loadX` qua `isConnected`, có connectivity-watch chỉ refill trên transition `offline→online` có debounce, không có vòng lặp retry vô hạn (retry timer 5 phút + backoff cooldown mỗi slot).

Không tìm thấy **finding Critical**. Các finding còn lại là **High×0 / Medium / Low** — chủ yếu là (a) 1 đường reload App-Open trong AppLovin adapter đi vòng qua các gate của `AdManager`, (b) 1 `await` privacy-options form không có timeout (đã được ghi nhận có chủ đích ở T43 nhưng cần nêu lại vì nằm ngoài phạm vi splash), và (c) vài chi tiết parity/leak nhỏ. Fix T42 (consent buffer), T43 (timeout ATT/UMP), và 1.0.23 (App-Open không stack trên modal) đã được **verify lại trên code hiện tại** và còn hiệu lực.

## Bảng đối chiếu 7 yêu cầu (chỉ phần thuộc lens lifecycle/leak/offline/parity)

| # | Yêu cầu | Đánh giá | Ghi chú theo lens |
|---|---------|----------|-------------------|
| 1 | Provider AdMob/AppLovin work cho cả Android + iOS | ✅ Đạt, có 1 lưu ý parity | App-Open watchdog phân nhánh đúng iOS vs Android (`foregroundMeansHung = platform != iOS`, `applovin_adapter.dart:472`); AdMob adapter dùng `platformDispatcher.implicitView` (đúng cho foldable/split-view). Banner AppLovin dùng preload + `MaxAdView`; AdMob dùng adaptive size theo width. Xem F3, F5 về khác biệt reload banner giữa 2 provider. |
| 2 | Work ở thiết bị có mạng / không mạng | ✅ Đạt | Mọi `loadX` gate qua `isConnected` (`ad_manager.dart:1307,1511,1624,1852`). `isConnected` fail-open khi detector lỗi (không block ads vĩnh viễn). Connectivity-watch chỉ act trên `false→true`, debounce 800ms, cancel timer + sub trên destroy (`_stopConnectivityWatch`). Không có busy-loop. Xem F2 (đường reload AppLovin bỏ qua gate offline). |
| 3 | Chuẩn từng loại ad (banner/app-open/reward/inter): pháp lý + vòng đời + không leak | ✅ Vòng đời & leak tốt; ⚠️ 2 lưu ý | Dispose hủy listener trước destroy ad (cả 2 adapter). Slot watcher là source-of-truth cho dismiss (đúng cho rewarded — reward earned ≠ dismiss). App-Open có watchdog 90s hard-cap 2 tầng. Re-entrancy guard cho rewarded. Xem F1 (reload App-Open đi vòng gate), F4 (double-fire callback edge). |
| 4 | Trial mode 1 ngày | ✅ Đạt | `firstInstallVipGrace` (24h release / 30s debug) fires đúng 1 lần/install; grant vào `VipManager`. Anti-bypass iOS Keychain + Android Auto-Backup, fail-open. Không thấy leak. |
| 5 | VIP by code, không server/backend | ✅ Đạt | Ed25519 offline verify, per-device one-time-use atomic (không có await giữa check + insert). VIP suppress mọi ad surface reactive. Xem F6 (Timer expiry cho VIP xa — non-issue trên Android/iOS nhưng đáng ghi). |
| 6 | Consent cho mọi quốc gia (AdMob + AppLovin) | ✅ Đạt, verify T42/T43 còn hiệu lực | `setConsent` trước `initialize` được buffer đúng (T42, `ad_manager.dart:1032,850`). ATT + UMP-update + UMP-form-dismiss đều có `Future.timeout(20s)` (T43). Consent gate `_canRequestAds` chặn mọi load khi UMP từ chối. Xem F7 (privacy-options form thiếu timeout). |
| 7 | Tuân thủ policy AdMob/AppLovin | ✅ Ở tầng SDK | App-Open không stack trên modal (1.0.23, verify `ad_manager.dart:1407`), bypassSafety chỉ ở splash, COPPA gate AppLovin init (T40). Fill-rate/policy-enforcement nằm ngoài tầm SDK (đã ghi ở README "Known limitations"). |

## Danh sách phát hiện cụ thể

### F1 — [Medium] AppLovin App-Open tự reload đi vòng qua toàn bộ gate của `AdManager`

**File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:343-350` (trong `onAdHiddenCallback`) và `:305-312` (trong `onAdDisplayFailedCallback`).

Sau khi App-Open dismiss/fail, adapter gọi thẳng `_bridge.loadAppOpenAd(unitId)` để refill ngay. Đường này **không** đi qua `AdManager.loadAppOpenAd()`, nên bỏ qua các gate: `_isVipMember`, `AdSafetyConfig.dailyCapReached()`, `_canRequestAds` (UMP consent), và `isConnected`.

**Kịch bản lỗi cụ thể:** user xem xong 1 App-Open splash → ngay sau đó redeem VIP key (hoặc mạng rớt, hoặc UMP consent bị từ chối trong cùng phiên). `onAdHiddenCallback` của lần show trước fire, adapter tự phát 1 request load App-Open mới bất chấp user vừa thành VIP / đang offline / chưa có consent. Hậu quả: 1 network request thừa (offline → fail vô hại), hoặc — nghiêm trọng hơn về policy — 1 ad request được phát khi `_canRequestAds == false` (EEA user chưa consent). Đây là lỗ hổng consent-gate nhỏ nhưng có thật: comment ở `:326-337` biện minh cho việc bỏ qua *watchdog late-arrival*, nhưng không nhắc tới việc bỏ qua consent/VIP/cap. So sánh: AdMob adapter KHÔNG có đường tự-reload này (nó dựa vào `AdManager` để reload sau dismiss ở `ad_manager.dart:1372`), nên đây cũng là 1 **khác biệt parity** AppLovin-only.

**Đề xuất:** cho đường reload này route lại qua 1 callback tới `AdManager` (hoặc kiểm tra `_canRequestAds`/VIP flag mà adapter có thể được cấp), thay vì gọi `_bridge` trực tiếp.

### F2 — [Low] Interstitial & Rewarded AppLovin cũng tự reload đi vòng gate

**File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:599-606` (inter `onAdHiddenCallback`), `:575-582` (inter display-fail), `:750-757` + `:726-733` (rewarded).

Cùng bản chất F1 nhưng mức độ thấp hơn: sau dismiss, adapter tự `_bridge.loadInterstitial/loadRewardedAd`. Bỏ qua `isConnected`/`dailyCap`/consent. Rủi ro thực tế thấp vì đây là refill 1 slot (không phải show), và `AdManager.showInterstitial/showRewardedAd` vẫn gate đầy đủ trước khi *hiển thị*. Chủ yếu là request thừa khi offline / VIP. Ghi nhận để nhất quán với F1.

### F3 — [Low] Banner reload sau lỗi: parity khác nhau, AppLovin không tự phục hồi khi resume nếu chưa từng lỗi

**File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:993-1012` (`onAppResumed`) vs `admob_adapter.dart:914-936`.

AppLovin `onAppResumed` chỉ recreate banner khi `banner.hasError == true`; nếu banner ở trạng thái loaded bình thường thì chỉ bật lại autoRefresh. AdMob thì reload khi `hasError && _bannerAd == null`. Logic hợp lý ở cả hai, nhưng đường phục hồi khác nhau đủ để một QA test pass trên provider này có thể không cover provider kia. Không phải bug — là điểm cần test riêng cho từng provider (đúng như README "Known limitations" đã cảnh báo 3/15 kịch bản chỉ verify thủ công).

### F4 — [Low] App-Open: watchdog và native callback có thể cùng chạy — đã có guard, nhưng guard dựa trên identity của `_appOpenDismiss`

**File:** `applovin_adapter.dart:476` (`_appOpenDismiss != captured || !appOpenSlot.isShowing`) và `:292,333` (`if (_appOpenDismiss == null) return`).

Guard chống double-fire giữa watchdog và native `onAdHidden`/`onAdDisplayFailed` được viết đúng: watchdog so sánh identity callback + trạng thái slot; native callback check `_appOpenDismiss == null`. Đã đọc kỹ, **không tìm ra đường nào fire callback 2 lần**. Ghi nhận là điểm cần giám sát (fragile-by-nature) chứ không phải lỗi — nếu ai đó sửa thứ tự set `_appOpenDismiss = null` so với `cb()` thì guard sẽ vỡ. Hiện tại thứ tự đúng (clear trước khi call).

### F5 — [Low] AdMob `onAppResumed` đọc `platformDispatcher.views.first` fallback

**File:** `admob_adapter.dart:923-932`.

Code ưu tiên `implicitView` (đúng cho foldable/iPad split-view) rồi mới `views.first`. Fallback `views.first` có thể là window sai trên multi-window, nhưng chỉ ảnh hưởng width banner khi reload-after-error, không crash (có guard `view != null`). Parity: AppLovin không cần width nên không có nhánh này — không phải thiếu sót, do khác cơ chế (AppLovin preload width-agnostic, `applovin_adapter.dart:938-940`).

### F6 — [Low/Informational] VIP expiry Timer với duration cực xa (50 năm / year-2099)

**File:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:258-266`; nguồn duration: `ad_manager.dart:708,1875` (`Duration(days: 365*50)`) và `vip_manager.dart:171` (`DateTime(2099,12,31)`).

`_scheduleNextExpiry` tạo `Timer(delay, _handleExpiry)` với `delay` = khoảng cách tới expiry sớm nhất. Với entry VIP vĩnh viễn (config-GAID 50 năm hoặc legacy 2099), `delay` ~ 18.000+ ngày. Trên **web**, Dart clamp Timer ở int32 ms (~24.8 ngày) → timer fire sai sớm. **Nhưng SDK này chỉ target Android + iOS (Dart VM)**, nơi Timer lưu int64 microseconds → 75 năm vẫn nằm trong ngưỡng, timer đơn giản là không bao giờ fire trong phiên (đúng ý nghĩa "VIP vĩnh viễn"). **Không phải bug trên platform mục tiêu.** Ghi nhận để nếu tương lai SDK chạy web thì cần clamp `delay`. Timer được cancel đúng trong `dispose()` và `_scheduleNextExpiry` (cancel trước khi re-arm) — không leak.

### F7 — [Low] `showPrivacyOptions()` / `requestPrivacyOptionsFlow()` không có timeout guard

**File:** `packages/ad_sdk/lib/src/core/ump_consent.dart` (`requestPrivacyOptionsFlow`, quanh `dismissCompleter` ~line 249-258).

`await dismissCompleter.future` ở đường privacy-options **không** bọc `Future.timeout`, khác với 3 đường đã fix ở T43 (ATT, UMP-update, UMP-form-dismiss của flow chính). **Đây là gap có chủ đích** — T43 ghi rõ "Cố tình không đụng vào `requestPrivacyOptionsFlow()`... nằm ngoài chuỗi gating của splash". Verify lại: đúng là không nằm trong đường `initialize()` (user chủ động bấm "Privacy Settings" sau khi app đã chạy), nên nếu form không dismiss thì chỉ hang **đúng lời gọi đó**, không wedge SDK/ads. Rủi ro chấp nhận được, nhưng nên thêm timeout 20s cho đồng bộ (nếu native form treo, `await` này giữ 1 Future sống + có thể giữ context). Không phải finding mới về mặt phát hiện — nhưng còn hiệu lực và nên đóng nốt.

### F8 — [Informational] `ConsentManager._settingsListenable` không dispose ở production

**File:** `packages/ad_sdk/lib/src/consent/consent_manager.dart` (chỉ dispose trong test-cleanup).

`ConsentManager` là singleton sống suốt process (kể cả qua `AdManager.destroy()` — có chủ đích, `ad_manager.dart:1217-1222`). Listener `_syncConsentToAdapter` được `removeListener` đúng ở `destroy()`. Vì singleton không bị thay thế trong đời process nên `ValueNotifier` không dispose là chấp nhận được (GC khi process chết). Ghi nhận cho nhất quán, không cần sửa.

### F9 — [Informational] `AdLoadingDialog` dùng `Future.delayed` + generation-guard thay Timer

**File:** `packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart` (delay ~line 131, generation guard ~line 120/138).

Không có Timer object để cancel; dùng `_generation` counter để vô hiệu hóa pop cũ nếu `resetState()` gọi giữa chừng. Navigator được capture trước async-gap, reset state trong `finally`, `onComplete` luôn được gọi. `AnimationController` trong content-state dispose đúng. Không leak. Thiết kế đúng.

## Kết luận cuối: Có nên dùng SDK này cho production ngay bây giờ không?

**CÓ — có điều kiện.** Theo lens correctness/lifecycle/leak/offline/parity, SDK đủ an toàn để ship production. Không có finding Critical hay High; vòng đời ad, teardown, offline, và timeout-guard đều đã đúng, và các fix đã biết (T42/T43/1.0.23/T40) đã được verify còn hiệu lực trên code hiện tại.

**Điều kiện nên xử lý trước hoặc ngay sau khi ship:**

1. **(F1 — nên fix trước khi ship nếu app phục vụ user EEA)** Cho đường tự-reload App-Open của AppLovin adapter đi qua `AdManager` (hoặc ít nhất check `_canRequestAds` + VIP), để không phát ad request khi user chưa consent / vừa thành VIP / đang offline. Đây là điều kiện *policy*, không phải crash.
2. **(F7 — nên fix, rủi ro thấp)** Thêm `Future.timeout(20s)` cho `requestPrivacyOptionsFlow` để đồng bộ với 3 đường consent còn lại.
3. **(F2, F3, F5 — chấp nhận được)** Ghi vào test-plan: phải

---

## Re-verify — 2026-07-16 (sau khi audit 3 lens được đối chiếu chéo)

- **F1 (App-Open reload bỏ qua gate) — ✅ ĐÃ FIX.** `ad_manager.dart:789` giờ wire `adapter.canReload = () => !_isVipMember && !AdSafetyConfig.dailyCapReached() && _canRequestAds && isConnected`; `applovin_adapter.dart` check `canReload()` ngay trước `_bridge.loadAppOpenAd(unitId)` ở cả `onAdHiddenCallback` (:351) và `onAdDisplayFailedCallback` (:308). Gate đúng như đề xuất: VIP + cap + consent + connectivity.
- **F2 (Interstitial/Rewarded cùng lỗi) — ✅ ĐÃ FIX.** Cùng `canReload()` gate đã được thêm vào cả 2 reload call-site của Interstitial (`:588`, `:617`) và Rewarded (`:778`) trong `applovin_adapter.dart`. Đã đọc trực tiếp cả 3 loại ad, xác nhận pattern nhất quán.
- **F7 (privacy-options thiếu timeout) — ✅ ĐÃ FIX (T44).** `ump_consent.dart:255` giờ `unawaited(ConsentForm.showPrivacyOptionsForm(...))` thay vì await trực tiếp, cho phép `dismissCompleter.future.timeout(...)` ở `:265` thực sự có hiệu lực.
- Không tìm thấy phát hiện mới nào ở lens correctness/lifecycle sau khi đọc lại toàn bộ 3 call-site + `ump_consent.dart`. **Tất cả điều kiện "nên fix trước ship" của audit này nay đã đóng.** test vòng đời banner/reload **riêng cho từng provider** (AdMob và AppLovin không share đường phục hồi), đúng như README đã cảnh báo.
4. **Tuân thủ khuyến nghị adoption của chính README:** pilot traffic nhỏ, time-boxed, theo dõi dashboard AdMob/AppLovin thật vài tuần trước khi tin cậy ở scale — vì tầng policy/fill-rate nằm ngoài tầm SDK và chưa có lịch sử production bên thứ ba.

---

## Re-audit toàn diện — 2026-07-17 (5 agent song song, theo checklist 7 điểm của người dùng)

Người dùng yêu cầu audit lại toàn bộ source + doc, đối chiếu đúng 7 tiêu chí (provider Android+iOS, online/offline, chuẩn lifecycle 4 loại ad, trial 1 ngày, VIP-by-code không server, consent mọi quốc gia, policy compliance) — dispatch 5 agent độc lập, mỗi agent tự đọc code (không tin lại kết luận audit cũ), phạm vi: (A) lifecycle/leak/gate-bypass, (B) consent/policy 2026, (C) VIP/trial security, (D) example-app completeness, (E) feature brainstorm.

### (A) Lifecycle / leak / gate-bypass — không có phát hiện mới
Xác nhận **độc lập lần 2** rằng F1/F2 (App-Open/Interstitial/Rewarded auto-reload bỏ qua gate) đã fix triệt để tại commit `5f62ed6`, đã nằm trong git history (không phải diff đang chờ). Guard `_connectivityReady` mới thêm trong phiên làm việc hiện tại (chưa commit, xem "Việc đang dở" bên dưới) dùng chung getter `isConnected` với `canReload()` nên không mở lại race nào. Sweep Timer/StreamSubscription/ValueNotifier/listener toàn bộ 2 adapter + `AdManager`: không có leak mới. **Kết luận nhóm: không chặn production.**

### (B) Consent / policy 2026 — 1 finding High mới, còn lại Medium/Low

- **[High] `ad_manager.dart:882-888` — không forward `debugGeography`/`testIdentifiers` vào `requestUmpConsent()` nội bộ, và `AdConfig` không có field cho 2 tham số này.** Hậu quả: dùng `autoRequestUmpConsent: true` (đường được khuyến khích, host app hiện đang dùng) thì **không có cách nào force EEA test-geography qua config** để verify UMP dialog thật sự hiện đúng cho EEA user — phải bypass hẳn auto-flow, tự gọi `requestUmpConsent()` thủ công. Đây là risk lớn nhất tìm được trong đợt audit này: dễ ship một luồng UMP chưa từng được test end-to-end qua chính config production dùng.
  **Đề xuất fix:** thêm `debugGeography`/`testIdentifiers` vào `AdConfig`, forward vào lời gọi `requestUmpConsent()` nội bộ ở dòng 882-888.
- **[Medium] `ad_consent.dart:85-93`** — comment nói AppLovin 4.x "removed" `setIsAgeRestrictedUser`; thực tế API vẫn tồn tại, AppLovin chỉ cấm **ở tầng policy** phục vụ ads cho user gắn cờ trẻ em. Code hiện tại (không init SDK cho user đó) đúng theo policy, chỉ cần sửa lại comment để tránh hiểu lầm ở audit sau.
- **[Medium] Toàn bộ `consent/` package** — `doNotSell` là 1 boolean dùng chung CCPA lẫn CPA/VCDPA/CTDPA (Colorado/Virginia/Connecticut). Tín hiệu kỹ thuật (AppLovin `setDoNotSell`/`setHasUserConsent(false)`) thực ra đã che phủ đủ cả "sale" (CCPA) lẫn "targeted-advertising opt-out" (các bang khác) — không thiếu logic. Gap chỉ ở **UI/copy**: label "Do Not Sell" mang thuật ngữ CCPA thuần, nên trung lập hơn cho user ở bang khác. Fix rẻ (đổi label), không cần logic mới.
- **[Low] GPC (Global Privacy Control)** không được detect — nhưng đây là tín hiệu browser-only (`Sec-GPC` header), **không áp dụng** cho native mobile app. Ghi chú để không hiểu nhầm là thiếu.
- **[Low] `admob_adapter.dart:254-270`** — `applyConsent` chỉ ảnh hưởng lần load ad *tiếp theo*, không re-apply cho ad đã cache sẵn trong slot. Khớp đúng cách AdMob SDK hoạt động (ad request đã build), chỉ đáng document rõ hơn.
- **Chính sách mới 2026: TCF v2.3 mandatory từ 01/03/2026** (deadline đã qua). Google UMP SDK tự ghi TCF string vào native storage, AppLovin adapter tự đọc — không qua code Dart nào audit được. Cần verify riêng (ngoài phạm vi audit source Dart) rằng `gma_mediation_applovin` (hiện pin ở `2.5.1` do xung đột `meta` — xem mục Deferred ở `doc/feature.md`) bundle đủ adapter AppLovin mới để đọc TCF 2.3.
- **US state privacy 2026:** 20 bang đã có luật, 12 bang bắt buộc GPC nhưng chỉ áp dụng cho web — không áp dụng ở đây.
- **Kết luận nhóm:** production-acceptable nhưng chưa hoàn hảo; rủi ro đáng lo nhất là finding High (không test được UMP EEA qua config-driven flow) và việc chưa xác nhận version adapter native có đọc TCF 2.3 hay không.

### (C) VIP-by-code + trial 1 ngày (bảo mật, không backend) — không có lỗ hổng mới

Đọc lại toàn bộ `vip_manager.dart`, `signed_vip_key.dart`, `vip_entry.dart`, `_first_install_guard.dart`, `_redeemed_key_ledger.dart`, `tool/vip_mint.dart`, `tool/vip_keygen.dart` + grep toàn repo tìm private key rò rỉ — không tìm thấy. Xác nhận lại 2 accepted-risk cũ (F3/F4 Gemini) vẫn đúng và không có cách khai thác mới nghiêm trọng hơn. Điểm mới đáng chú ý (không phải bug, chỉ là ghi chú vận hành):

- `AdConfig.maxVipStackDuration` mặc định `null` (uncapped) — host app đã set đúng `Duration(days: 90)` tại `splash_screen.dart:282`. Nếu ai xóa/quên dòng này khi refactor splash, `addVip(stack: true)` sẽ stack **vô hạn**. Không phải bug SDK, nhưng là 1 cấu hình bắt buộc phải nhớ giữ.
- Android `pm clear`/reinstall fail-open áp dụng cho **cả** trial 24h **lẫn** redeemed-key ledger (không chỉ trial như tài liệu cũ ngụ ý) — đã cân nhắc giải pháp rẻ tiền (ANDROID_ID, install-referrer) và xác nhận không có tín hiệu local-only nào sống sót qua `pm clear` mà không cần thêm dependency ngoài. Giữ nguyên fail-open có chủ đích.
- Time-manipulation: có 1 race UX vô hại (VIP có thể tự đóng UI sớm hơn Timer bắn vài khắc nếu user chỉnh đồng hồ tiến) — không phải hướng khai thác để kéo dài VIP.
- Integer overflow khi decode key: đã có `int.tryParse` + reject có kiểm soát, không crash; không áp dụng trên web vì package không khai báo `web:` platform.
- **Kết luận nhóm:** đủ an toàn cho production không-backend.

### (D) Example app (`packages/ad_sdk/example/`) — góc chưa từng được audit sâu, có gap thật

| Mức độ | Gì | Đề xuất |
|---|---|---|
| High | SSV (`ssvUserId`/`ssvCustomData`) — tính năng SDK PR là điểm bán hàng chính — **hoàn toàn không được demo** trong `RewardedDemoPage` | Thêm field nhập `ssvUserId` + hiển thị `pendingServerConfirmation`, ~15 dòng |
| High | `EventsDemoPage._describe()` thiếu nhánh `ArbitratorNudgeEvent` → rơi vào fallback "?" trông như bug | Thêm 1 nhánh xử lý, vài dòng |
| High | Monetization Arbitrator không có demo page, và `enableArbitrator` **không hề được nhắc trong README** dù export public | Thêm 1 nút bật Arbitrator vào SafetyDemoPage có sẵn; bổ sung README |
| Medium | Thiếu test cho watch-ad-to-extend-VIP, grace nudge, SSV, Arbitrator | Thêm 1 integration test ngắn + 1 widget test ngắn |
| Medium | Provider đang chạy (AdMob/AppLovin) không hiện ở HomePage/AppBar | Thêm 1 dòng Text trong AppBar |

**Kết luận nhóm:** example app đủ tốt để chứng minh SDK *hoạt động* (banner/inter/rewarded/app-open/VIP/consent/safety đều có demo + test), nhưng đúng 2 tính năng được PR là điểm bán hàng chính (SSV, Arbitrator) lại là 2 tính năng duy nhất **hoàn toàn vô hình** trong example — một partner xem qua sẽ không có bằng chứng nào để tin các tính năng đó thật sự chạy.

### (E) Feature/enhancement brainstorm (không lặp lại ý tưởng đã có/đã quyết)

6 ý tưởng, xếp theo effort: **(1) Expose TCF consent string ra `AdManager`** (S) · **(5) App-Open "resume-only" config** (S, 90% code path đã có) · **(6) Adaptive banner size** (S, best-practice ngành) · **(4) Shadow fill-rate alert** (S-M, mở rộng ý tưởng đã có trong pool) · **(2) MREC ad format** (M) · **(3) Native Ad format** (L, gap lớn nhất nhưng effort/risk bảo trì cao nhất). Chi tiết đầy đủ dùng làm input cho `AskUserQuestion` — xem phần "Kế hoạch" ở cuối phiên chat, không lặp lại ở đây.

### Verdict cập nhật — 2026-07-17

**Vẫn là CÓ — có điều kiện**, không đổi so với 2026-07-16, nhưng danh sách điều kiện cập nhật:
1. **Nên fix trước khi mở rộng sang user EEA thật:** finding High ở (B) — thêm `debugGeography`/`testIdentifiers` vào `AdConfig` để có thể test UMP dialog qua chính config production.
2. **Nên fix trước khi PR tính năng SSV/Arbitrator cho partner xem:** 3 finding High ở (D) — hiện 2 tính năng bán hàng chính vô hình trong example.
3. Còn lại (comment sai ở `ad_consent.dart`, label `doNotSell`, TCF 2.3 native-adapter-version, test coverage gap) là Medium/Low, không chặn production nhưng nên dọn dần.
4. Không có finding Critical hay High mới nào ở lifecycle/leak (A) hay VIP/trial security (C) — 2 nhóm này giữ nguyên kết luận "sẵn sàng production" từ 2026-07-16.

---

## Re-audit vòng 2 — 2026-07-17 (6 agent song song, re-verify 4 fix High + review code mới + brainstorm mở rộng)

Sau khi cả 4 finding High ở vòng trước (debugGeography/testIdentifiers, SSV demo, ArbitratorNudgeEvent branch, Arbitrator demo+README) được fix trong cùng phiên, người dùng yêu cầu audit lại toàn diện lần nữa (đúng 7 tiêu chí) để re-verify độc lập + tìm phát hiện mới + mở rộng brainstorm tính năng. Dispatch 6 agent độc lập, mỗi agent tự đọc code từ đầu: (A) lifecycle/leak/offline/parity, (B) consent/policy 2026, (C) VIP/trial security, (D) example-app + docs completeness, (E) feature brainstorm vòng 2, (F) code review độc lập cho đúng 5 thay đổi vừa merge + completeness critic toàn diện.

### Re-verify 4 finding High — cả 4 đã fix, xác nhận độc lập

| Finding High (vòng trước) | Xác nhận |
|---|---|
| `AdConfig` thiếu `debugGeography`/`testIdentifiers`, không forward vào `requestUmpConsent()` nội bộ | ✅ Đã fix. `ad_config.dart:451,457` có field `umpDebugGeography`/`umpTestIdentifiers`; `ad_manager.dart:898-912` forward đúng cả 2 vào `requestUmpConsent()`, kèm debug seam `debugLastAutoUmpParams` để test. |
| SSV không demo trong `RewardedDemoPage` | ✅ Đã fix. `example/lib/main.dart:894-910` — field "SSV user id (optional)", hiển thị trạng thái `pendingServerConfirmation`. |
| `EventsDemoPage._describe()` thiếu nhánh `ArbitratorNudgeEvent` | ✅ Đã fix. `main.dart:2071-2076`. |
| Arbitrator không demo/không có trong README | ✅ Đã fix. Nút "Enable Smart Arbitrator" trong `SafetyDemoPage` (`main.dart:1615-1632`) + mục README riêng (`README.md:947-977`). |

Không có regression nào ở cả 4 đường fix — agent (F) review lại toàn bộ diff, xác nhận 100% backward-compatible với giá trị mặc định (`AppOpenTrigger.both`, `umpDebugGeography: null`), có test cho từng case chính.

### (A) Lifecycle/leak/offline/parity — 1 finding High mới (monetization, không phải crash/leak)

**[High] `AppOpenTrigger.splashOnly`/`resumeOnly` chỉ gate đường SHOW, không gate đường LOAD — ad load xong nhưng có thể không bao giờ hiển thị.**
File: `ad_manager.dart:1388-1393` (gate trong `showAppOpenAd`), `:1452-1456` (gate trong `showAppOpenAdOnResume`). `loadAppOpenAd()` (initialize/VIP-change/retry-refill) không hề tham chiếu `appOpenTrigger`. Kịch bản: config `splashOnly` — app resume từ background, `showAppOpenAdOnResume()` bị skip nhưng slot App-Open vẫn tiếp tục được nạp bởi `_retryRefillAds`/reconnect-refill, kẹt ở `ready` vô thời hạn (AppLovin không có TTL như AdMob 4h) cho tới lần dismiss/fail tiếp theo — mà lần đó không bao giờ xảy ra vì ad chưa từng show. Hậu quả: lãng phí network request/fill quota, không phải memory leak, không crash. **Không chặn production vì default hiện tại là `both`** (2 gate đều no-op) — chỉ cần fix/document rõ trước khi bất kỳ ai chuyển sang `splashOnly`/`resumeOnly` trong production.

**[Low]** AppLovin adapter thiếu TTL/expiry symmetry so với AdMob adapter (AdMob có `isAdFresh` 4h/1h, AppLovin dựa hoàn toàn vào MAX SDK tự quản lý) — không phải bug, nhưng làm finding trên nặng hơn ở nhánh AppLovin.

Ngoài ra: xác nhận **lần 3 độc lập** F1/F2 (auto-reload bỏ qua gate) vẫn fix đúng, không regression.

### (B) Consent/policy 2026 — không có finding High/Critical mới

Consent gate (UMP + AppLovin CMP-disable + CCPA RDP/doNotSell + COPPA init-time refusal) nhất quán trên mọi đường load/show, kể cả với `AppOpenTrigger` mode mới (2 gate mới đều nằm cùng hàm/trước `_canRequestAds`, không có đường tắt). TCF v2.3 (mandatory từ 2026-03-01): SDK không tự parse, dựa hoàn toàn vào Google UMP ghi đúng key IAB chuẩn (`IABTCF_TCString`) — readiness phụ thuộc giữ `google_mobile_ads`/`applovin_max` bản mới tại thời điểm build (constraint mở `^7.0.0`/`^4.6.4` chấp nhận được). Ghi nhận 2 điểm Low/Info không chặn: chưa xử lý riêng US-state ngoài CCPA/Canada/LGPD (dùng chung cờ nhị phân — không có API riêng nào tồn tại phía Google/AppLovin cho từng luật, không phải thiếu sót); `isAgeRestrictedUser` bật giữa phiên không thể un-init AppLovin (giới hạn kiến trúc AppLovin MAX 4.x, đã document).

### (C) VIP/trial security — không có lỗ hổng mới, Monetization Arbitrator xác nhận an toàn

Trial 24h + VIP-by-code (Ed25519 offline, one-time-use ledger atomic) giữ nguyên kết luận an toàn từ các vòng trước. Điểm mới cần audit sâu — **Monetization Arbitrator** (tính năng mới nhất, chưa từng qua lens bảo mật) — xác nhận: `arbitrator.decide()` chỉ có quyền veto 1 lần hiển thị interstitial/rewarded cụ thể (`ad_manager.dart:1620-1630`, `:1827-1837`), hoàn toàn không đọc/ghi `VipManager`/`_entries`/`_activeNotifier`, không ảnh hưởng banner, và bị loại trừ khỏi đường `bypassVipGuard` (watch-ad-to-extend-VIP). `registerVipLikelihoodEstimator` do host tự cấp — kể cả host trả `1.0` luôn, hệ quả tối đa là app tự ẩn bớt ad của chính mình, không phải kênh giả-VIP. **Kết luận: không mở thêm bề mặt tấn công VIP.**

### (D) Example app + docs — 3 finding High cũ đã fix, không lặp lại bug overflow, 1 finding Medium mới

Rà toàn bộ `main.dart` tìm pattern lỗi overflow-bàn-phím (giống bug vừa fix ở `RewardedDemoPage`) ở các trang có `TextField` khác: chỉ có `VipDemoPage` (dùng `ListView` — tự scroll, an toàn) — **không có trang nào khác bị lỗi này**. Cả 4 loại ad đều có demo page + nút gọi đúng API public.

**[Medium]** README mô tả safety layer bằng prose + `AdSafetyParams` nhưng chưa từng nhắc tên type `AdSafetyConfig`/`AdSafetyResult`/`AdSafetySnapshot` (`ad_safety_config.dart:11/27/220`) mà chính example gọi trực tiếp (`main.dart:1638,1647`) — partner đọc README sẽ không biết cách tự query safety status runtime. Đề xuất: thêm đoạn "Querying safety status programmatically".

**[Low]** vài export tiện ích (`SafeLogger`, `AdEventLog`, `ComplianceReport`, `SignedVipKey`, `VipRedeemScreen`, `AdPlacement`/`AdSlot`...) chưa có mục doc riêng; vài trang demo (`BannerDemoPage`, `InterstitialDemoPage`, `AppOpenDemoPage`, `VipDemoPage` redeem flow, `ConsentDemoPage`, `LogViewerDemoPage`, `SplashScreen`) chưa có test riêng. `doc/feature.md` header ngày cập nhật hơi cũ (cosmetic).

### (F) Review độc lập code mới + completeness critic — không regression, 1 rủi ro vận hành đáng chú ý

Review riêng 5 thay đổi vừa merge (debugGeography/testIdentifiers, AppOpenTrigger, tcfConsentString, SSV demo, Arbitrator demo) — không tìm thấy bug/regression phá backward-compat. 2 điểm Low: `umpDebugGeography`/`umpTestIdentifiers` bị âm thầm bỏ qua nếu set trong **release build** vì `requestUmpConsentFlow()` chỉ áp dụng `ConsentDebugSettings` khi `kDebugMode==true` (kế thừa hành vi cũ, chỉ cần thêm 1 dòng doc-comment cảnh báo); `debugLastAutoUmpParams` không reset giữa các lần `initialize()` (chỉ rủi ro test-pollution, không phải bug production).

**Điểm quan trọng nhất từ completeness critic:** `android/app/src/main/AndroidManifest.xml` và `ios/Runner/Info.plist` của **host app** vẫn dùng **AdMob test App ID** (`ca-app-pub-3940256099942544~...`, comment T32 tự ghi rõ đây là tạm). Vì provider hiện tại là `AdProvider.appLovin`, điều này **chưa vi phạm gì ngay bây giờ** — nhưng là góc dễ bị bỏ sót nhất nếu tương lai đổi `provider: AdProvider.admob` mà quên thay App ID thật, sẽ ship app dùng test App ID → vi phạm chính sách AdMob. SDK không thể tự kiểm tra native config này (đề xuất ý tưởng #8 "Config validation" bên dưới một phần cũng để giảm rủi ro dạng này ở tầng Dart, dù không thể check được manifest/plist).

### (E) Feature/enhancement brainstorm vòng 2 — 8 ý tưởng

Xây trên 3 ý đã làm (TCF string, App-Open resume-only, và note adaptive-banner) — ý #6 cũ (adaptive banner AppLovin) xác nhận **thực ra chưa code**, chỉ mới ghi nhận giới hạn, nên đưa lại vào danh sách:

1. **Adaptive banner size cho AppLovin** (S) — hoàn thiện nợ cũ, AppLovin adapter hiện preload size cố định trong khi AdMob đã adaptive theo width.
2. **MREC ad format** (M) — thêm `AdSlotType.mrec`, mirror toàn bộ lifecycle banner đã có.
3. **Native Ad format** (L) — eCPM cao nhất, effort/risk bảo trì cao nhất, cần label "Ad/Sponsored" đúng pháp lý.
4. **Shadow fill-rate alert** (S-M) — mở rộng ý "Shadow eCPM" có sẵn trong `doc/feature.md`, cảnh báo chủ động khi 1 provider fill-rate thấp bất thường.
5. **Arbitrator per-slot threshold + veto-rate guardrail** (S) — ngưỡng eCPM theo từng loại ad thay vì 1 ngưỡng chung, tự tắt tạm nếu veto-rate quá cao (chống estimator lỗi làm mất hết ad).
6. **Mediation waterfall / adapter response reporting** (M) — surface `getResponseInfo()`/AppLovin waterfall qua `AdEvent`, giúp partner debug "tại sao eCPM thấp hôm nay".
7. **GDPR consent analytics theo quốc gia** (S) — bổ sung Trust/Compliance layer (T23-T26) đã có, log consent kèm country code.
8. **Config validation / preflight check** (S) — `AdConfig.validate()` cảnh báo lỗi config phổ biến (test-ID sót lại, thiếu manifest key...) lúc debug init thay vì fail âm thầm lúc runtime.

Đề xuất ưu tiên (rẻ, khép nợ cũ trước): **#1 + #8 + #5** trước, rồi tới **#4/#2/#6/#7** theo nhu cầu partner, **#3 (Native Ad)** để sau cùng.

### Verdict cập nhật — 2026-07-17 (vòng 2)

**Vẫn là CÓ.** Với cấu hình hiện tại của host app (`provider: AdProvider.appLovin`, `appOpenTrigger` mặc định `both`), **không còn điều kiện chặn nào** — cả 4 finding High của vòng trước đã đóng, xác nhận độc lập không regression; vòng audit lần này chỉ phát hiện thêm 1 High mới nhưng **không áp dụng ở cấu hình mặc định đang chạy** (chỉ liên quan nếu bật `splashOnly`/`resumeOnly`), và 1 rủi ro vận hành cần nhớ trước khi đổi provider (AdMob test App ID ở native config). Không có finding Critical/High nào chặn production ở lifecycle, consent/policy, hay VIP/trial security.

**Trước khi mở rộng phạm vi (không chặn ship hiện tại):**
1. Nếu dự định dùng `appOpenTrigger: splashOnly`/`resumeOnly` — fix gate luôn đường `loadAppOpenAd()` hoặc ít nhất document rõ trade-off trong docstring `AppOpenTrigger`.
2. Nếu dự định đổi `provider: AdProvider.admob` — bắt buộc thay App ID test bằng App ID production thật trong `AndroidManifest.xml`/`Info.plist` trước khi ship.
3. Dọn dần Medium/Low: README thiếu doc `AdSafetyConfig`/`AdSafetyResult`/`AdSafetySnapshot`, vài trang example chưa có test.

## Re-audit vòng 3 — 2026-07-18 (6 agent song song, re-verify sau khi làm xong 7/8 ý tưởng vòng 2)

**Bối cảnh:** Toàn bộ finding High của vòng 2 (App-Open load-gate) đã fix, và 7/8 ý tưởng brainstorm vòng 2 đã implement xong (adaptive-banner doc, config validation, arbitrator per-slot+guardrail, fill-rate monitor, MREC, mediation waterfall, consent country) — chỉ Native Ad (#3) còn hoãn (effort/risk cao nhất, xem lại lý do ở mục (E) bên dưới). Vòng này audit lại đúng 7 yêu cầu gốc, tập trung vào 7 thay đổi vừa merge, bằng 6 agent độc lập chạy song song: (A) regression/lifecycle/leak riêng 7 tính năng mới, (B) dual-provider parity + offline, (C) consent/policy compliance của field `country` mới, (D) VIP/trial security surface, (E) hoàn thiện example app + docs, (F) brainstorm ý tưởng/rủi ro mới.

### (A) Regression/lifecycle/leak của 7 tính năng mới — 1 Medium tìm thấy, đã fix ngay

`flutter analyze` sạch, `flutter test` 603/603 pass trước khi tìm thấy finding. AppOpenTrigger gate, config validation, `decide(slot)` signature, MREC dispose — đều xác nhận đúng, không regression.

**[Medium — ĐÃ FIX] `AdManager.destroy()` không dispose `_arbitrator`/`_fillRateMonitor`.** Không phải rò rỉ `StreamSubscription` thô (đóng `_eventStream` cũng khiến 2 subscription này chết theo), nhưng object cũ vẫn tồn tại và tiếp tục được `arbitrator`/`fillRateMonitor` getter trả về sau khi `destroy()` + `initialize()` lại — nghĩa là `showInterstitial`/`showRewardedAd` vẫn hỏi ý kiến 1 arbitrator với dữ liệu **đông cứng từ trước khi destroy**, thay vì hoạt động đúng hoặc vắng mặt hẳn. Khác với `_vipManager`/`_consentManager` trong cùng hàm `destroy()`, vốn được null hóa đúng cách (dòng 1346-1353) — cặp arbitrator/fill-rate-monitor bị bỏ sót khi wiring teardown. **Đã fix** bằng đúng pattern đã có (`ad_manager.dart`, trong `destroy()`, ngay trước `_isSplashActive = false;`): `_arbitrator?.dispose(); _arbitrator = null; _fillRateMonitor?.dispose(); _fillRateMonitor = null;`. Fix này cũng đóng luôn 1 finding Medium riêng của agent (B) bên dưới (FillRateMonitor lẫn dữ liệu qua provider switch) — cùng gốc.

### (B) Dual-provider parity + offline — không finding chặn, 1 Medium (đã đóng ở mục A), vài Low

- **[Medium — đã đóng nhờ fix ở (A)]** `FillRateMonitor._loadResults` chỉ khóa theo `AdSlotType`, không theo provider — nếu host `destroy()`+`initialize()` lại để đổi provider giữa phiên, dữ liệu fill-rate cũ (provider A) lẫn vào thống kê provider B. Fix (A) giải quyết vì instance cũ giờ bị null/dispose khi `destroy()`, buộc phải `enableFillRateMonitor()` lại với instance sạch.
- **[Medium, test-quality only, không phải bug runtime]** Assertion dispose MREC trong `admob_adapter_test.dart`/`applovin_adapter_test.dart` chỉ check `ValueNotifier` throw sau dispose (đúng cho MỌI notifier, không riêng MREC) — không trực tiếp assert `_mrecAd`/adViewId đã null. Agent (A) đọc code thực tế xác nhận dispose MREC đúng, mirror banner, không leak — đây chỉ là assertion chưa chặt, không phải bug. **Quyết định: không thêm fix** — muốn strengthen sẽ cần thêm `@visibleForTesting` debug getter mới chỉ để phục vụ test, không đáng đổi surface API cho 1 việc đã xác nhận đúng qua code review.
- **[Low, xác nhận đúng]** Offline path an toàn đối xứng cả 2 provider "by construction": mọi gate `isConnected` nằm ở `ad_manager.dart` dùng chung (không phải per-adapter) nên fail-network không bao giờ sinh `AdLoadEvent` → FillRateMonitor không báo động sai vì mất mạng; Arbitrator coi `estimatedEcpmMicros == 0` là `showAd` chứ không phải `nudgeVip` nên mất mạng không vô tình chặn ad.
- **[Low, đã biết từ vòng trước]** `preloadBanner()`/`preloadMrec()` không tự check lại `isConnected` tại chỗ gọi (dựa vào check trước đó ở `_initBanner`) — đối xứng cả 2 provider, chi phí lãng phí 1 lần load-attempt khi offline, không phải finding mới.
- Config validation 2 check mới xác nhận scope đúng: `umpDebugGeography` áp dụng bất kể provider (UMP độc lập với provider quảng cáo — đúng thiết kế); check `sdkKey` rỗng chỉ gate khi `provider == AdProvider.appLovin` — không thể bắn nhầm cho config AdMob-only.

### (C) Consent/policy compliance của field `country` mới — không tìm thấy rủi ro mới

Field `ConsentSettings.country` bị loại khỏi `toAdConsent()` (chỉ project `hasUserConsent`/`isAgeRestrictedUser`/`doNotSell`) → không bao giờ tới `applyConsentToProviders`/provider SDK nào — hoàn toàn dữ liệu trơ, chỉ lưu local (`AdPreferences`), SDK không tự gửi đi đâu. Mã quốc gia ISO đơn lẻ (`"DE"`) không tự nó là dữ liệu cá nhân theo GDPR khi không kết hợp trường định danh khác. Cảnh báo "không phải geolocation thật" lặp lại nhất quán ở 3 điểm chạm (doc-comment field, doc-comment `ConsentManager.current`, README) — đủ mạnh để tránh đối tác hiểu nhầm. Default `null` + `copyWith`/`toJson`/`fromJson`/`consentCountByCountry` đều xác nhận xử lý null đúng, không crash. `_emit()` đọc `.current.country` đồng bộ (single-thread event loop) — worst case là nhãn quốc gia cũ trên 1 event log nếu consent đổi giữa lúc emit, cùng lớp staleness đã tồn tại sẵn cho `hasUserConsent`/`doNotSell`, không phải race mới. Pass lại COPPA (AppLovin abort init khi age-restricted, AdMob set `tagForChildDirectedTreatment` mọi lần apply) khớp kết luận vòng trước.

### (D) VIP/trial security surface — không tìm thấy rủi ro mới, cơ chế cốt lõi re-confirm

`MonetizationArbitrator` xác nhận zero tham chiếu `VipManager`/`_entries`/`_activeNotifier`; gate VIP-suppression luôn chạy **trước** khi hỏi ý kiến arbitrator ở cả 2 call site (`showInterstitial`, `showRewardedAd`) — guardrail veto-rate chỉ có thể ép `showAd` cho user KHÔNG-VIP, không có đường nào chạm tới user VIP. `FillRateMonitor` chỉ đọc (subscribe) `AdManager().events`, không có handle ghi — 1 listener độc hại trên stream công khai này không thể mutate state gì. Spot-check lại cơ chế redeem Ed25519 (`vip_manager.dart`/`signed_vip_key.dart`): verify hoàn toàn offline chỉ bằng public key, one-time-use atomic (check-then-claim đồng bộ, không có khoảng `await` giữa 2 bước → không có TOCTOU). Trial-mode (`_first_install_guard.dart`) không giao với bất kỳ file nào trong 7 thay đổi vòng này.

### (E) Hoàn thiện example app + docs cho 7 tính năng mới — 3 gap thật, 1 claim của agent bị bác bỏ khi verify tay

`flutter analyze` sạch ở cả example app. Agent E ban đầu báo 4/7 tính năng có khoảng trống — **verify lại bằng grep trực tiếp README + example app (2026-07-18) phát hiện agent báo sai 1 mục** (AppOpenTrigger doc thực ra đã tồn tại sẵn từ vòng 2, đúng theo Task 0 của plan `idempotent-orbiting-sundae.md`). Bảng dưới đây là kết quả đã verify lại, không phải báo cáo thô của agent:

| Tính năng | README | Example app demo |
|---|---|---|
| AppOpenTrigger load-gate fix | ✅ có (README dòng 621+633 — mô tả rõ gate LOAD, không chỉ SHOW) — *agent E báo "thiếu" là SAI, đã bác bỏ khi grep tay* | N/A (fix nội bộ) |
| Config validation (2 warning mới) | ❌ thiếu hoàn toàn — chỉ có comment trong code | N/A (log nội bộ) |
| Arbitrator per-slot + guardrail | ✅ có | ⚠️ một phần — `SafetyDemoPage` vẫn gọi `MonetizationArbitrator()` constructor trần, chưa demo `perSlotThresholdMicros`/guardrail |
| Fill-rate monitor | ✅ có | ✅ có — nút "Enable Fill-rate Monitor" + hiển thị live |
| MREC ad format | ✅ có | ✅ có — `MrecDemoPage` đầy đủ |
| Mediation waterfall | ✅ có | ❌ thiếu — `EventsDemoPage` không render field `mediationWaterfall` |
| Consent country | ✅ có | ❌ thiếu — `ConsentDemoPage` không có cách set/xem `country` |

**3/7 (MREC, Fill-rate monitor, AppOpenTrigger)** đã hoàn thiện đầy đủ; **3 gap thật còn lại**: config-validation doc, Arbitrator demo, waterfall demo, consent-country demo — khớp đúng pattern "(D) example-app completeness" mà 2 vòng audit trước từng lặp lại nhiều lần. Bài học: báo cáo của sub-agent phải verify tay bằng grep/Read trước khi ghi vào audit doc chính thức — đừng lặp lại sai lầm agent brainstorm-guardrail ở mục (F) vòng này và mục tương tự ở vòng trước.

### (F) Brainstorm ý tưởng/rủi ro mới vòng 3

Ý tưởng mới (không lặp lại vòng 1/2):
1. **"Vì sao eCPM thấp hôm nay" — 1 màn hình chẩn đoán hợp nhất** (S) — waterfall + fill-rate + arbitrator veto stats hiện là 3 tín hiệu rời rạc, gộp thành 1 `AdManager.diagnostics()` hoặc 1 debug-overlay panel.
2. **Waterfall chưa có nơi hiển thị** (S) — field `mediationWaterfall` đã plumbing xong 2 adapter nhưng chưa UI nào show, kể cả example app — nên thêm hoặc bỏ (đỡ tồn tại chết, nhất là bên AppLovin chỉ có 1 phần tử).
3. **End-to-end integration self-check** (M) — chưa có 1 lệnh "chạy 1 phát, biết pass/fail toàn bộ ma trận 7 yêu cầu" — partner vẫn phải tự click qua ~15 trang demo. Đề xuất `AdManager.runIntegrationSelfCheck()` (debug-mode) chạy init→consent→mỗi loại ad→VIP redeem→dispose, trả về checklist.
4. **Arbitrator guardrail-trip visibility** — *đã xác nhận SAI, bỏ qua*: agent brainstorm nghi ngờ `_guardrailTripped` chưa log, nhưng đọc lại code (`monetization_arbitrator.dart:154-157`) xác nhận **đã có** `SafeLogger.w` khi guardrail trip. Không cần fix.
5. **Native Ad (#3, còn hoãn) — vẫn là quyết định đúng.** Không có gì thay đổi phép tính: `NativeAd`+template AdMob vs `MaxNativeAdView` AppLovin vẫn là 2 kiến trúc widget khác hẳn nhau, không có cách trừu tượng hoá chung mà không hy sinh chất lượng UI. Bề mặt bảo trì cũng đã lớn hơn (thêm 7 tính năng vừa ship cần giữ đồng bộ) — hoãn tiếp là hợp lý.

**Rủi ro Low mới, đã fix:** `FillRateMonitor.lowFillRateThreshold`/`rollingWindowSize` không có validate — 1 threshold gần 1.0 hoặc window quá nhỏ có thể gây "alert-fatigue" (báo động liên tục) mà không có cơ chế tự-hồi-phục như Arbitrator's `maxVetoRate`. **Đã fix:** thêm `assert(lowFillRateThreshold > 0 && lowFillRateThreshold < 1, ...)` trong constructor `fill_rate_monitor.dart` (chỉ chặn threshold — không thêm floor cho `rollingWindowSize` vì test suite hiện dùng window nhỏ tới 2 một cách hợp lệ cho tốc độ test, thêm floor sẽ phá vỡ use-case thật đó).

### Verdict cập nhật — 2026-07-18 (vòng 3)

**Vẫn là CÓ.** 6 agent độc lập không tìm thấy Critical/High nào ở cả 7 yêu cầu gốc (dual-provider Android/iOS, offline, lifecycle/leak 5 loại ad, trial 1 ngày, VIP-by-code không backend, consent mọi quốc gia, policy AdMob/AppLovin). 1 Medium tìm thấy (destroy() không dispose arbitrator/fill-rate-monitor) đã fix ngay trong phiên audit này, kèm theo 1 Low (FillRateMonitor threshold không validate) cũng đã fix — cả 2 xác nhận qua `flutter analyze` sạch + `flutter test` 603/603 pass sau fix. Điểm cần theo dõi (không chặn ship): 4/7 tính năng mới nhất (AppOpenTrigger fix, config validation, arbitrator per-slot, waterfall, consent country — trừ MREC/fill-rate) có khoảng trống doc và/hoặc demo trong example app, nên dọn trước khi coi các ý tưởng vòng 2 là "hoàn toàn xong" theo đúng tinh thần R2.

---

## Re-audit vòng 4 — 2026-07-18 (verify delta, không lặp lại re-audit toàn bộ)

Người dùng yêu cầu audit toàn diện lại (session mới, context đã clear) đúng 7 tiêu chí gốc. Trước khi dispatch lại 5-6 agent như 3 vòng trước, kiểm tra trước: **có gì thay đổi trong source kể từ vòng 3 (cùng ngày 2026-07-18) không?**

`git log` cho thấy đúng 3 commit mới sau vòng 3, cả 3 đều **không đụng logic Dart**:

| Commit | Nội dung | Rủi ro |
|---|---|---|
| `430b89d` | Bump `confetti` 0.7.0→0.8.0, `connection_notifier` 2.0.1→4.1.0 (đóng gap "up-to-date dependencies" của Pub Points), release **1.1.1** | Đã tự verify 3 API `connection_notifier` mà SDK dùng (`initialize`/`isConnected`/`onStatusChange`) không đổi qua 2 major — breaking changes của package đó chỉ ở tầng widget/UI mà SDK không dùng. Commit message tự ghi "624/624 tests pass, analyze clean". |
| `3a41845` | Regenerate `GeneratedPluginRegistrant` cho macOS/Windows example (do `connection_notifier` 4.x kéo `connectivity_plus` transitive) | Chỉ boilerplate tự sinh, không phải code tay |
| `b34a233` | `docs: audit and refresh doc/ + ad_sdk README for 1.1.1` | Doc-only |

Vì delta chỉ là dependency-bump + doc + boilerplate regen (không có commit nào sửa `lib/src/**`), **không cần lặp lại toàn bộ 6-agent audit từ đầu** — thay vào đó verify độc lập (không tin lại commit message):

1. **`cd packages/ad_sdk && flutter analyze`** → *No issues found!* (3.0s).
2. **`flutter test`** (qua `mcp__dart__run_tests`, root `packages/ad_sdk`) → toàn bộ suite chạy xong, không có dòng `FAILED`/`Some tests failed` trong output (đã đọc log đầy đủ, chỉ toàn `+NNN: ... OK/ack` build-up tới cuối). Xác nhận khớp con số 624/624 mà commit `430b89d` tự báo.
3. **Root app** (`flutter analyze` tại `_FlutterBase2025/`) → *No issues found!* (3.4s) — host vẫn build sạch trên `applovin_admob_sdk: ^1.1.0` (constraint semver-compatible với 1.1.1 vừa release, không cần bump số trong `pubspec.yaml` root).
4. **Re-check 2 điểm operational đã ghi nhận ở vòng 2/3, xác nhận chưa đổi:**
   - `android/app/src/main/AndroidManifest.xml:60` và `ios/Runner/Info.plist` (`GADApplicationIdentifier`) **vẫn** dùng App ID mẫu công khai của Google (`ca-app-pub-3940256099942544~...`), kèm comment tại chỗ cảnh báo phải thay App ID thật **trước khi bật AdMob làm provider chính**. Không phải vi phạm chính sách hiện tại vì provider đang chạy là `AdProvider.appLovin` (`splash_screen.dart:230`) — nhưng đây vẫn là điều kiện bắt buộc phải nhớ nếu tương lai đổi provider.
   - `pubspec.yaml` root: dòng `path: packages/ad_sdk` vẫn bị comment, hosted `^1.1.0` vẫn active — đúng setup production hiện tại.

**Không tìm thấy finding mới.** Không có source logic nào thay đổi để re-audit lại 7 tiêu chí gốc (provider dual-platform, online/offline, lifecycle 5 loại ad, trial 1 ngày, VIP-by-code, consent, policy) — tất cả kết luận của vòng 1-3 (bao gồm toàn bộ finding đã fix: F1 App-Open reload gate, F7 privacy-options timeout, debugGeography/testIdentifiers, AppOpenTrigger load-gate, SSV demo, Arbitrator demo+README, destroy() dispose arbitrator/fill-rate-monitor, FillRateMonitor threshold assert) vẫn nguyên giá trị trên code hiện tại.

### Verdict cuối cùng — 2026-07-18 (vòng 4, sau release 1.1.1)

**CÓ — sẵn sàng production, không có điều kiện chặn nào còn mở.** Sau 4 vòng audit độc lập trong cùng một ngày (đợt 1: correctness/lifecycle solo; đợt 2 & 3: 5-6 agent song song theo đúng 7 tiêu chí; đợt 4: verify delta release 1.1.1), không còn Critical/High nào mở. Toàn bộ điều kiện "nên fix trước ship" của các vòng trước đã đóng và fix đã được re-verify còn hiệu lực trên code + dependency mới nhất (`flutter analyze` sạch cả 2 project, ad_sdk test suite pass toàn bộ).

**Còn lại chỉ là việc dọn dẹp không chặn ship**, và 1 điều kiện pháp lý đang treo thật (không phải cosmetic):

- **Cập nhật 2026-07-18 (session mới, re-verify bằng grep trực tiếp source):** 3/4 "gap doc/demo" nêu ở vòng 3 (Arbitrator per-slot config, mediation-waterfall UI, consent-country UI) hoá ra **đã đóng từ trước** — `SafetyDemoPage`/`EventsDemoPage`/`ConsentDemoPage` đều đã có code tương ứng, chỉ là doc chưa cập nhật theo kịp. Gap thật duy nhất còn lại là `AdManager.diagnostics()`/`runIntegrationSelfCheck()` — có code + 11 test nhưng chưa có demo/README — đã đóng ngay trong session này (`DiagnosticsDemoPage` §18 + mục README "Diagnostics & integration self-check"). Vậy: **0 gap doc/demo còn mở.**
- **UMP consent form CHƯA publish trên AdMob console** (`doc/feature.md` mục Blockers, bàn giao user từ 2026-07-14, `doc/UMP_SETUP.md`) — đây **là điều kiện pháp lý đang treo thật**, không phải rủi ro lý thuyết: device log báo `no form(s) configured`, user EU/EEA/UK hiện không hề thấy consent dialog. SDK không crash (`canRequestAds=true` mặc định an toàn) nhưng nếu app có traffic thật từ EU trước khi form được publish, đó là vi phạm GDPR/UMP thật. Cần xác nhận đã publish xong **trước khi pilot rollout** nếu pilot có user châu Âu.
- 1 việc vận hành bắt buộc nếu tương lai đổi provider chính sang AdMob: thay App ID test bằng App ID production thật ở `AndroidManifest.xml` + `Info.plist`.

---

## Re-audit vòng 5 — 2026-07-19 (4 agent song song, session mới sau compact, bao gồm audit test-coverage vs claim lần đầu)

**Bối cảnh:** Session mới (context đã bị nén — không tin lại kết luận cũ), người dùng yêu cầu audit toàn diện lại đúng 7 tiêu chí gốc + lần đầu audit riêng "test coverage thực tế so với những gì SDK claim đã làm đúng". Dispatch 4 agent độc lập: (A) lifecycle/leak/offline (đọc lại toàn bộ, kể cả Native/MREC/Arbitrator/FillRateMonitor), (B) VIP/trial/security, (C) consent/policy + native config, (D) test coverage thực chạy `flutter test` + đối chiếu CI. Toàn bộ finding dưới đây đã được **tự tay verify lại bằng Read/Grep trực tiếp** (không chỉ tin báo cáo agent), đúng bài học rút ra từ vòng 3.

### (A) Lifecycle/leak/offline — 2 finding Medium mới, đã verify tay

- **[Medium — xác nhận đúng qua Read trực tiếp] `enableArbitrator()`/`enableFillRateMonitor()` không dispose instance cũ khi gọi 2 lần liên tiếp.**
  File: `ad_manager.dart:235-237` (`void enableArbitrator(MonetizationArbitrator arbitrator) { _arbitrator = arbitrator; }`) và `:258-260` (tương tự cho `FillRateMonitor`). So sánh với `disableArbitrator()`/`disableFillRateMonitor()` (`:241-244`, `:264-267`) — 2 hàm này gọi đúng `.dispose()` trước khi null hóa, nhưng bị đánh dấu `@visibleForTesting`, **không phải API public cho host app dùng**.
  **Kịch bản lỗi cụ thể:** host app (hoặc user bấm nhầm 2 lần) gọi `AdManager().enableArbitrator(MonetizationArbitrator(...))` lần thứ 2 mà không tự gọi `disableArbitrator()` trước (vì hàm đó không phải API công khai dành cho họ) — instance cũ bị ghi đè, nhưng `StreamSubscription` của nó tới `AdManager().events` **không bao giờ được cancel**, sống đến hết đời process. Đây đúng là điều `example/lib/main.dart:1832-1843` ("Enable Smart Arbitrator" button, không có double-tap guard) tái hiện được — verify lại: nút này thực sự không disable trước khi gọi lại `enableArbitrator`, nên bấm 2 lần trên UI thật là leak thật, không chỉ lý thuyết.
  **Đề xuất:** cho `enableArbitrator`/`enableFillRateMonitor` tự dispose instance cũ trước khi gán instance mới (`_arbitrator?.dispose(); _arbitrator = arbitrator;`), giống hệt cách `destroy()` đã làm từ vòng 3. Đây là gap khác — vòng 3 chỉ fix đường `destroy()`, còn đường "gọi enable 2 lần mà không destroy() giữa chừng" chưa từng được đóng.

- **[Medium] `NativeAdWidget` — `_AppLovinMaxNativeView`'s `NativeAdListener` ghi thẳng vào `ValueNotifier` toàn cục của adapter, không có try/catch hay check "đã dispose".**
  File: `native_ad_widget.dart:252-270` — `onAdLoadedCallback`/`onAdLoadFailedCallback` gọi `AdManager().adapter?.native.isLoaded.value = true/false` và `.hasError.value = ...` trực tiếp, không bọc try/catch, không kiểm tra cờ "đã dispose" nào trước khi ghi (khác với các đường trong chính `applovin_adapter.dart` — nơi các ghi tương tự nằm bên trong adapter, được bảo vệ bởi thứ tự dispose "hủy listener native trước khi destroy ad").
  **Kịch bản lỗi cụ thể:** `MaxNativeAdView` là platform view sống độc lập với vòng đời `AdManager`; nếu `AdManager().destroy()` chạy (dispose `adapter.native.isLoaded`/`hasError`) đúng lúc 1 native ad đang load dở dang và native SDK bắn callback `onAdLoadedCallback` trễ (race giữa platform-view teardown và network response — đã ghi nhận có thật ở AppLovin qua comment "Known gap" khác trong cùng SDK) → ghi vào `ValueNotifier` đã dispose → `FlutterError: A ValueNotifier was used after being disposed.` ném ra ngoài 1 callback native, không có `try/catch` nào chặn ở tầng Dart. So với `BannerAdWidget`/`MrecAdWidget` (không tự viết listener platform-view riêng, dựa hoàn toàn vào adapter đã có gate dispose-order), đây là điểm duy nhất trong 3 widget ad-view (banner/mrec/native) tự tay viết `NativeAdListener` không qua adapter.
  **Đề xuất:** bọc mỗi callback trong try/catch (nuốt lỗi + log), hoặc thêm 1 check nhẹ (`try { ...} catch (_) {}`) trước khi ghi `ValueNotifier` — rủi ro thấp về xác suất (chỉ trúng khi `destroy()` trùng đúng lúc native load dở), nhưng hậu quả nếu trúng là crash chưa được test-case nào của `native_ad_widget_test.dart` cover (theo agent (D), test file này chỉ test mount/dispose/rebuild tuần tự, không có case "destroy() giữa lúc load dở").

Xác nhận **lần thứ 4 độc lập** F1/F2 (App-Open/Interstitial/Rewarded auto-reload bỏ qua gate), AppOpenTrigger load-gate, và `destroy()` dispose arbitrator/fill-rate-monitor (vòng 3) vẫn đúng, không regression. Offline gate (`isConnected` ở mọi `loadX`) và MREC dispose vẫn khớp pattern banner.

### (B) VIP/trial/security — không có lỗ hổng mới

Đọc lại `vip_manager.dart`, `signed_vip_key.dart`, `_first_install_guard.dart`, `_redeemed_key_ledger.dart`, `_vip_entries_store.dart` — kiến trúc giữ nguyên: Ed25519 offline verify, one-time-use check-then-claim đồng bộ (không TOCTOU), trial 24h qua `FirstInstallGuard` fail-open có chủ đích, `maxVipStackDuration` được host set đúng 90 ngày ở `splash_screen.dart`. Không tìm ra hướng khai thác mới. Giữ nguyên kết luận "đủ an toàn cho production không-backend" từ các vòng trước.

### (C) Consent/policy + native config — 1 finding High tái xác nhận còn tồn tại

- **[High — xác nhận còn tồn tại, chưa fix] `dependency_overrides` ở root `pubspec.yaml:105-106` pin `applovin_max: 4.6.0` và `google_mobile_ads: 6.0.0` — cả 2 đều **thấp hơn floor mà chính `packages/ad_sdk/pubspec.yaml:16-17` khai báo** (`applovin_max: ^4.6.4`, `google_mobile_ads: ^7.0.0`).**
  Verify tay bằng `grep` trực tiếp 2 file `pubspec.yaml` (2026-07-19): vẫn đúng như comment tại chỗ tự ghi nhận ("2.6.1 khớp applovin_max ^4.6.4/google_mobile_ads ^7.0.0 SDK tự khai... xung đột meta"). Vì `dependency_overrides` **thắng mọi constraint khác** trong `pubspec.yaml`, host app hiện tại build/run thực tế với native SDK **cũ hơn** những gì `ad_sdk` đã test/khai báo hỗ trợ — nghĩa là mọi kết luận "TCF v2.3 readiness dựa vào giữ bản mới" ở các vòng audit trước (vòng 2, mục B) **có thể không đúng trên build thật của host app** cho tới khi override được gỡ.
  **Kịch bản lỗi cụ thể:** `google_mobile_ads 6.0.0` cũ hơn 7.0.0 có thể chưa mang đủ bản UMP SDK native ghi đúng key TCF v2.3 (`IABTCF_TCString`) mới nhất, hoặc thiếu fix policy compliance đã vá ở 7.x; `applovin_max 4.6.0` cũ hơn 4.6.4 có thể thiếu 1 fix cụ thể mà version floor 4.6.4 được chọn để có. Comment tại chỗ tự thừa nhận đây là workaround tạm cho 1 xung đột `meta` version, không phải quyết định chủ đích giữ bản cũ vì lý do ổn định.
  **Đề xuất:** gỡ override ngay khi xung đột `meta`/`gma_mediation_applovin` được giải quyết (theo dõi ở `doc/feature.md` mục Deferred đã ghi) — đây là điều kiện nên đóng trước khi tin cậy đầy đủ vào các kết luận TCF/consent-policy của những vòng trước.

Không có finding mới khác ở lens này — COPPA gate, ATT/UMP timeout, consent buffer, `doNotSell`/RDP propagation đều re-confirm đúng như các vòng trước.

### (D) Test coverage thực tế vs claim — lần đầu audit riêng lens này, 2 finding Medium

Chạy trực tiếp `cd packages/ad_sdk && flutter test` → **629/629 pass, 0 fail, không skip, không timeout.** Cao hơn con số 624 ghi ở vòng 4 (thêm test mới trong lúc đó). Đối chiếu 63 file test với 11 tính năng chính trong 7 tiêu chí gốc: coverage rất sâu và rộng (chi tiết matrix xem báo cáo agent gốc) — không tính năng nào thiếu test hoàn toàn.

- **[Medium] CI (`​.github/workflows/test.yml`) chỉ chạy `flutter test` (Dart VM), không chạy 15 file `example/integration_test/*.dart`** (banner/interstitial/rewarded/app_open/vip_redeem/consent_dialog chạy thật trên simulator/device) — lớp test gần nhất với hành vi native thật chỉ chạy thủ công theo memory log, không gate PR nào.
- **[Medium] VIP trial 1-ngày chỉ có unit test cho `FirstInstallGuard` đơn lẻ — không có test end-to-end xác nhận `AdManager().initialize()` với config mặc định thực sự tự cấp VIP 24h qua `firstInstallVipGrace`.** Guard đúng, nhưng wiring giữa `AdManager` và guard chưa được 1 test nào assert trực tiếp (`ad_manager_core_test.dart` chỉ test message cảnh báo config, không test hành vi cấp VIP thật).
- **[Low]** `ump_consent_test.dart` chỉ 2 `test()` — mỏng hơn hẳn `att_consent_test.dart` (9 test) dù độ phức tạp tương đương.
- **[Low]** Example app không có nút re-trigger UMP/ATT thủ công ngoài lần chạy splash đầu — khó QA lại nếu không reset simulator.

### Verdict cập nhật — 2026-07-19 (vòng 5)

**Vẫn là CÓ — sẵn sàng production, nhưng có 1 điều kiện High cần đóng sớm và 2 Medium nên vá trước khi mở rộng traffic.**

So với vòng 4 (0 gap mở), vòng này — nhờ audit sâu hơn ở đúng 2 góc chưa từng có lens riêng trước đó (double-enable arbitrator, test-coverage-vs-CI) — phát hiện lại 4 điều kiện cần đóng:

1. **(High, ưu tiên cao nhất)** Gỡ `dependency_overrides` pin `applovin_max: 4.6.0`/`google_mobile_ads: 6.0.0` xuống dưới floor của chính `ad_sdk` — đây là finding duy nhất ảnh hưởng trực tiếp tới độ tin cậy của mọi kết luận consent/TCF đã đưa ra ở 4 vòng trước, vì override thắng constraint.
2. **(Medium)** `enableArbitrator()`/`enableFillRateMonitor()` tự dispose instance cũ trước khi gán mới — vá nốt phần "gọi enable 2 lần" mà fix `destroy()` ở vòng 3 chưa cover.
3. **(Medium)** Bọc try/catch cho callback của `NativeAdListener` trong `native_ad_widget.dart` — đóng nốt góc dispose-race duy nhất còn lại trong 3 widget ad-view.
4. **(Medium x2, vận hành/quy trình chứ không phải code)** Thêm CI job chạy `integration_test` trên simulator (ít nhất smoke subset mỗi PR); thêm 1 test end-to-end cho VIP trial 1-ngày xác nhận `AdManager().initialize()` thực sự tự cấp VIP đúng, không chỉ test guard đơn lẻ.

Không có Critical nào ở vòng này. Không có finding nào lặp lại đã fix ở vòng 1-4 bị regression (F1/F2/AppOpenTrigger/destroy-dispose đều re-confirm đúng lần thứ 4-5 độc lập). Điều kiện pháp lý treo từ vòng 4 (UMP consent form chưa publish trên AdMob console cho EEA) **chưa được verify lại trong vòng này** — cần user xác nhận trạng thái hiện tại trước khi coi là đã đóng.

### Fix áp dụng — 2026-07-19 (cùng ngày, theo yêu cầu user "fix luôn 3 finding code")

User duyệt fix 3/4 điều kiện ở trên (loại trừ 2 mục #4 — thuộc quy trình CI/test, không phải code fix). Kết quả:

- ✅ **#2 đã fix** — `ad_manager.dart`: `enableArbitrator()` và `enableFillRateMonitor()` giờ gọi `_arbitrator?.dispose();`/`_fillRateMonitor?.dispose();` trước khi gán instance mới, cùng pattern với `destroy()` (vòng 3) và `disableArbitrator()`/`disableFillRateMonitor()` sẵn có. Đóng hoàn toàn leak "gọi enable 2 lần liên tiếp không qua destroy()".
- ✅ **#3 đã fix** — `native_ad_widget.dart:252-286`: cả 3 callback của `NativeAdListener` (`onAdLoadedCallback`, `onAdLoadFailedCallback`, `onAdClickedCallback`) giờ bọc try/catch, log qua `SafeLogger.e` với message "disposed mid-flight?" khi bắt lỗi — cùng convention đã dùng ở `ad_loading_dialog.dart`/`top_toast.dart`. Native ad load callback trễ sau `AdManager().destroy()` giờ không còn ném `FlutterError` ra ngoài platform-view callback nữa.
- ⛔ **#1 KHÔNG fix được — xác nhận bằng thực nghiệm là bị chặn cứng ở tầng Flutter SDK, không phải do lười/quên.** Đã thử bump `applovin_max: 4.6.4`/`google_mobile_ads: 7.0.0`/`gma_mediation_applovin: 2.6.1` (đúng target mà comment tại chỗ đề xuất) rồi chạy `flutter pub get` thật — **thất bại đúng như comment dự đoán**: `gma_mediation_applovin >=2.6.0` đòi `meta ^1.17.0`, nhưng Flutter SDK 3.35.1 (bản CI đang pin) bundle `flutter_test` ép `meta 1.16.0` — xung đột ở tầng Dart resolver, chưa tới lượt CocoaPods/Gradle. Đã revert lại `pubspec.yaml` về nguyên trạng (`applovin_max: 4.6.0`/`google_mobile_ads: 6.0.0`/`gma_mediation_applovin: 2.5.1`) và `flutter pub get` lại thành công. Không có hướng nào sửa được ở tầng app ngay bây giờ — cần 1 trong 2: Flutter SDK nâng lên bản có `meta ^1.17.0`, hoặc `gma_mediation_applovin` hạ constraint `meta`. Giữ nguyên plan "thử lại ~2026-10-13" đã ghi sẵn trong comment của `pubspec.yaml`. **Finding #1 (High) vẫn mở** — không phải do chưa làm, mà do thực sự chưa có fix khả thi.

Verify sau fix: `flutter analyze` (trong `packages/ad_sdk`) — "No issues found!". `flutter test` (trong `packages/ad_sdk`) — **629/629 pass**, không regression.

**Trạng thái còn lại sau vòng fix này:** 1 High (dependency_overrides, chặn ở tầng SDK, chờ ~2026-10-13) + 2 Medium quy trình (CI integration_test, VIP-trial e2e test) — cả 3 đều không phải lỗi code có thể sửa trong session này. Kết luận sản xuất không đổi: **CÓ, dùng được cho production**, với điều kiện High vẫn cần theo dõi định kỳ chứ không chặn release.

### Self-review diff + chấm điểm — 2026-07-19 (sau khi fix xong 3 finding)

Tự audit lại diff bằng Read source thật (không chỉ tin lại claim của chính mình): `dispose()` của `MonetizationArbitrator`/`FillRateMonitor` an toàn khi gọi 2 lần (`StreamSubscription.cancel()` idempotent — verify tại `monetization_arbitrator.dart:172-174`, `fill_rate_monitor.dart:107-108`). `dart format --set-exit-if-changed` sạch cả 2 file. Điểm ban đầu: **8/10** — trừ 2 điểm vì (1) không có test regression cho chính leak vừa fix, (2) try/catch trong `native_ad_widget.dart` bọc phạm vi hơi rộng (gộp `AdSafetyConfig.recordAdClick()`/`eventSink` chung với phần ghi `ValueNotifier`, có thể nuốt im lặng bug không liên quan tới dispose — trade-off có sẵn trong codebase, không phải anti-pattern mới).

**Đã đóng gap #1** (2026-07-19, cùng ngày): thêm 2 test regression —
- `test/monetization_arbitrator_test.dart` — group `enableArbitrator called twice disposes the previous instance`: gọi `enableArbitrator(arb1)`, emit 1 revenue event, gọi `enableArbitrator(arb2)`, emit thêm 1 event nữa, assert `arb1.estimatedEcpmMicros` **không đổi** (chứng minh `arb1` đã bị unsubscribe, không còn nhận event).
- `test/fill_rate_monitor_test.dart` — test tương tự cho `enableFillRateMonitor`, dùng `fillRate()` làm oracle.
- **Verify test thật sự bắt được regression:** tạm thời revert dòng `_arbitrator?.dispose();` trong `ad_manager.dart`, chạy lại test → **FAIL** đúng như dự đoán (`Expected: <1000000> Actual: <5000000>` — arb1 bị leak, nhận cả event sau khi đã bị thay thế). Sau đó restore lại fix, test pass lại. Đây là bằng chứng thực nghiệm test có khả năng phát hiện regression, không phải test giả (tautological).

Sau khi thêm 2 test: `flutter test` (packages/ad_sdk) — **631/631 pass**. Gap #2 (try/catch scope rộng) vẫn còn, chấp nhận được vì khớp convention sẵn có của codebase — không sửa trong vòng này.

## Re-audit vòng 6 — 2026-07-19

Bối cảnh: sau khi vòng 5 khép lại với 1 High mở (dependency_overrides, chặn tầng SDK) + 2 Medium quy trình mở (CI không gate integration_test, thiếu VIP-trial e2e test), đã có thêm 5 commit mới (`9a4f6c4`→`066151c`) trong cùng ngày. Thay vì audit lại từ đầu, dispatch 5 agent song song, mỗi agent một lens: (1) verify chi tiết các delta commit, (2) audit lifecycle/leak/offline hoàn toàn mới (không đọc lại kết luận cũ, tự trace từ đầu), (3) re-verify 3 điểm consent/policy còn treo (dependency_overrides, host App ID thật hay test, UMP đã publish chưa), (4) audit bảo mật VIP/trial mới từ đầu, (5) kiểm tra hiện trạng test coverage + CI gating. Tất cả 5 agent đọc source thật qua Read/Grep, không suy diễn từ audit cũ.

### A. Delta commit verification (Agent 1)

- `9a4f6c4` (docs): chỉ cập nhật `doc/feature.md` — đóng T44-T46, xác nhận UMP form đã publish trên console AdMob (2026-07-19). Không đổi code.
- `ccc7c3d`: **Finding quan trọng, làm rõ nhầm lẫn xuyên suốt 3 vòng trước.** Rounds 2-4 từng ghi nhận "AdMob App ID có vẻ là test ID" như một operational risk mơ hồ, không rõ ở đâu. Vòng này xác định chính xác: `packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml` và `.../example/ios/Runner/Info.plist` (app **example**, không phải host) trước đó **vô tình chứa App ID production thật của host app** (`ca-app-pub-3004713799155145~9488250427`) — rò rỉ ID thật vào một demo app công khai trong SDK repo. Commit này swap sang App ID test chính thức của Google (`ca-app-pub-3347511713~...` Android / `ca-app-pub-1458002511~...` iOS). Đây là fix đúng hướng — example app không nên bao giờ mang ID production thật.
- `97a29fc`: bump `flutter_lints` trong `example/pubspec.yaml` lên `^6.0.0` khớp package cha — thuần dev-dependency, không ảnh hưởng runtime/production.
- `57b7486`: +6 file integration_test mới (mrec, native ad, arbitrator demo, fill-rate demo, consent-country demo, diagnostics demo) — 557 dòng, che phủ các demo page T31-T41 trước đây chưa có test. Toàn bộ vẫn nằm trong `packages/ad_sdk/example/integration_test/`, chạy tay trên simulator/device thật, **không được CI gate**.
- `066151c`: xác nhận lại + finalize App ID swap, đồng thời sửa `vip_api_playground_test.dart` dùng `_pumpUntil()` polling (thay `tester.pump()` cố định) để chịu được ghi Android Keystore chậm trên thiết bị thật — cải thiện độ ổn định test, không phải fix bug logic.
- **Không có commit nào đóng 1 High + 2 Medium còn treo từ vòng 5** — đúng như dự đoán, các commit này thuộc nhánh công việc khác (App ID hygiene + test coverage), không nhắm vào 3 gap đó.

### B. Fresh lifecycle/leak/offline re-audit (Agent 2)

Audit lại từ đầu (không kế thừa kết luận cũ) toàn bộ: `ad_manager.dart`, cả 2 adapter, `native/banner/mrec_ad_widget.dart`, `monetization_arbitrator.dart`, `fill_rate_monitor.dart`, `ad_slot.dart`, `ad_safety_config.dart`, `ad_provider_adapter.dart`, `ad_screen.dart`, `vip_manager.dart`, `backoff.dart`, `ad_loading_dialog.dart`, `event_bus.dart`, `ad_route_observer.dart`.

**Không có phát hiện mới.** Không regression trên 5 bug đã fix ở các vòng trước. Đã re-confirm độc lập các điểm sau là đúng (không chỉ tin lại claim cũ):
- `AdSafetyConfig`: state static, reset đầy đủ qua `resetForReinit()`/`resetSession()`; preset `debug` chỉ nới cap số lượng chứ không bật `dryRun` ngầm — không có gate-bypass ẩn.
- `AdScreenState.showInterstitialAd`/`showRewardedAd`: guard `_isDisposed || !mounted` cả trước và sau async gap (dialog buffer) — không use-after-dispose, kể cả khi `showAdBuffer`'s `onComplete` fire trễ sau dispose.
- `_onVipActiveChanged` re-init path (`ad_manager.dart:927-933`): listener cũ bị `removeListener` trước khi gán `VipManager` mới — không leak listener qua nhiều lần re-initialize.
- `VipManager`: `_saveQueue` serialize mọi write chống race; `_signedKidsInFlight` claim đồng bộ (không await xen giữa) chống double-redeem; `_expiryTimer` luôn set `null` trước khi re-arm, không chồng timer; `dispose()` cố ý không dispose `_activeNotifier`/`_graceNudgeDueNotifier` — có doc giải thích rõ (widget ngoài giữ reference qua re-init, gọi `removeListener` trên notifier đã dispose vẫn an toàn ở Flutter hiện tại) — là thiết kế có chủ đích, không phải leak.
- `AdLoadingDialog`: cơ chế `_generation` chống stale timer pop nhầm dialog khi `resetState()` xảy ra giữa async gap — đúng.

### C. Consent/policy/native-config re-verification (Agent 3)

- **`dependency_overrides` (High)**: vẫn mở, đã re-confirm root `pubspec.yaml:100-107` vẫn pin dưới floor mà `packages/ad_sdk/pubspec.yaml` khai báo. Không có thay đổi nào từ vòng 5 (fix đã thử và revert ở vòng 5 vẫn là trạng thái hiện tại).
- **Host App ID**: xác nhận `android/app/src/main/AndroidManifest.xml` và `ios/Runner/Info.plist` (repo root, app host thật) chứa App ID production thật (`ca-app-pub-3004713799155145~9488250427`) — **không phải test ID** như rounds 2-4 từng nghi ngờ. Kết hợp với Finding A ở trên: rounds trước đã nhầm lẫn giữa host app và example app; giờ đã tách bạch rõ — host dùng ID thật (đúng), example dùng ID test (đúng, sau fix `ccc7c3d`).
- **UMP consent form**: xác nhận đã publish trên AdMob console (user confirm 2026-07-19, ghi trong `doc/feature.md`) — đóng blocker pháp lý GDPR/EEA đã treo từ vòng 4.

### D. VIP/trial security fresh audit (Agent 4)

- Re-verify Ed25519 offline signature, one-time-use ledger (đồng bộ check-then-claim), `FirstInstallGuard` (iOS Keychain bền qua reinstall, Android fail-open có chủ đích) — tất cả đúng như các vòng trước ghi nhận, không regression.
- **Finding mới (Low, chưa khai thác được)**: `VipManager.addVip(stack: false)` (nhánh mặc định khi `stack` không truyền) **không áp dụng clamp `maxStackDuration`** như nhánh `stack: true` có làm (~dòng 342-348 so với ~369-393). Hiện tại **không exploitable** vì call site duy nhất (`vip_redeem_screen.dart:263`) luôn dùng `stack: true` mặc định — nhưng nếu tương lai có thêm call site dùng `stack: false` với `duration` do người dùng kiểm soát, thiếu clamp này có thể cho phép VIP window vượt quá 90 ngày dự kiến. Khuyến nghị: áp cùng clamp cho cả 2 nhánh cho nhất quán, nhưng không chặn production vì chưa có đường khai thác thật.

### E. Test coverage & CI gating current state (Agent 5)

- **Gap CI không chạy integration_test: vẫn mở.** `.github/workflows/test.yml` vẫn chỉ 2 job (`sdk`, `host`), cả hai chỉ `flutter analyze` + `flutter test` (Dart VM, không simulator). Không job nào chạy `integration_test/`. 6 file mới từ `57b7486` nâng tổng số integration_test từ 15 → 21 nhưng đều cần chạy tay trên simulator/device thật — CI vẫn không gate nhóm này.
- **Gap VIP-trial e2e: vẫn mở.** Grep `firstInstallVipGrace|FirstInstallGuard` trong `packages/ad_sdk/test/` chỉ ra 3 file, không file nào gọi `AdManager().initialize()` với config mặc định rồi assert `vip.isActive` — vẫn thiếu 1 test thật kiểm chứng trial-mode 1-ngày tự động kích hoạt đúng qua toàn bộ init flow.
- `flutter test` (packages/ad_sdk): **631/631 pass** — không đổi so với vòng 5. `flutter analyze` sạch ở cả root và `packages/ad_sdk`.

### Bảng verdict cập nhật — vòng 6

| Tiêu chí | Trạng thái |
|---|---|
| Provider AdMob/AppLovin, Android + iOS | ✅ Đạt |
| Hoạt động có mạng / không mạng | ✅ Đạt |
| Chuẩn ad type, đúng vòng đời, không leak | ✅ Đạt (fresh re-audit vòng 6: 0 finding mới) |
| Trial mode 1 ngày | ✅ Đạt (logic đúng; thiếu 1 e2e test — Medium quy trình) |
| VIP by-code, bảo mật không backend | ✅ Đạt (1 Low mới, chưa khai thác được) |
| Consent mọi quốc gia (AdMob + AppLovin) | ✅ Đạt (UMP form đã publish — blocker pháp lý đã đóng) |
| Tuân thủ policy AdMob/AppLovin | ✅ Đạt, với 1 High kỹ thuật (dependency_overrides) chờ Flutter SDK upgrade |

**Tồn đọng sau vòng 6:** 1 High (dependency_overrides — chặn ở tầng Flutter SDK/`meta` constraint, không phải lỗi code, đã thử fix và revert có bằng chứng, kế hoạch re-check ~2026-10-13) + 2 Medium quy trình (CI thiếu integration_test gating; thiếu VIP-trial e2e test) + 1 Low mới (VIP `addVip(stack:false)` thiếu clamp, chưa exploitable). Không phát hiện regression nào trên 9 bug đã fix qua 5 vòng trước. Đã làm rõ và đóng 1 nhầm lẫn tồn tại 3 vòng (App ID host vs. example).

### Kết luận cuối — có nên dùng SDK này cho production không?

**CÓ.** Qua 6 vòng audit (nhiều agent độc lập, đọc source trực tiếp, cross-verify lẫn nhau, không tin claim một chiều), SDK đạt cả 7 tiêu chí đề ra. Không còn blocker pháp lý (UMP đã publish) hay blocker bảo mật (VIP Ed25519 + one-time-use ledger vững, App ID thật/test đã tách bạch đúng chỗ). Phần còn treo là:
- 1 High mang tính kỹ thuật/tooling (dependency_overrides) — không phải rủi ro runtime, chỉ là version pin tạm thời chờ Flutter SDK bắt kịp; **không chặn release**, chỉ cần lịch re-check định kỳ.
- 2 Medium là process/CI gap (thiếu integration_test trong CI, thiếu 1 e2e test cho trial) — nên làm nhưng không phải lỗi runtime ảnh hưởng người dùng.
- 1 Low lý thuyết (VIP stack:false clamp) — nên sửa cho gọn nhưng không có đường khai thác hiện tại.

Khuyến nghị: **release production được ngay**, song song mở task theo dõi 3 việc còn lại (CI gating, VIP-trial e2e test, dependency_overrides re-check ~2026-10-13) trong `doc/feature.md`.

## Vòng 7 — Real-device runtime investigation, 2026-07-19 (sau khi user phản bác "partner vẫn chửi SDK")

Sau khi chốt verdict "CÓ" ở vòng 6, user hỏi thẳng: *"bạn chắc không? audit kỹ chưa, vì partner vẫn chửi sdk chúng ta"*. Điểm mấu chốt: **6 vòng trước đều chỉ audit source code + unit/integration test — chưa từng chạy app thật trên device thật và quan sát hành vi ads runtime.** User xác nhận không có log/screenshot cụ thể từ partner, chỉ nghe than chung chung → tự điều tra bằng live-device test lần đầu tiên.

### Phương pháp
Chạy host app thật (không phải `packages/ad_sdk/example/`) trên Pixel 7 Pro thật (`2B051FDH3006MU`, `flutter run --profile`), quan sát logcat + screenshot qua splash → main screen, sau đó tương tác trực tiếp (tap) để loại trừ giả thuyết treo app.

### Phát hiện

1. **App KHÔNG bị treo/crash.** Ban đầu nghi ngờ vì toàn bộ log Dart (kể cả log của framework Flutter, không riêng `SafeLogger`) im bặt hoàn toàn sau dòng `"App Open not available -> navigate"`. Đã loại trừ giả thuyết deadlock bằng cách tap trực tiếp vào chip "15s" trên UI — chip đổi màu xanh ngay lập tức, xác nhận Dart isolate + GetX rebuild vẫn hoạt động bình thường, chỉ đơn giản là không có log statement nào ở các đường code đó khi VIP đang active. Không có `FATAL EXCEPTION`, `ANR`, hay crash nào trong toàn bộ session.

2. **Nguyên nhân banner/app-open không hiện trên máy test: VIP đang active, đúng thiết kế — không phải bug.** Mở VipScreen xác nhận: *"VIP đang kích hoạt — Hiệu lực đến 20/07/2026 16:40 — Còn 23h49m"*, đúng khớp 24h kể từ thời điểm `AdManager().initialize()` chạy trong log. Đây chính là cơ chế **`FirstInstallVipGrace`** (`packages/ad_sdk/lib/src/config/ad_config.dart:14-59`, kích hoạt tại `ad_manager.dart:959-1004`) — mặc định `auto` = 24h ở release/profile, 30s ở debug. Đã biết và audit từ vòng 1 (`audit_claude.md` dòng 18), user đã tự chốt giữ default này (`doc/feature.md:349`).

3. **⚠️ Manh mối khả dĩ nhất giải thích khiếu nại của partner: trên Android, cơ chế chống-tái-cấp KHÔNG hoạt động (fail-open có chủ đích).** `packages/ad_sdk/lib/src/vip/_first_install_guard.dart`: iOS dùng Keychain flag sống sót qua gỡ cài đặt để chặn tái cấp; Android thì `hasAlreadyGranted()` **luôn trả về `false`** (dòng 113-119) — lý do ghi rõ trong code: "không có tín hiệu local nào tin cậy sống sót qua gỡ cài đặt mà không thêm plugin". Hệ quả thực tế: **mỗi lần gỡ cài đặt (hoặc `pm clear`) app trên Android rồi cài/mở lại → được cấp lại đúng 24h hoàn toàn không quảng cáo, không giới hạn số lần.** Nếu partner có thói quen QA kiểu "gỡ cài đặt cài lại để test cho sạch" (rất phổ biến), họ gần như **chắc chắn** sẽ luôn thấy "không có ads" mỗi lần mở app — đúng với khiếu nại "ads không hiện/hiện quá ít". Ngoài ra không có thông báo nào ở thời điểm *cấp* grace (chỉ có snackbar nudge lúc *sắp hết hạn*, `graceNudgeThreshold` mặc định = 24h nên bắn gần như ngay sau khi cấp) — từ góc nhìn người dùng/tester, trải nghiệm là "ads chưa từng xuất hiện", không có gợi ý nào rằng đó là do đang trong giai đoạn dùng thử.

4. Các giả thuyết khác đã kiểm tra và loại trừ: `AppLovin Mediation Debugger` báo `ADMOB_NETWORK: INCOMPLETE INTEGRATION/UNAVAILABLE` — đúng như thiết kế vì AdMob không được khai báo làm mediation network trong AppLovin (host chỉ dùng AppLovin làm provider chạy, AdMob chỉ tồn tại ở tầng config chờ swap), không phải lỗi. `applicationId "com.roy.admobwrapper"` trong `android/app/build.gradle` không phải mismatch — đã xác nhận qua git history + `doc/task/README.md` là identity thật, dùng xuyên suốt nhiều vòng smoke-test trước đó.

### Việc chưa làm (do không muốn phá dữ liệu test cũ trên device mà không hỏi trước user)
Chưa gỡ cài đặt lại app để tận mắt xem banner/interstitial thật load thành công sau khi hết VIP grace (vì máy Pixel 7 Pro đang có VIP+history test-state tích lũy từ các vòng smoke-test trước, việc `adb uninstall` sẽ xoá sạch). Tuy nhiên có bằng chứng gián tiếp mạnh: `doc/task/README.md` dòng 36 đã ghi nhận **trên chính máy này**, ở vòng smoke-test 2026-07-07, luồng rewarded-ad (`bypassVipGuard: true`, chạy được ngay cả khi VIP active) **đã tải + hiện quảng cáo thật thành công** — nên hạ tầng serve-ads của host app không có lý do để nghi ngờ có lỗi ẩn khác ngoài việc bị VIP-suppress.

### Kết luận vòng 7
Verdict "CÓ, production-ready" từ vòng 6 **vẫn đúng về mặt code correctness** — không tìm thêm bug runtime mới. Nhưng câu trả lời trung thực cho "bạn chắc không?" là: **rất có khả năng nguyên nhân thực sự đằng sau khiếu nại của partner không phải một bug trong SDK, mà là hệ quả thực tế của tính năng `FirstInstallVipGrace` 24h kết hợp với Android fail-open khi gỡ cài đặt lại — một hành vi đã biết, đã chủ đích giữ, nhưng chưa từng được nối với khiếu nại thực tế của partner cho đến vòng audit này.** Đề xuất hành động (chưa làm, chờ quyết định user):
- Hỏi thẳng partner 1 câu: "khi test có hay gỡ cài đặt app trước không?" — xác nhận/loại trừ giả thuyết ngay lập tức, không tốn công sức.
- Thêm thông báo rõ ràng ngay lúc *cấp* grace (không chỉ lúc sắp hết hạn) để tester không nhầm là lỗi.
- Cân nhắc thêm cơ chế chống fail-open trên Android (đánh đổi với rủi ro lạm dụng bởi end-user thật) nếu xác nhận đây đúng là nguyên nhân.
- Đóng T48 (thiếu e2e test cho luồng cấp grace) để tránh regression về sau.
