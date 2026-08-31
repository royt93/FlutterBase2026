# Roadmap đề xuất độc lập — `applovin_admob_sdk` sau audit round 26

**Ngày:** 2026-08-31  
**Baseline:** package `applovin_admob_sdk` 2.4.1, task T01–T100 và `audit_round26_consolidated.md`  
**Phạm vi đã đọc:** toàn bộ `packages/ad_sdk/lib/`, `example/`, tài liệu Markdown trong package, task board và các báo cáo audit liên quan.

## Nguyên tắc lọc đề xuất

- Không lặp lại ba finding còn mở của round 26: race trong `_redeemed_key_ledger.markRedeemed`, callback `onFailed` trễ của bốn fullscreen AdMob, và khoảng hở `_persist()` → `_applyToProviders()` của consent AppLovin.
- Không tạo lại các task T88–T100 đã có như remote safety config, rewarded-interstitial, provider A/B splitter, animated banner collapse, per-placement caps, readiness splash, CRL, signed compliance report, fill-rate regression detector, runtime doctor và VIP arbitrator.
- Không thay kiến trúc VIP Ed25519 offline, safety cap hay consent dual-provider. Mọi ý tưởng dưới đây chạy trong app, dùng storage/event hiện có và không cần backend riêng.
- Effort: **S** ≤ 2 ngày, **M** 3–5 ngày, **L** 1–2 tuần, **XL** > 2 tuần; gồm code, test và tài liệu.

## 1. BUG cần fix

### BUG-1 — Tuần tự hóa ghi baseline fill-rate/eCPM

- **Ưu tiên / effort:** P1 / M
- **Vấn đề:** `FillRateBaselineMonitor._onEvent()` gọi `recordFillRateBaselineSample()` bằng `unawaited`. Mỗi lần ghi lại đọc toàn bộ JSON, cộng delta rồi ghi lại. Hai event load/revenue sát nhau có thể cùng đọc snapshot cũ và phép ghi hoàn tất sau cùng làm mất delta của phép kia. Baseline 7 ngày vì vậy thấp hoặc sai, kéo theo cảnh báo regression sai.
- **Code liên quan:** `lib/src/monetization/fill_rate_baseline_monitor.dart`, `lib/src/utils/ad_preferences.dart` (`recordFillRateBaselineSample`).
- **Việc cần làm:** thêm write-chain/mutex theo instance hoặc API cộng dồn theo batch; chờ flush khi disable/destroy; test với hai write bị chủ động đảo thứ tự completion.
- **Vì sao đáng làm:** bảo toàn dữ liệu đầu vào của flagship T97; tránh publisher ra quyết định monetization dựa trên số liệu bị mất ngẫu nhiên.

### BUG-2 — Toast cũ không được phép dismiss toast mới

- **Ưu tiên / effort:** P2 / S
- **Vấn đề:** `_TopToastWidget` dùng `Future.delayed(duration, _animateOut)`. Khi `TopToast.show()` thay toast A bằng B, timer của A vẫn chạy; `onDismiss` của A gọi static `_dismiss()` và có thể remove `_current` đang là B. Tap nhiều lần còn có thể gọi `reverse()` đồng thời.
- **Code liên quan:** `lib/src/widget/top_toast.dart`.
- **Việc cần làm:** dùng `Timer` có thể hủy và token/identity-bound dismiss (`dismiss(entry)` chỉ remove đúng entry); khóa một lần cho animation-out; thêm widget test A→B trước deadline A.
- **Vì sao đáng làm:** thông báo “ad chưa sẵn sàng”, safety/VIP nudge không biến mất sớm hoặc nhấp nháy trong app thật.

### BUG-3 — Chờ compliance log flush trước khi mở session mới

- **Ưu tiên / effort:** P1 / M
- **Vấn đề:** `_destroy()` gọi `unawaited(_eventLog?.flush())` rồi đặt `_eventLog = null`. `destroy()` có thể hoàn tất và `initialize()` tạo log mới trước khi flush cũ ghi xong; log mới đọc dữ liệu cũ, sau đó hai session có thể ghi cùng key và session cũ ghi đè các event đầu session mới. Điều này phá tính đầy đủ của compliance report dù từng `AdEventLog` riêng lẻ đã có `_persistChain`.
- **Code liên quan:** `lib/src/core/ad_manager.dart` (cuối `_destroy`), `lib/src/compliance/ad_event_log.dart`, `lib/src/utils/ad_preferences.dart`.
- **Việc cần làm:** await `flush()` có timeout hữu hạn trước khi null hóa; hoặc chuyển quyền sở hữu một shared persistence chain qua các session; test destroy→initialize với delayed storage write.
- **Vì sao đáng làm:** audit trail và chữ ký report chỉ có giá trị khi không mất/ghi đè sự kiện tại đúng ranh giới lifecycle nhạy cảm.

### BUG-4 — EventBuffer của example chết sau `AdManager.destroy()`

- **Ưu tiên / effort:** P2 / S
- **Vấn đề:** example subscribe `AdManager().events` đúng một lần trong `main()`. `destroy()` đóng controller và tạo stream controller mới, nên subscription gốc nhận `done` và không bao giờ theo stream mới. Sau demo destroy/re-init, màn Events âm thầm không còn ghi nhận event.
- **Code liên quan:** `example/lib/main.dart` (`main`, `EventBuffer`), `lib/src/core/ad_manager.dart` (`_eventStream` recreation, `initRevision`).
- **Việc cần làm:** tạo lifecycle-aware binding re-subscribe theo `initRevision`, giữ/cancel `StreamSubscription`, test destroy→initialize→emit event.
- **Vì sao đáng làm:** app mẫu là tài liệu executable; log demo sai khiến integrator hiểu nhầm SDK không emit callback sau re-init.

### BUG-5 — Không ghi vào `ValueNotifier` splash đã dispose

- **Ưu tiên / effort:** P1 / S
- **Vấn đề:** `_SplashScreenState.dispose()` dispose `_navigated` nhưng không đánh dấu điều hướng/không vô hiệu hóa toàn bộ callback async. Callback load/dialog đã được giao cho native trước dispose có thể gọi `_goHome()`, nơi gán `_navigated.value = true` trước kiểm tra `mounted`, gây “ValueNotifier was used after being disposed”. Đây là implementation splash riêng của example, không phải finding controller đã fix trong round 26.
- **Code liên quan:** `example/lib/main.dart` (`_SplashScreenState._showAppOpen`, `_goHome`, `dispose`).
- **Việc cần làm:** dùng bool lifecycle token hoặc set terminal state trước dispose; kiểm tra generation/mounted trước mọi write; regression test callback load/dismiss trễ sau dispose.
- **Vì sao đáng làm:** loại crash khỏi mẫu copy-paste phổ biến nhất của SDK và tránh người dùng mang bug vào app production.

## 2. ENHANCEMENT — cải thiện tính năng hiện có

### ENH-1 — Một API bootstrap consent + init có kiểu dữ liệu rõ ràng

- **Ưu tiên / effort:** P1 / L
- **Cơ hội:** flow khuyến nghị hiện buộc host tự xâu chuỗi ATT, UMP, fallback consent, initialize và splash timeout. Example dài và dễ copy thiếu một bước dù SDK đã có đủ primitive.
- **Code liên quan:** `lib/src/core/ad_manager.dart`, `att_consent.dart`, `ump_consent.dart`, `ad_readiness_splash_controller.dart`, `doc/init.md`, example splash.
- **Cải thiện:** thêm `bootstrap(AdBootstrapOptions)` trả `AdBootstrapResult` chứa ATT/UMP/init/diagnostic outcome; vẫn giữ API thấp tầng và callback cũ tương thích.
- **Giá trị:** giảm boilerplate và footgun compliance trong lần tích hợp đầu tiên.

### ENH-2 — Placement object dùng xuyên suốt load/show/widget

- **Ưu tiên / effort:** P2 / M
- **Cơ hội:** `AdPlacement` đã tồn tại nhưng nhiều entry point vẫn nhận string/default placement ở các tầng khác nhau, làm host dễ typo và khó tái sử dụng cấu hình per-placement.
- **Code liên quan:** `lib/src/state/ad_placement.dart`, `core/ad_manager.dart`, `core/ad_screen.dart`, các widget banner/MREC/native.
- **Cải thiện:** overload nhận `AdPlacement` typed cho mọi format; factory/const catalog cho host; deprecate dần string overload thay vì breaking change.
- **Giá trị:** autocomplete tốt hơn, ít sai key thống kê/cap và code tích hợp nhất quán.

### ENH-3 — Chính sách retry cấu hình theo format và loại lỗi

- **Ưu tiên / effort:** P2 / L
- **Cơ hội:** SDK đã có `Backoff` và watchdog nhưng chủ yếu dùng một policy chung; no-fill, network, invalid-request và timeout có ý nghĩa khác nhau.
- **Code liên quan:** `lib/src/state/backoff.dart`, `state/ad_slot.dart`, hai adapter, `config/ad_config.dart`, `_retryRefillAds` trong manager.
- **Cải thiện:** expose `AdRetryPolicy` per slot với max delay, jitter, retryable error classifier và reset-on-connectivity; default giữ nguyên hành vi 2.4.1.
- **Giá trị:** app ít chờ vô ích sau lỗi cấu hình nhưng phục hồi nhanh hơn khi mạng/no-fill thoáng qua.

### ENH-4 — Snapshot trạng thái tất cả ad slot bằng một listenable

- **Ưu tiên / effort:** P2 / M
- **Cơ hội:** host muốn disable nút/show skeleton hiện phải ghép nhiều `ValueNotifier` và biết chi tiết adapter/widget instance.
- **Code liên quan:** `lib/src/core/ad_manager.dart`, `state/ad_slot.dart`, `widget/debug_ad_overlay.dart`, `ad_readiness_splash_controller.dart`.
- **Cải thiện:** public immutable `AdSdkStateSnapshot` + `ValueListenable`, gồm init/consent/offline/VIP/fullscreen-busy và trạng thái từng slot; cập nhật coalesced theo microtask.
- **Giá trị:** UI host phản ứng đúng với SDK bằng một subscription, giảm listener leak và glue code.

### ENH-5 — Export diagnostics/compliance có redaction profile

- **Ưu tiên / effort:** P2 / M
- **Cơ hội:** report hiện hữu ích nhưng host cần tự quyết trường nào được gửi cho support; placement, device/test identifier hoặc consent string có thể nhạy cảm theo chính sách riêng.
- **Code liên quan:** `lib/src/compliance/compliance_report.dart`, `compliance_signing.dart`, `monetization/ad_diagnostics.dart`, tool verifier.
- **Cải thiện:** `ReportRedactionProfile` (`supportSafe`, `fullLocal`, custom field policy), metadata schema version và preview trước export/sign.
- **Giá trị:** support nhanh hơn mà giảm nguy cơ app vô tình chia sẻ dữ liệu không cần thiết.

## 3. TECH DEBT — không đổi hành vi observable

### DEBT-1 — Tách `AdManager` 6.999 dòng thành internal coordinators

- **Ưu tiên / effort:** P1 / XL
- **Nợ kỹ thuật:** một singleton đang chứa init, consent, lifecycle, connectivity, safety, fullscreen orchestration, telemetry và VIP wiring; mỗi fix race phải hiểu nhiều generation/token không liên quan.
- **Code liên quan:** `lib/src/core/ad_manager.dart`.
- **Refactor:** tách private `InitCoordinator`, `ConsentCoordinator`, `LifecycleCoordinator`, `FullscreenCoordinator`, `RetryCoordinator`; facade public và thứ tự side effect giữ nguyên; làm từng lát với characterization tests.
- **Giá trị:** giảm blast radius và thời gian audit/fix, đặc biệt ở teardown/re-init race.

### DEBT-2 — Hợp nhất lifecycle keyed inline-ad giữa hai adapter

- **Ưu tiên / effort:** P2 / L
- **Nợ kỹ thuật:** banner/MREC/native có nhiều map instance, sentinel warmup key, listenable disposal và revive logic gần giống nhau nhưng triển khai lặp ở AdMob/AppLovin.
- **Code liên quan:** `adapters/admob_adapter.dart`, `applovin_adapter.dart`, `_inline_visibility.dart`, ba widget inline.
- **Refactor:** internal generic `InlineAdInstanceRegistry<TAd>` quản lý ownership, notifier, generation và dispose; bridge provider chỉ cung cấp load/destroy callbacks.
- **Giá trị:** ngăn regression “format/provider này đã fix nhưng format/provider kia bị quên” mà không đổi public API.

### DEBT-3 — Chuẩn hóa primitive hủy callback async

- **Ưu tiên / effort:** P1 / L
- **Nợ kỹ thuật:** code dùng lẫn generation int, bool disposed, timer, identity check và `Completer`; correctness hiện phụ thuộc comment dài tại từng call site.
- **Code liên quan:** manager, hai adapter, UMP, VIP manager, splash controller, loading dialog.
- **Refactor:** internal `OperationToken`/`AsyncEpoch` thống nhất `isCurrent`, invalidate và bounded await; migrate từng subsystem, giữ timing hiện tại bằng fake clock tests.
- **Giá trị:** race teardown/provider-switch dễ chứng minh và review hơn.

### DEBT-4 — Chia example monolith theo từng demo

- **Ưu tiên / effort:** P2 / M
- **Nợ kỹ thuật:** `example/lib/main.dart` dài khoảng 2.700 dòng, chứa config, splash, buffers và toàn bộ pages; thay đổi một demo tạo conflict và khó tìm đoạn tích hợp chuẩn.
- **Code liên quan:** `example/lib/main.dart`, example tests/integration tests.
- **Refactor:** tách `config/`, `bootstrap/`, `demos/<format>/`, `shared/`; không đổi key/widget text đang được integration test tìm.
- **Giá trị:** example dễ đọc như cookbook, giảm lỗi khi publisher copy một use case cụ thể.

### DEBT-5 — Contract-test chung cho `AdProviderAdapter`

- **Ưu tiên / effort:** P1 / L
- **Nợ kỹ thuật:** test hai adapter nhiều nhưng parity chủ yếu được assert theo file riêng; các lệch guard/callback/dispose thường chỉ lộ sau audit độc lập.
- **Code liên quan:** `core/ad_provider_adapter.dart`, test `admob_*`, `applovin_*`, bridge fakes.
- **Refactor:** reusable contract suite chạy cùng scenario matrix cho hai provider: consent epoch, late callbacks, N instances, watchdog, revenue, dispose và show mutex.
- **Giá trị:** khóa dual-provider parity trong CI và giảm chi phí mỗi lần nâng plugin native.

## 4. Ý TƯỞNG MỚI — feature không cần backend

### IDEA-1 — Waterfall tuner on-device theo placement

- **Ưu tiên / effort:** P2 / XL
- **Cơ hội:** event hiện có load latency, fill/revenue/network name nhưng chưa biến chúng thành khuyến nghị cấu hình.
- **Code liên quan:** `state/ad_event.dart`, compliance log, fill-rate monitors, diagnostics, experiment bucket.
- **Tính năng:** lưu rolling score theo provider/format/placement (fill, latency, eCPM), đưa ra khuyến nghị local “ưu tiên provider X cho placement Y”; chỉ auto-switch tại ranh giới session khi host opt-in, không load shadow ad.
- **Giá trị:** tối ưu doanh thu/latency theo chính thiết bị mà không gửi dữ liệu ra server và không tăng ad request.

### IDEA-2 — Smart prefetch theo hành trình người dùng

- **Ưu tiên / effort:** P2 / L
- **Cơ hội:** preload hiện chủ yếu theo init/resume/reconnect, chưa biết một placement sắp được dùng.
- **Code liên quan:** manager load APIs, route observer, ad slot/backoff, safety config.
- **Tính năng:** host khai báo lightweight signals (`levelStarted`, `screenEntered`, `expectedBreakIn`) và budget; SDK học rolling time-to-show on-device để preload vừa đủ sớm, tự bỏ qua khi VIP/cap/offline/consent đóng.
- **Giá trị:** tăng ready rate và giảm thời gian chờ nhưng không giữ ad quá lâu hay phát request thừa.

### IDEA-3 — Contextual adaptive banner size controller

- **Ưu tiên / effort:** P2 / L
- **Cơ hội:** AppLovin đã thích ứng width và AdMob có anchored adaptive sizing, nhưng host vẫn tự quyết banner/MREC/native và breakpoint.
- **Code liên quan:** ba inline widget, hai adapter/bridge, `MediaQuery`, visibility helper.
- **Tính năng:** `AdaptiveAdSurface` tự chọn banner/MREC/native-template theo available width, orientation và policy host; debounce resize, giữ instance ownership đúng và không thay format khi fullscreen đang bận.
- **Giá trị:** một widget tối ưu tablet/foldable/rotation, ít layout shift và boilerplate.

### IDEA-4 — Offline incident recorder + replayable support bundle

- **Ưu tiên / effort:** P3 / L
- **Cơ hội:** diagnostics/report là snapshot; race “không hiện ad” thường cần chuỗi trạng thái trước đó và khó tái tạo trên máy publisher.
- **Code liên quan:** event log, diagnostics, safety snapshots, consent transitions, connectivity events, compliance signing.
- **Tính năng:** ring buffer có giới hạn lưu state-transition timeline, config fingerprint đã redact và clock deltas; export bundle signed để tool CLI replay state machine, hoàn toàn local.
- **Giá trị:** giảm đáng kể thời gian support các lỗi chỉ xuất hiện trên một thiết bị mà không cần telemetry server.

### IDEA-5 — Creative fatigue guard on-device

- **Ưu tiên / effort:** P2 / L
- **Cơ hội:** cap hiện đếm impression/click theo thời gian/placement nhưng không nhận biết một network/creative lặp quá dày gây UX xấu và CTR bất thường.
- **Code liên quan:** `AdRevenueEvent.networkName`, safety config, event log, adapter callbacks/metadata nếu plugin expose creative/ad identifiers.
- **Tính năng:** hash identifier không đảo ngược và lưu rolling exposure local; khi có đủ metadata thì cooldown creative/network lặp, khi thiếu metadata fail open về cap hiện hữu. Không can thiệp click hay nội dung creative.
- **Giá trị:** giảm fatigue và hành vi click bất thường, bảo vệ retention lẫn tài khoản quảng cáo.

## 5. TÍNH NĂNG ĐỘC QUYỀN / FLAGSHIP

### FLAGSHIP-1 — Offline Policy Autopilot có thể chứng minh

- **Ưu tiên / effort:** P0 / XL
- **Khác biệt:** nâng safety layer hiện tại thành engine policy-as-code local: từ loại app/audience/placement, tạo policy profile bất biến cho consent, cap, preload/show, rewarded disclosure và App Open; mọi quyết định phát sinh “decision receipt” có hash-chain và có thể ký bằng compliance signing hiện hữu.
- **Code liên quan:** `ad_safety_config.dart`, consent manager, compliance log/report/signing, integration self-check, config.
- **Phạm vi khả thi:** bundled versioned rules + host override chỉ được siết chặt; không tải rule từ server, không thay UMP/CMP; tool CLI verify receipt và giải thích “vì sao request/show bị chặn”.
- **Vì sao must-have:** dev tự tích hợp hai plugin phải tự nối hàng chục policy guard và không có bằng chứng hậu kiểm. SDK này biến compliance từ checklist thủ công thành hành vi enforce + giải thích được.

### FLAGSHIP-2 — Self-healing Dual-Provider Runtime

- **Ưu tiên / effort:** P0 / XL
- **Khác biệt:** state machine on-device phát hiện provider/format bị kẹt hoặc suy giảm bằng timeout, fill, latency, callback anomaly và circuit breaker; cách ly đúng slot/provider rồi chuyển sang provider còn lại ở ranh giới an toàn, có rollback và cooldown.
- **Code liên quan:** provider adapter contract, ad slots/backoff, fill-rate baseline, diagnostics, experiment bucket, manager provider switch lifecycle.
- **Phạm vi khả thi:** không shadow-load, không đổi provider khi fullscreen/consent flow đang hoạt động, không vượt cap; quyết định chỉ dùng rolling metrics local và config host ký/compile-time.
- **Vì sao must-have:** lợi thế cốt lõi của dual-provider không chỉ là một enum chuyển tay; app tiếp tục kiếm tiền khi một SDK/native network hỏng cục bộ mà không cần remote ops/backend.

### FLAGSHIP-3 — Monetization Digital Twin chạy hoàn toàn trên thiết bị

- **Ưu tiên / effort:** P1 / XL
- **Khác biệt:** mô phỏng trước tác động của cap, retry, provider split, VIP duration và preload policy từ event history local; trả dự báo dạng khoảng tin cậy về impression/revenue/blocked-request/UX cost, không phát ad thử.
- **Code liên quan:** compliance event log, adaptive frequency, monetization arbitrator, fill-rate baseline, experiment bucket, diagnostics/export tool.
- **Phạm vi khả thi:** deterministic replay + counterfactual rules trên ring buffer đã redact; có “shadow decision mode” chỉ ghi SDK *sẽ* làm gì, không thay hành vi production cho đến khi host bật.
- **Vì sao must-have:** publisher có thể tune monetization an toàn bằng dữ liệu thật của app trước khi ảnh hưởng người dùng—khả năng mà hai plugin quảng cáo thô không cung cấp và vẫn giữ triết lý zero-backend.

## Thứ tự roadmap đề nghị

1. **Sprint production hardening:** BUG-1, BUG-3, BUG-5, DEBT-5; sau đó BUG-2 và BUG-4.
2. **Sprint integration ergonomics:** ENH-1, ENH-4, ENH-2; song song DEBT-4.
3. **Sprint runtime resilience:** ENH-3, DEBT-3 và prototype FLAGSHIP-2 ở chế độ observe-only.
4. **Sprint monetization intelligence:** IDEA-1/IDEA-2 và FLAGSHIP-3 shadow mode; chỉ auto-act sau đủ test/canary local.
5. **Dòng sản phẩm khác biệt:** FLAGSHIP-1 làm nền policy/receipt trước khi quảng bá rộng “production-safe dual-provider”, rồi mới bật self-healing mặc định opt-in.

## Definition of Done chung khi tách thành T101+

- Mỗi bug có regression test chứng minh red-before/green-after; race test phải điều khiển được thứ tự callback/write, không dựa `sleep`.
- Chạy `flutter analyze`, toàn bộ `flutter test`, và integration matrix Android+iOS cho phần chạm native/lifecycle.
- Mọi API mới backward-compatible trong minor release, có migration/deprecation note và example executable.
- Mọi feature lưu local có retention cap, schema version, corruption fallback, erase API và tài liệu privacy; mặc định opt-in nếu ảnh hưởng monetization.
- Không phát thêm ad request chỉ để đo lường; mọi quyết định vẫn đi qua consent, VIP, safety cap và fullscreen mutex hiện hữu.
