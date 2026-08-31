# Đề xuất roadmap — applovin_admob_sdk (2026-08-31)

Tài liệu này tổng hợp kết quả đọc toàn bộ `packages/ad_sdk/lib/` (25.9k dòng qua 6 module: core, adapters, vip, monetization, compliance, consent, config, widget), `example/`, baseline `doc/audit/audit_round26_consolidated.md`, và toàn bộ `doc/task/done/T01-T100.md` (SDK đã qua 26 vòng audit độc lập, 100 ticket đã đóng, version hiện tại 2.4.1). Baseline round-26 đã tự đóng 3/6 finding của chính nó (reward-race khi destroy, consent-dialog timer leak *trong `destroy()`*, splash crash) và để mở 3 finding khác (VIP ledger race, AdMob `onFailed` thiếu guard, khoảng hở consent AdMob/AppLovin) — **không finding nào dưới đây lặp lại 6 finding đó**; BUG-1 là một *sibling regression* của fix round-26 #4 (cùng field, khác nhánh code chưa được vá).

SDK này đã có một lượng flagship-feature bất thường nhiều cho một package pub.dev: VIP Ed25519 offline + revocation list (T95), compliance report ký số (T96), fill-rate regression detector 7 ngày on-device (T97), integration doctor (T98), monetization arbitrator + VIP upsell (T99), A/B provider splitter (T90/T93), per-placement cap (T92), remote safety-param override (T88). Phần IDEA/FLAGSHIP dưới đây được thiết kế **không trùng** với danh sách này.

---

## 1. BUG — lỗi thật, chưa có trong baseline round-26

### BUG-1 — Reinit-without-destroy() không huỷ `_consentDialogTimer`/`_consentDialogScheduled`
- **Mô tả:** Round-26 đã fix leak của 2 field này nhưng **chỉ trong `destroy()`** (`ad_manager.dart:5065-5071`, comment tự ghi "Round-26 audit (MAJOR)"). `_resetGuardState()` (`:5104-5150`) — hàm được chính comment tại `:5091-5103` mô tả là "single source of truth cho mọi guard flag, để tránh đúng kiểu bug `_footgunBlocked`/`_umpRequested` từng lọt qua nhánh reinit-without-destroy()" — **không đụng tới 2 field này**. `initialize()` gọi lại khi đã init (`:2124-2146`, nhánh "auto-disposing previous") chỉ gọi `_resetGuardState()`, không gọi đoạn dọn ở `destroy()`.
- **Cơ chế lỗi:** Host gọi `initialize()` lần 2 mà không gọi `destroy()` trước đó (pattern có thật, được chính code comment tại `:2126-2129` xác nhận là use-case được hỗ trợ) trong lúc dialog consent tự động (`autoShowConsentDialog`) đang chờ trong cửa sổ `consentDialogPostSplashDelay` → closure cũ (đã capture `AdConfig`/`ConsentManager` CŨ) vẫn fire trên session MỚI, hoặc `_consentDialogScheduled` kẹt `true` vĩnh viễn nếu dialog đã bị bỏ qua trước đó (ví dụ `ConsentManager.reset()`), khiến consent dialog không bao giờ được hỏi lại — chính xác là loại bug round-26 vừa vá cho `destroy()`, chỉ khác đường vào.
- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:1603,1613,1630,1652,1657-1659` (khai báo/dùng), `:2124-2146` (nhánh reinit), `:5065-5073` vs `:5104-5150` (2 hàm dọn không đồng bộ).
- **Priority:** P1 · **Effort:** S — chuyển 3 dòng từ `destroy()` vào `_resetGuardState()`.
- **Vì sao đáng làm:** Đây là chính xác loại bug mà comment trong code tự cảnh báo ("R12-A audit round 6") — không vá lần này thì finding sẽ tái diễn ở field tiếp theo thêm vào `destroy()` mà quên `_resetGuardState()`.

### BUG-2 — `installAdCrashGuard()` không idempotent, phình chuỗi handler vô hạn
- **Mô tả:** `installAdCrashGuard()` (`ad_crash_guard.dart:58-85`) đọc `FlutterError.onError`/`PlatformDispatcher.instance.onError` hiện tại làm `previousOnError`/`previousOnPlatformError` rồi wrap thêm 1 lớp — không có cờ "đã cài" để bỏ qua lần gọi thứ 2. Gọi từ `ad_manager.dart:2160-2161` mỗi lần `initialize()` thành công với `config.enableCrashGuard == true`. Docstring tự nhận "Idempotent-ish" (dấu hiệu tự biết chưa chắc) nhưng code không có guard thật.
- **Cơ chế lỗi:** Mọi `destroy()` + `initialize()` lại (đổi provider, logout/login, QA re-init — pattern được document rõ trong CLAUDE.md/README) đều cộng thêm 1 closure lồng vào `FlutterError.onError`/`PlatformDispatcher.onError`. `destroy()` không hề gỡ closure này. Kết quả: mỗi lần crash SDK-attributable bị xử lý N lần (N = số lần init trong đời process), log trùng lặp N lần, và toàn bộ chuỗi closure cũ (giữ tham chiếu gián tiếp qua closure scope) không bao giờ được GC — rò rỉ bộ nhớ tăng dần theo số chu kỳ init, không phải leak 1 lần mà leak **tuyến tính theo thời gian sống app**.
- **File:** `packages/ad_sdk/lib/src/core/ad_crash_guard.dart:58-85`, gọi từ `packages/ad_sdk/lib/src/core/ad_manager.dart:2160-2161`.
- **Priority:** P1 · **Effort:** S — thêm cờ static `_installed` hoặc lưu handler gốc 1 lần duy nhất tại module-level, tương tự pattern `ConsentManager` singleton guard đã dùng.
- **Vì sao đáng làm:** Ảnh hưởng trực tiếp tới bất kỳ app nào bật `enableCrashGuard` và có provider switch / re-init trong phiên dài (ví dụ app WiFi-stress-tester từng sống trong repo này, hoặc bất kỳ host nào theo A/B cohort re-init) — đúng dạng "memory leak" mà CLAUDE.md/init.md liệt là điều cấm kỵ số 1.

### BUG-3 — `pickProviderCohort()`/`experimentBucket()` sập về 1 bucket duy nhất khi gọi đúng như README hướng dẫn
- **Mô tả:** README (mục "A/B testing AdMob vs AppLovin MAX") dạy gọi `AdManager().pickProviderCohort()` **TRƯỚC** `initialize()` (bắt buộc, vì provider phải cố định trước khi dựng `AdConfig`). Tại thời điểm đó `AdPreferences.instanceOrNull` (`ad_preferences.dart:21,34`) luôn là `null` (`getInstance()` mới chỉ được gọi bên trong `initialize()`), và `_currentDeviceGAID` (`ad_manager.dart:879`) cũng chưa được fetch (`''`). `experimentBucket()` (`:371-378`) code: `installId = (gaid không rỗng) ? gaid : (AdPreferences.instanceOrNull?.getOrCreateExperimentInstallId() ?? gaid)` — khi cả `instanceOrNull` lẫn `gaid` đều rỗng/null, `installId` sập về chuỗi rỗng `''` cho **MỌI thiết bị**.
- **Cơ chế lỗi:** `experimentBucket('', key, buckets)` hash FNV-1a của `('' + key)` — hằng số cho mọi lần gọi, mọi thiết bị → `pickProviderCohort()` trả về CÙNG 1 giá trị cho 100% install base khi gọi đúng thứ tự tài liệu hướng dẫn. Toàn bộ tính năng A/B provider-split (T90/T93) không hoạt động, 100% traffic dồn về 1 provider, và không có warning/log/test nào bắt được vì **mọi test hiện có đều gọi `await AdPreferences.getInstance()` trong `setUp()` trước khi test `experimentBucket`** — tức bộ test tự phá vỡ đúng điều kiện lỗi bằng cách vô tình khởi tạo trước, không test đúng thứ tự README dạy.
- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:371-378,399-402`; `packages/ad_sdk/lib/src/utils/ad_preferences.dart:21,34,347`.
- **Priority:** P0 · **Effort:** M — cần 1 trong 2 hướng: (a) làm `experimentBucket()`/`pickProviderCohort()` async và tự đảm bảo `AdPreferences.getInstance()` trước khi đọc, hoặc (b) `AdManager` tự lazy-bootstrap `AdPreferences` ngay từ constructor thay vì trong `initialize()`. Cả hai đổi contract hiện có (sync → async, hoặc side-effect ở constructor) nên cần thiết kế cẩn thận, không phải 1 dòng.
- **Vì sao đáng làm:** Đây không phải race hẹp — nó silently vô hiệu hoá HOÀN TOÀN một tính năng đã document, đúng call pattern chính README dạy, không có tín hiệu lỗi nào cho host biết. Giá trị monetization/thử nghiệm bị mất mà không ai nhận ra trừ khi đào sâu vào code.

### BUG-4 — `AppLovinAdapter._disposedNativeKeys` phình vô hạn với native ad trong danh sách cuộn
- **Mô tả:** `_disposedNativeKeys` (`applovin_adapter.dart:492,495,504,531-532,545`) là 1 `Set<Object>` "tombstone" — key được thêm vào khi 1 native-ad instance bị dispose (`:532`), và **chỉ** được gỡ qua `reviveNativeInstance(key)` (`:545`), hàm này chỉ được gọi khi đúng `State` widget đó re-init lại (mount lại chính instance cũ). Trong use-case chính của T73 (`NativeAdWidget` với size configurable, dùng trong `ListView`/feed cuộn) — 1 native ad cuộn qua khỏi màn hình và bị dispose **vĩnh viễn** (không bao giờ mount lại đúng key đó) sẽ không bao giờ được revive.
- **Cơ chế lỗi:** Mỗi native ad hiển thị-rồi-cuộn-qua trong 1 phiên dài (feed vô hạn) cộng thêm đúng 1 entry vào `_disposedNativeKeys` không bao giờ bị xoá — leak tuyến tính theo số native ad đã hiển thị trong session, giữ tham chiếu `Object key` (thường là 1 identity gắn với State object) sống suốt đời `AppLovinAdapter`. `AdMobAdapter` không bị vì dùng so sánh identity trực tiếp (`identical`) trên slot thay vì tombstone Set.
- **File:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:487-545`.
- **Priority:** P2 · **Effort:** M — thay Set không giới hạn bằng cơ chế tự dọn theo TTL, hoặc bỏ luôn model tombstone-Set để đổi sang so sánh identity giống AdMob adapter (root-cause fix, nhất quán 2 adapter).
- **Vì sao đáng làm:** Ảnh hưởng thật với đúng use-case T73 được thiết kế ra để phục vụ (feed native ad cuộn) — nhẹ trên session ngắn nhưng tích luỹ trong app dùng feed dài (mạng xã hội, tin tức).

### BUG-5 — Thiếu identity-guard đối xứng trên `onAdOpened`/`onAdClicked` (cả 2 adapter) + `eventSink` không null hoá ở AppLovin `dispose()`
- **Mô tả:** Round-26 finding #2 (còn mở) chỉ nêu AdMob's `onFailed` thiếu `_discardIfDisposed` đối xứng với `onLoaded` (fix M4 trước đó). Đọc lại `admob_adapter.dart`, callback `onAdOpened`/`onAdClicked` cho banner/mrec/native (quanh dòng ~1966, 2122, 2246) **cũng thiếu** guard `identical(_xSlotsByKey[key], slot)` mà `onAdLoaded`/`onAdFailedToLoad` đã có. Thêm nữa, `eventSink` (`applovin_adapter.dart:159,164`) không được set `null` trong `dispose()` (`:765-` trở đi) — round-26 #2 chỉ note phía AdMob, AppLovin có cùng lỗ hổng.
- **Cơ chế lỗi:** Click/open event tới TRỄ (sau khi widget/instance đã dispose, ví dụ user scroll rất nhanh qua native ad ngay lúc click event đang bay từ native layer) vẫn được ghi nhận vào CTR-fraud counter (`AdSafetyConfig`) và emit `AdClickEvent` cho 1 placement đã không còn tồn tại — gây nhiễu số liệu CTR dùng để phát hiện gian lận (chính là tầng anti-fraud SDK tự hào bảo vệ tài khoản host).
- **File:** `packages/ad_sdk/lib/src/adapters/admob_adapter.dart` (quanh `onAdOpened`/`onAdClicked` của banner/mrec/native), `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:159,164`.
- **Priority:** P2 · **Effort:** M — nhân bản đúng guard `identical(...)` đã áp dụng cho `onAdLoaded` sang 2 callback còn lại; null hoá `eventSink` trong cả 2 `dispose()`. Nên fix chung 1 chỗ vì cùng root cause với round-26 #2, không tách 2 PR riêng.
- **Vì sao đáng làm:** Trực tiếp làm sai số liệu nuôi bộ máy anti-fraud — vòng lặp ngược: dữ liệu CTR nhiễu có thể khiến safety layer tự đưa ra quyết định sai (suspend nhầm hoặc bỏ sót gian lận thật).

### BUG-6 — `_selfCheckLoad` leak subscription nếu `load()` throw đồng bộ
- **Mô tả:** Trong `integration_self_check.dart`/`ad_manager.dart` (quanh `:660-680`), nếu adapter's `load()` throw đồng bộ TRƯỚC khi tới dòng `sub.cancel()`, subscription bị bỏ ngỏ.
- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (khu vực `_selfCheckLoad`, ~660-680), `packages/ad_sdk/lib/src/core/integration_self_check.dart`.
- **Priority:** P3 · **Effort:** S — bọc trong `try/finally`.
- **Vì sao đáng làm:** Chỉ chạy trong debug/doctor path (T98), không ảnh hưởng production runtime, nhưng doctor tự nó phải sạch tuyệt đối vì nó là công cụ chẩn đoán leak cho host khác.

### BUG-7 — `showAppOpenAdOnResume()` thiếu `identical(_adapter, ad)` guard đối xứng
- **Mô tả:** `_resumeAdWorkAfterConsent` có guard `identical(_adapter, ad)` để tránh dùng adapter cũ sau reinit-without-destroy(); pre-check buffer của `showAppOpenAdOnResume()` không có guard tương tự.
- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (hàm `showAppOpenAdOnResume`).
- **Priority:** P3 · **Effort:** S.
- **Vì sao đáng làm:** Cửa sổ hẹp (~500ms) đúng lúc reinit-without-destroy() rơi vào giữa lúc app resume — độ ưu tiên thấp nhưng rẻ để vá cùng đợt với BUG-1 (cùng họ "reinit-without-destroy thiếu guard").

---

## 2. ENHANCEMENT — cải thiện tính năng đã có

### ENH-1 — MREC widget thiếu animated auto-collapse (parity với T91)
- **Mô tả:** T91 thêm `AnimatedSize`/`collapseAnimationDuration` cho `banner_ad_widget.dart` (dòng 29,36,263-278) để tránh giật layout khi no-fill/cooldown. `mrec_ad_widget.dart` vẫn dùng `SizedBox.shrink()` đột ngột ở **6 điểm** riêng biệt (dòng 254,258,260,289,305,322) — không có animated-collapse tương đương dù cùng lý do UX (CLS) áp dụng y hệt.
- **File:** `packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart`.
- **Priority:** P2 · **Effort:** M (không thể copy-paste 1:1 vì MREC không có subtree duy nhất như banner — cần audit lại điểm return sớm).
- **Giá trị:** Đóng khoảng cách parity giữa 2 widget cùng họ, tránh câu hỏi hỗ trợ "sao banner mượt mà MREC giật".

### ENH-2 — `RemoteAdSafetyProvider` không có đường re-fetch định kỳ, chỉ đọc 1 lần lúc `initialize()`
- **Mô tả:** `fetchSafetyParamOverrides()` chỉ được gọi 1 lần bên trong `initialize()` (`ad_manager.dart:2156-2168`). Muốn áp giá trị remote mới, host phải `destroy()` + `initialize()` lại toàn bộ SDK — nặng hơn nhiều so với thiết kế tương tự của `VipRevocationProvider` (T95), vốn có API `refreshRevocationList()` gọi được bất cứ lúc nào không cần re-init.
- **File:** `packages/ad_sdk/lib/src/config/remote_ad_safety_provider.dart`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2156-2168`.
- **Priority:** P2 · **Effort:** M — thêm `AdManager().refreshRemoteSafetyParams()` public, mirror đúng pattern `refreshRevocationList` đã có (fail-open, giữ giá trị cũ nếu lỗi).
- **Giá trị:** Cho phép publisher đổi tần suất/cap thật sự "remote" theo đúng tinh thần T88 đặt ra (đổi mà không cần build mới) — hiện tại vẫn cần khởi động lại SDK, gần như mất hết lợi ích "remote".

### ENH-3 — Nối `FillRateBaselineMonitor` (T97) làm tín hiệu veto cho `MonetizationArbitrator` (T99)
- **Mô tả:** 2 tính năng đã có nhưng chưa "nói chuyện" với nhau: `FillRateBaselineMonitor` phát hiện fill-rate/eCPM tụt so baseline 7 ngày; `MonetizationArbitrator.decide()` chỉ so ngưỡng eCPM tuyệt đối tĩnh, không biết phiên này có đang trong giai đoạn regression hay không.
- **File:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`, `packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart`.
- **Priority:** P2 · **Effort:** M — thêm tham số optional `FillRateBaselineMonitor?` vào constructor arbitrator, dùng active alert làm tín hiệu veto bổ sung (opt-in, không đổi hành vi mặc định).
- **Giá trị:** Tăng độ chính xác quyết định "có nên nudge VIP không" — hiện tại arbitrator "mù" trước tín hiệu regression đã có sẵn trong chính SDK.

### ENH-4 — `DebugAdOverlay` chưa hiển thị trạng thái VIP revocation-list / remote-safety-override
- **Mô tả:** `debug_ad_overlay.dart` đã hiển thị slot state, safety status, fill-rate regression alert (T97) — nhưng không có dòng nào cho biết CRL (T95) lần refresh gần nhất là khi nào/thành công hay fail-open, hay `AdSafetyParams` hiện tại có đang bị remote override (T88) hay không.
- **File:** `packages/ad_sdk/lib/src/widget/debug_ad_overlay.dart`.
- **Priority:** P3 · **Effort:** S — dữ liệu đã tồn tại sẵn trong `VipManager`/`AdSafetyConfig`, chỉ cần thêm 2 dòng Text.
- **Giá trị:** Giảm thời gian debug "tại sao remote config của tôi không áp dụng" — hiện phải grep log thay vì nhìn overlay.

### ENH-5 — Adaptive Frequency Phase 2 (T26 đã chủ động để ngỏ)
- **Mô tả:** `adaptive_frequency.dart` tự ghi rõ "Phase 2 (dùng signal để hạ soft cap dưới hard ceiling) intentionally unscoped chờ dữ liệu thật". Sau 26 vòng audit và ~500-entry rolling buffer đã tích luỹ, đủ cơ sở để làm 1 bản Phase 2 tối giản: nếu tỉ lệ `ad_to_background`/`background_to_resume` vượt ngưỡng cấu hình được trong 1 cửa sổ thời gian, tự hạ `maxFullscreenAdsPerSession` xuống 1 bậc (không bao giờ vượt hard ceiling của `AdSafetyParams`, chỉ nới lỏng KHÔNG BAO GIỜ tự nới rộng).
- **File:** `packages/ad_sdk/lib/src/adaptive/adaptive_frequency.dart`, `packages/ad_sdk/lib/src/core/ad_safety_config.dart`.
- **Priority:** P3 · **Effort:** L — cần thiết kế cẩn thận để tránh feedback loop (soft cap thấp → ít data → khó phục hồi).
- **Giá trị:** Tận dụng dữ liệu đã thu thập 1 thời gian dài mà chưa dùng vào việc gì — đúng tinh thần "không để instrumentation chết".

### ENH-6 — `AdPlacement` không dùng được trong `const` map (giới hạn ngôn ngữ Dart, T92 tự ghi nhận)
- **Mô tả:** T92 tự phát hiện `AdPlacement` override `==`/`hashCode` nên `const AdSafetyParams(maxPerPlacementAdsPerDay: {...})` KHÔNG compile được — đã document trong dartdoc/README nhưng chưa có API né tránh, host vẫn phải tự nhớ dùng non-const.
- **File:** `packages/ad_sdk/lib/src/state/ad_placement.dart`, `packages/ad_sdk/lib/src/core/ad_safety_config.dart`.
- **Priority:** P3 · **Effort:** S — thêm factory `AdPlacement.id(String)` dùng `String` làm key thay vì instance `AdPlacement` trong riêng field `maxPerPlacementAdsPerDay` (giữ nguyên API cũ, chỉ thêm overload nhận `Map<String, int>`).
- **Giá trị:** Loại bỏ 1 lớp lỗi compile khó hiểu cho host mới, đã từng khiến chính team tự vấp trong lúc code T92.

---

## 3. TECH DEBT — dọn dẹp, không đổi hành vi observable

### DEBT-1 — `MonetizationArbitrator._samples` là dead code
- **Mô tả:** Field `_samples` tồn tại trong `monetization_arbitrator.dart` nhưng không có nơi nào đọc lại giá trị — chỉ được ghi, chưa từng consume.
- **File:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`.
- **Priority:** P3 · **Effort:** S — xoá field + code ghi vào nó, hoặc note rõ lý do giữ lại nếu dự định dùng tương lai gần.

### DEBT-2 — `FillRateBaselineMonitor` rebuild toàn bộ rolling-window map mỗi ad event
- **Mô tả:** Thay vì cập nhật incremental, mỗi `AdEvent` mới khiến toàn bộ map baseline được rebuild lại từ đầu — O(n) mỗi event thay vì O(1) amortized.
- **File:** `packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart`.
- **Priority:** P3 · **Effort:** M — cache kết quả theo cửa sổ, chỉ tính lại khi cửa sổ trượt.
- **Lý do:** Không sai về mặt kết quả (đã có test), nhưng chi phí CPU tăng tuyến tính theo số event trong phiên dài — có thể đo được trên thiết bị cấu hình thấp.

### DEBT-3 — Ghi SharedPreferences dư thừa trong `VipManager._effectiveNow`
- **Mô tả:** Đường gọi `_effectiveNow` (mỗi lần check VIP `isActive`/`remaining`) có 3+ lần ghi SharedPreferences lặp lại trong 1 lần `load()`, thay vì gộp thành 1 write.
- **File:** `packages/ad_sdk/lib/src/vip/vip_manager.dart`.
- **Priority:** P3 · **Effort:** M — gộp write, cẩn thận không đổi thứ tự crash-safe (README đã document rõ thứ tự Keychain-trước-prefs-sau là chủ ý, phải giữ nguyên invariant đó khi gộp).

### DEBT-4 — Trùng lặp lớn giữa `admob_adapter.dart` (2406 dòng) và `applovin_adapter.dart` (2373 dòng)
- **Mô tả:** Cả 2 file lặp lại gần như y hệt: vòng lặp reset slot, dispose per-key map (banner/mrec/native), pattern `_bannerSlotsByKey`/`_mrecSlotsByKey`/`_nativeSlotsByKey`. Không sai, nhưng mỗi lần audit round phải sửa cùng 1 loại bug ở CẢ 2 nơi riêng biệt (chính là lý do BUG-5 ở trên tồn tại — fix 1 bên, quên bên kia).
- **File:** `packages/ad_sdk/lib/src/adapters/admob_adapter.dart`, `applovin_adapter.dart`.
- **Priority:** P2 · **Effort:** XL — trích phần chung (dispose-per-key-map, reset-slot loop) vào mixin/helper dùng chung qua `AdProviderAdapter`, KHÔNG đổi interface public. Rủi ro cao (2 adapter đã qua 26 vòng audit riêng biệt, refactor chung dễ đưa bug regress) — chỉ nên làm khi có ngân sách 1 phiên riêng + test coverage giữ nguyên 100%.
- **Lý do đáng làm:** Giảm hẳn lớp bug "fix 1 bên quên bên kia" đã xảy ra ít nhất 2 lần (round26 #2, BUG-5 ở trên).

### DEBT-5 — `ad_manager.dart` là 1 "god file" 6999 dòng
- **Mô tả:** File duy nhất gộp init/destroy/consent-wiring/VIP-listener/connectivity-watch/safety-gating/4+ entry-point show-ad. Không có risk đúng nghĩa (đã audit kỹ 26 vòng), nhưng chi phí review mỗi thay đổi tăng dần vì phải load toàn bộ context 7000 dòng.
- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart`.
- **Priority:** P3 · **Effort:** XL — tách thành `AdManager` + các phần thuần tổ chức (`part` file hoặc mixin riêng cho connectivity-watch, consent-wiring) — 0 đổi hành vi, chỉ đổi vị trí code.
- **Lý do:** Rủi ro dài hạn thuần về bảo trì, không phải bug — nên làm khi có 1 phiên rảnh, không urgent.

### DEBT-6 — Docstring "Idempotent-ish" tự thừa nhận không chắc chắn
- **Mô tả:** `installAdCrashGuard()`'s docstring (`ad_crash_guard.dart:56`) viết "Idempotent-ish" — dấu hiệu code tự biết hành vi không rõ ràng (chính là BUG-2). Sau khi fix BUG-2, cần viết lại docstring khẳng định đúng guarantee thật.
- **File:** `packages/ad_sdk/lib/src/core/ad_crash_guard.dart:56`.
- **Priority:** P3 · **Effort:** S — làm cùng lúc với BUG-2.

---

## 4. Ý TƯỞNG MỚI (không cần backend) — không trùng T88-T99

### IDEA-1 — `FakeAdProviderAdapter`: chế độ Demo/CI-safe hoàn toàn offline
- **Mô tả:** `AdProviderAdapter` đã là 1 interface trừu tượng (`core/ad_provider_adapter.dart`) — implement thêm 1 adapter thứ 3 phát placeholder creative + event giả lập đúng shape `AdEvent` hiện có, không cần ad-unit ID thật, không gọi network. Đúng nhu cầu documented trong chính CI của repo (`.github/workflows/test.yml` phải "Forces `AD_PROVIDER_ADMOB` vì không có AppLovin key thật commit") và trong build App-Store-review/demo không được phép burn spend thật.
- **File liên quan:** `packages/ad_sdk/lib/src/core/ad_provider_adapter.dart` (interface có sẵn), file mới `lib/src/adapters/fake_adapter.dart`.
- **Priority:** P2 · **Effort:** M.
- **Giá trị:** Giải quyết đúng nỗi đau documented nhiều lần trong CHANGELOG/CLAUDE.md ("no real AppLovin key committed"), giúp demo app/screenshot pipeline/App Review build không cần credential thật — hoàn toàn offline, không backend.

### IDEA-2 — Bộ mô phỏng ma trận consent (dev tool, local-only)
- **Mô tả:** Một hàm thuần `simulateConsentOutcome(AdConsent hypothetical)` chạy qua đúng logic `applyConsentToProviders`/`ad_consent.dart` NHƯNG không gọi platform channel thật — chỉ trả về "AdMob sẽ nhận `npa=?`, AppLovin sẽ nhận `hasUserConsent=?`/COPPA=?" cho từng tổ hợp GDPR/ATT/COPPA giả định. Giúp QA compliance kiểm tra trước khi build thật lên thiết bị.
- **File liên quan:** `packages/ad_sdk/lib/src/core/ad_consent.dart`, `packages/ad_sdk/lib/src/consent/consent_manager.dart`.
- **Priority:** P2 · **Effort:** S — logic mapping đã tồn tại, chỉ cần bọc thành pure function không side-effect.
- **Giá trị:** Compliance là 1 trong 7 yêu cầu sản phẩm cốt lõi (round26 #7) — công cụ này giúp catch sai sót mapping consent TRƯỚC khi lên thiết bị thật, giảm rủi ro chính là thứ round26 finding #5 đang vật lộn.

### IDEA-3 — `AdManager().explainLastSkip(AdSlotType)` — bộ giải thích "tại sao ad không hiện"
- **Mô tả:** Ring buffer nhỏ (giữ N quyết định gate gần nhất: VIP/consent/cooldown/cap/network/dryRun) cho mỗi loại ad, expose qua 1 hàm trả về lý do bị skip gần nhất dạng human-readable — nhẹ hơn nhiều so với `compliance_report`/`ad_event_log` (vốn thiết kế cho audit trail ký số, không phải debug nhanh).
- **File liên quan:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (nơi các gate hiện tại đã quyết định pass/fail), `packages/ad_sdk/lib/src/compliance/ad_event_log.dart` (tham khảo pattern ring-buffer đã có).
- **Priority:** P1 · **Effort:** M.
- **Giá trị:** README/CHANGELOG nhắc đi nhắc lại câu hỏi hỗ trợ phổ biến nhất của SDK quảng cáo: "ad không hiện, tại sao?" — hiện phải bật verbose log + đọc tag. 1 API trực tiếp trả lời câu hỏi này là giá trị hỗ trợ rất thực tế, rẻ để build (data đã tồn tại rải rác, chỉ cần gom lại).

### IDEA-4 — Máy tính ý nghĩa thống kê cho A/B cohort (bổ sung T90/T93)
- **Mô tả:** T90's chính tài liệu tự ghi "host tự group theo `providerTag` trong analytics pipeline riêng" — nghĩa là phần thống kê so sánh 2 cohort được CHỦ Ý để ngỏ cho host. Thêm 1 hàm thuần toán học (two-proportion z-test / khoảng tin cậy đơn giản) nhận vào số liệu tổng hợp mà host đã có (fill count, revenue theo cohort) trả về "cohort A vs B: chênh lệch X%, độ tin cậy Y%" — không cần dependency thống kê ngoài, `dart:math` đủ.
- **File liên quan:** `packages/ad_sdk/lib/src/utils/experiment_bucket.dart` (nơi đặt hàm bổ sung).
- **Priority:** P3 · **Effort:** S.
- **Giá trị:** Hoàn thiện nốt phần T90 chủ ý để trống, không cần backend/dependency mới, dùng đúng data host đã tự thu thập.

### IDEA-5 — Lịch "ramp an toàn" cục bộ theo tuổi cài đặt (bổ sung local cho T88)
- **Mô tả:** T88 làm remote config qua host-supplied provider (cần network/Firebase). Bổ sung 1 lựa chọn HOÀN TOÀN LOCAL: `AdConfig.safetyRampSchedule: Map<Duration, AdSafetyParams>` keyed theo thời gian-kể-từ-first-install (đã có sẵn `AdPreferences.getFirstInstallAtMs`) — SDK tự áp `AdSafetyParams` tương ứng mốc D0/D3/D7/D30 mà không cần bất kỳ network call nào, cho app muốn ramp độ "aggressive" ads dần theo thời gian giữ chân user mà không set up remote-config server.
- **File liên quan:** `packages/ad_sdk/lib/src/config/ad_config.dart`, `packages/ad_sdk/lib/src/utils/ad_preferences.dart` (đã có `firstInstallAtMs`).
- **Priority:** P2 · **Effort:** M.
- **Giá trị:** Đúng tinh thần "no-server" xuyên suốt SDK (VIP offline, safety local) — cho app nhỏ không có backend vẫn ramp monetization theo D1/D7/D30, thứ mà app lớn mới đủ lực làm qua Firebase Remote Config (T88).

---

## 5. FLAGSHIP — tính năng độc quyền, không cần backend

### FLAGSHIP-1 — Nhật ký kiểm toán ký số cho mọi lần "bypass" safety layer
- **Vì sao độc quyền:** SDK đã có hạ tầng Ed25519 dùng cho 3 mục đích khác nhau (VIP key T18/AVP2, VIP revocation T95, compliance report T96) — nhưng chính các "cửa hậu" hợp pháp của SDK (`bypassSafety: true`, `bypassVipGuard: true`, `dryRun`) hiện chỉ là boolean trần, không ai kiểm chứng được SAU KHI build đã ship rằng chúng chỉ được gọi đúng 2 nơi SDK cho phép (splash app-open, VIP-extend rewarded) chứ không bị lạm dụng ở nơi khác để cày impression.
- **Ý tưởng:** Mỗi lần `bypassSafety`/`bypassVipGuard` được gọi, ghi 1 record (timestamp, call-site tag do host truyền vào, kết quả) vào ring buffer, cuối phiên (hoặc theo lịch) xuất ra 1 file ký Ed25519 bằng CHÍNH private key host đã dùng cho compliance report (T96) — offline hoàn toàn, verify bằng đúng tool `tool/vip_mint.dart`/CLI verify đã có.
- **File liên quan:** `packages/ad_sdk/lib/src/compliance/compliance_signing.dart` (tái dùng hạ tầng ký), `packages/ad_sdk/lib/src/core/ad_manager.dart` (nơi `bypassSafety`/`bypassVipGuard` được đọc).
- **Priority:** P1 · **Effort:** L.
- **Giá trị:** Giải quyết đúng câu hỏi "làm sao chứng minh dev/agency của tôi không âm thầm patch quanh safety layer để farm doanh thu" — 1 lớp trust-nhưng-verify cho chính safety layer, không dev ads SDK nào khác có.

### FLAGSHIP-2 — Failover chéo-provider theo từng định dạng, hoàn toàn offline (không phải A/B split cố định-cả-phiên)
- **Vì sao độc quyền:** `AdConfig.provider` hiện cố định 1 provider cho TOÀN BỘ phiên (kể cả sau T90's cohort split — vẫn là 1 provider/phiên). Chưa có cơ chế: nếu riêng ĐỊNH DẠNG rewarded của provider chính đang fill-rate tệ (theo đúng dữ liệu `FillRateMonitor`/`FillRateBaselineMonitor` T97 đã thu thập sẵn), tự động thử provider còn lại CHỈ CHO ĐỊNH DẠNG ĐÓ trong phiên hiện tại, các định dạng khác vẫn ở provider chính.
- **Ý tưởng:** Mở rộng `MonetizationArbitrator`/`FillRateMonitor` thêm chế độ opt-in "per-format failover": khi 1 slot liên tục no-fill/fill-rate dưới ngưỡng qua N lần thử liên tiếp, slot đó (và CHỈ nó) chuyển sang load từ adapter còn lại cho tới khi provider chính phục hồi — hoàn toàn client-side, dùng lại `AdProviderAdapter` interface đã trừu tượng hoá sẵn cho cả 2 provider.
- **File liên quan:** `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `fill_rate_baseline_monitor.dart`, `packages/ad_sdk/lib/src/core/ad_manager.dart` (nơi chọn adapter theo `AdSlotType`).
- **Priority:** P2 · **Effort:** XL — cần cả 2 adapter sống song song trong 1 phiên (hiện kiến trúc giả định 1 adapter/phiên), thay đổi kiến trúc không nhỏ.
- **Giá trị:** Đây là thứ 1 dev tự tích hợp thẳng `google_mobile_ads`+`applovin_max` gần như không bao giờ tự làm (phải maintain 2 SDK sống song song, quá phức tạp để tự viết) — "mediation waterfall nghèo" hoàn toàn client-side, không cần network mediation platform.

### FLAGSHIP-3 — Token chuyển VIP sang thiết bị mới, ký offline, 1 lần dùng
- **Vì sao độc quyền:** README tự công bố giới hạn: Android không có anti-reinstall bền vững, "clear app data" hoặc đổi máy làm mất VIP. Thay vì chỉ coi đây là rủi ro cần chấp nhận, biến nó thành 1 tính năng: user chủ động export 1 token ký Ed25519 (dùng CHÍNH private key app, không phải public key VIP) chứa thời gian VIP còn lại + danh sách `kid` đã dùng, TRƯỚC KHI gỡ cài đặt/đổi máy; máy mới verify token offline và áp lại đúng số ngày còn lại, 1 lần dùng (tự thêm vào `_redeemed_key_ledger` như 1 kid đã tiêu).
- **File liên quan:** `packages/ad_sdk/lib/src/vip/signed_vip_key.dart` (tái dùng scheme ký sẵn có), `packages/ad_sdk/lib/src/vip/vip_manager.dart`, `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart`.
- **Priority:** P3 · **Effort:** L.
- **Giá trị:** Biến 1 giới hạn đã document ("Android VIP anti-bypass yếu") thành trải nghiệm tốt hơn cho user hợp pháp (không mất VIP khi đổi máy chính chủ) mà KHÔNG làm yếu anti-abuse (vẫn 1 lần dùng, vẫn ký offline, vẫn cần hành động chủ động của user trước khi mất dữ liệu cũ) — khác biệt thật với cách các SDK khác chỉ đơn thuần "chấp nhận rủi ro" ở điểm yếu này.
