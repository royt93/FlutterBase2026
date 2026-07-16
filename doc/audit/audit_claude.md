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
3. **(F2, F3, F5 — chấp nhận được)** Ghi vào test-plan: phải test vòng đời banner/reload **riêng cho từng provider** (AdMob và AppLovin không share đường phục hồi), đúng như README đã cảnh báo.
4. **Tuân thủ khuyến nghị adoption của chính README:** pilot traffic nhỏ, time-boxed, theo dõi dashboard AdMob/AppLovin thật vài tuần trước khi tin cậy ở scale — vì tầng policy/fill-rate nằm ngoài tầm SDK và chưa có lịch sử production bên thứ ba.
