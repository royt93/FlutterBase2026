# Audit SDK ads 2026-08-15

Phạm vi: chỉ audit `packages/ad_sdk/` sau khi host app đã prune khỏi repo. Đã đọc `CLAUDE.md`, track T01-T56 trong `doc/task/README.md`, các audit gần nhất, toàn bộ `lib/`, `test/`, `example/`, docs package và CI. Không audit ticket P/host-app như `doc/task/todo/P55-background-packet-loss-alert.md`.

Xác minh nhanh: chạy `flutter test` trong `packages/ad_sdk/`, kết quả pass 700 tests. Không chạy integration test vì CI đã có shard riêng và một số flow fullscreen vẫn cần thao tác đóng ad thủ công.

## 1. Bug cần fix

### P1 - AppLovin Native có thể request sau khi gate đã đổi trạng thái

Vì sao quan trọng: `NativeAdWidget` set `_allowed=true` sau khi qua gate ban đầu, nhưng AppLovin native load thực tế xảy ra khi `MaxNativeAdView` được mount trong `build`. Nếu consent bị revoke, offline, cooldown/cap đổi trạng thái, hoặc SDK bị reset sau thời điểm `_allowed` bật, rebuild vẫn có thể tạo native view mới mà không re-check `canRequestAds`/`canReload`.

File/dòng liên quan: `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:48`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:70`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:102`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:158`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:249`

Effort: M

Priority: P1

### P1 - `canShowInterstitial()` và `canShowRewardedAd()` trả true khi show path sẽ bị chặn

Vì sao quan trọng: public pre-check đang thiếu các gate quan trọng như `canRequestAds`, connectivity, fullscreen mutex và một số in-flight state. UI tiêu thụ SDK có thể bật nút hoặc hiện loading dialog rồi mới fail ở `showInterstitial`/`showRewardedAd`, tạo race và UX sai trạng thái.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_screen.dart:93`, `packages/ad_sdk/lib/src/core/ad_screen.dart:188`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2342`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2632`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2282`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2497`

Effort: S

Priority: P1

### P1 - UMP channel error đang fail-open sang request ads

Vì sao quan trọng: khi auto UMP gặp `MissingPluginException` hoặc lỗi channel không bắt được trong UMP helper, code mở `_canRequestAds=true`. Với package public trên pub.dev, behavior này có thể phục vụ ads khi consent path bị hỏng trong vùng cần consent, thay vì fail-closed hoặc chuyển sang chế độ non-personalized có tín hiệu rõ ràng.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:1272`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1275`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1294`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1300`

Effort: M

Priority: P1

### P1 - `destroy()` không reset đủ consent/ATT guard state

Vì sao quan trọng: `_resetGuardState()` chỉ reset một phần flag, trong khi `_canRequestAds`, `_lastUmpResult`, `_umpAttemptFailed` và `_attRequested` còn giữ lại qua `destroy()` rồi `initialize()` lại. App test nhiều config, hot restart/integration harness, hoặc app logout/login có thể inherit consent failure/success cũ vào phiên SDK mới.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:617`, `packages/ad_sdk/lib/src/core/ad_manager.dart:695`, `packages/ad_sdk/lib/src/core/ad_manager.dart:699`, `packages/ad_sdk/lib/src/core/ad_manager.dart:727`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1937`

Effort: M

Priority: P1

### P1 - README config reference ghi sai default `autoRequestUmpConsent`

Vì sao quan trọng: code default là `true`, nhưng bảng cấu hình trong README vẫn ghi `false`. Người dùng copy block config từ pub.dev có thể vô tình tắt UMP auto request, sau đó gặp zero-ads footgun hoặc flow consent không đúng kỳ vọng.

File/dòng liên quan: `packages/ad_sdk/lib/src/config/ad_config.dart:349`, `packages/ad_sdk/README.md:660`, `packages/ad_sdk/README.md:664`

Effort: S

Priority: P1

## 2. Enhancement (cải thiện tính năng đã có)

### P1 - Trả về `CanShowAdResult` thay vì boolean thuần

Vì sao quan trọng: SDK đã có nhiều skip reason nội bộ, nhưng API public chỉ trả boolean nên app tiêu thụ không biết nên disable UI, retry, mở purchase, hay chờ consent. Một result có `allowed`, `reason`, `retryAfter`, `adType`, `provider` sẽ cải thiện DX và giảm misuse.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:2342`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2632`, `packages/ad_sdk/lib/src/config/ad_safety_config.dart:11`

Effort: M

Priority: P1

### P2 - Expose consent/UMP state stream và last error

Vì sao quan trọng: `_lastUmpResult` và `_umpAttemptFailed` đang private, còn `ConsentManager.current` chưa đủ để UI debug consent readiness. App tiêu thụ cần phân biệt "đang chờ UMP", "UMP failed", "offline", "not required" để hiển thị trạng thái và telemetry chính xác.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:692`, `packages/ad_sdk/lib/src/core/ad_manager.dart:699`, `packages/ad_sdk/lib/src/consent/consent_manager.dart:79`

Effort: M

Priority: P2

### P2 - Emit structured skip/gate events thay vì chỉ log text

Vì sao quan trọng: các path bị chặn bởi VIP, cap, cooldown, consent, connectivity hiện chủ yếu đi qua `SafeLogger`. Nếu có `AdGateEvent`/`AdSkipEvent` trong event stream, app có thể audit funnel, phát hiện cấu hình sai và tạo dashboard mà không parse log.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:2271`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2302`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2981`, `packages/ad_sdk/lib/src/event/ad_event.dart:1`

Effort: M

Priority: P2

### P2 - Public listenable cho fullscreen mutex

Vì sao quan trọng: `_fullscreenBusyReason` bảo vệ tốt trong SDK nhưng app không quan sát được trạng thái busy để disable CTA hoặc tránh mở dialog riêng. Một `ValueListenable<FullscreenBusyState>` hoặc stream read-only sẽ làm interstitial/rewarded/app-open orchestration dễ dự đoán hơn.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:644`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2267`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2458`

Effort: S

Priority: P2

### P2 - Load watchdog cho fullscreen ad load thường

Vì sao quan trọng: SDK đã có timeout cho on-demand rewarded load, nhưng preload/load thường của interstitial/rewarded vẫn phụ thuộc callback native SDK. Khi native SDK im lặng sau network/process edge case, slot có thể kẹt trạng thái lâu hơn kỳ vọng.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:2391`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2427`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2755`

Effort: M

Priority: P2

## 3. Task mới / nợ kỹ thuật

### P1 - CI chưa cover fullscreen show/dismiss thật

Vì sao quan trọng: integration retry script loại `app_open`, `interstitial`, `rewarded` khỏi CI vì cần người đóng ad. Đây là đúng thực tế vận hành hiện tại, nhưng cũng nghĩa là các bug native render, dismiss callback, mutex release và reward callback chỉ được bảo vệ bằng test thủ công.

File/dòng liên quan: `.github/scripts/integration-retry.sh:87`, `.github/workflows/test.yml:99`, `.github/workflows/test.yml:238`

Effort: L

Priority: P1

### P1 - CI chỉ chạy AdMob path và skip consent/splash trên iOS

Vì sao quan trọng: Android/iOS CI đều ép `AD_PROVIDER_ADMOB=true`, còn iOS skip splash, ATT và UMP. AppLovin MAX adapter, mediation pod graph, ATT prompt ordering và UMP real path vì vậy chưa có coverage tự động tương xứng với risk của package dual-provider.

File/dòng liên quan: `.github/workflows/test.yml:100`, `.github/workflows/test.yml:248`, `.github/workflows/test.yml:251`, `.github/workflows/test.yml:252`, `.github/workflows/test.yml:255`

Effort: L

Priority: P1

### P1 - Pinning wall Dart/CocoaPods cần thành matrix test hoặc doctor check

Vì sao quan trọng: `CLAUDE.md` đã ghi rõ hai pinning wall: Dart-level quanh `google_mobile_ads`/`gma_mediation_applovin` và CocoaPods-level quanh AppLovinSDK exact versions. `pubspec.yaml` của package pass riêng lẻ chưa chứng minh consuming app có pod graph hợp lệ khi thêm mediation plugin.

File/dòng liên quan: `CLAUDE.md:132`, `CLAUDE.md:139`, `packages/ad_sdk/pubspec.yaml:58`, `packages/ad_sdk/pubspec.yaml:59`, `.github/workflows/test.yml:31`

Effort: M

Priority: P1

### P2 - README còn stale theo dependency hiện tại

Vì sao quan trọng: README vẫn nhắc `google_mobile_ads 6.x` trong khi package đang dùng `^7.0.0`; cùng với default UMP sai, docs pub.dev có thể dẫn người dùng debug nhầm version behavior. Đây là debt nhỏ nhưng ảnh hưởng trực tiếp adoption.

File/dòng liên quan: `packages/ad_sdk/README.md:222`, `packages/ad_sdk/README.md:664`, `packages/ad_sdk/pubspec.yaml:58`

Effort: S

Priority: P2

### P2 - Barrel export đang lộ nhiều low-level/testing surface

Vì sao quan trọng: `applovin_admob_sdk.dart` export adapters, event bus, slot/backoff/log internals và một số API thiên về test. Khi đã publish pub.dev, các symbol này làm tăng semver blast radius và khiến refactor nội bộ khó hơn.

File/dòng liên quan: `packages/ad_sdk/lib/applovin_admob_sdk.dart:7`, `packages/ad_sdk/lib/applovin_admob_sdk.dart:23`, `packages/ad_sdk/lib/applovin_admob_sdk.dart:49`

Effort: M

Priority: P2

### P2 - Chưa có coverage threshold dù test suite rộng

Vì sao quan trọng: 69 file test và 700 tests là baseline tốt, nhưng CI chỉ chạy `flutter test` không tạo hoặc enforce coverage. Các vùng native bridge, consent edge và lifecycle route có thể tụt coverage mà không bị phát hiện trong PR.

File/dòng liên quan: `.github/workflows/test.yml:31`, `.github/workflows/test.yml:36`, `packages/ad_sdk/test/`

Effort: S

Priority: P2

## 4. Ý tưởng tính năng mới

### P1 - Remote safety policy profile có fallback ký sẵn

Vì sao quan trọng: App tiêu thụ SDK thường cần đổi caps, cooldown, provider preference, consent strictness hoặc ad pressure mà không release app. Một profile remote có signature và local fallback sẽ biến safety layer hiện có thành cơ chế vận hành production.

File/dòng liên quan: `packages/ad_sdk/lib/src/config/ad_safety_config.dart:1`, `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart:1`

Effort: L

Priority: P1

### P2 - `AdReadinessSplashController` / widget orchestration chính thức

Vì sao quan trọng: README yêu cầu app set navigator, route observer, ATT, UMP, init SDK và app-open/splash flow đúng thứ tự. Một controller/widget first-party sẽ giảm lỗi integration và giúp app mới có flow production-ready nhanh hơn.

File/dòng liên quan: `packages/ad_sdk/README.md:73`, `packages/ad_sdk/README.md:139`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1061`

Effort: M

Priority: P2

### P2 - Revenue-backed provider experiment cho AppLovin vs AdMob

Vì sao quan trọng: SDK đã có revenue event, fill-rate monitor và arbitrator, nhưng chưa có lớp experiment end-to-end cho cohort, eCPM/fill comparison và rollback. Đây là tính năng hấp dẫn cho app muốn tối ưu doanh thu mà không viết hạ tầng ads riêng.

File/dòng liên quan: `packages/ad_sdk/lib/src/event/ad_event.dart:1`, `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart:1`, `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart:1`

Effort: L

Priority: P2

### P2 - Optional backend ledger cho VIP codes

Vì sao quan trọng: Offline signed VIP keys là điểm mạnh, nhưng một số app cần revoke, global one-time redemption và chống share code ở mức server. Cung cấp interface backend tùy chọn sẽ giữ mode offline hiện tại nhưng mở đường cho app doanh thu cao.

File/dòng liên quan: `packages/ad_sdk/README.md:760`, `packages/ad_sdk/README.md:810`, `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:95`

Effort: L

Priority: P2

### P2 - Adaptive ad pressure tự điều chỉnh theo device/session health

Vì sao quan trọng: SDK đã có tín hiệu adaptive frequency; bước tiếp theo là tự giảm/tăng ad pressure theo crash risk, latency, background rate, reward completion và retention proxy. Consuming app được lợi vì không phải tự nối telemetry vào caps/cooldown.

File/dòng liên quan: `packages/ad_sdk/lib/src/config/adaptive_frequency.dart:1`, `packages/ad_sdk/lib/src/config/ad_safety_config.dart:1`

Effort: L

Priority: P2

## 5. Tính năng độc quyền / flagship (differentiator)

### P1 - Compliance black box cho ad decisions

Vì sao quan trọng: Raw AppLovin MAX, raw Google Mobile Ads và nhiều wrapper chỉ cung cấp load/show callback; package này đã có event log, compliance report, debug overlay và policy risk score. Đẩy thành "black box export" sẽ tạo lợi thế pub.dev rõ ràng: giải thích được vì sao ad được request/show/skip.

File/dòng liên quan: `packages/ad_sdk/lib/src/event/ad_event_log.dart:1`, `packages/ad_sdk/lib/src/debug/compliance_report.dart:1`, `packages/ad_sdk/lib/src/config/ad_safety_config.dart:1`

Effort: M

Priority: P1

### P1 - Offline signed VIP entitlement cho ad suppression

Vì sao quan trọng: VIP code ký offline, có bundle binding, expiry guard và suppression xuyên suốt ad types là khác biệt mạnh so với wrapper ads thông thường. Nếu đóng gói thêm CLI/key rotation guide và diagnostics, đây có thể là flagship cho app indie không muốn vận hành backend.

File/dòng liên quan: `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:1`, `packages/ad_sdk/lib/src/vip/vip_manager.dart:1`, `packages/ad_sdk/lib/src/core/ad_manager.dart:2239`

Effort: M

Priority: P1

### P1 - Provider-agnostic safety gate + fullscreen mutex

Vì sao quan trọng: Điểm mạnh không chỉ là wrap hai provider, mà là cùng một lớp caps/cooldown/CTR/click-guard/VIP/consent/fullscreen arbitration ở trên cả AppLovin và AdMob. Đây là abstraction raw SDK không có và là lý do package có thể bán như một "ads safety SDK" thay vì chỉ là adapter.

File/dòng liên quan: `packages/ad_sdk/lib/src/core/ad_manager.dart:644`, `packages/ad_sdk/lib/src/config/ad_safety_config.dart:1`, `packages/ad_sdk/lib/src/provider/ad_provider_adapter.dart:1`

Effort: M

Priority: P1

### P2 - Runtime integration doctor cho consuming app

Vì sao quan trọng: Package đã có self-check/debug overlay nhưng có thể nâng thành doctor chạy runtime hoặc trong integration test: navigator key, route observer, UMP/ATT, ad unit placeholder, SKAdNetwork/Info.plist, Android manifest và mediation/pod graph. Đây là khác biệt rất thực tế vì phần lớn lỗi ads SDK xảy ra ở integration layer, không phải Dart API.

File/dòng liên quan: `packages/ad_sdk/lib/src/debug/integration_self_check.dart:1`, `packages/ad_sdk/lib/src/debug/ad_debug_overlay.dart:1`, `packages/ad_sdk/README.md:73`

Effort: L

Priority: P2

---

Agent tạo report: codex CLI

Ngày: 2026-08-15
