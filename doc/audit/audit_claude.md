# Audit SDK và example — applovin_admob_sdk

Ngày khảo sát: 2026-10-08. Đính chính: 2026-10-09.
Source khảo sát: `2d31e36`, phiên bản local `3.4.4`.
Phạm vi yêu cầu: SDK, example, Android/iOS, AdMob/AppLovin, online/offline, các định dạng quảng cáo, trial, VIP và consent/policy.

## 1. Kết luận hiện tại

**CHƯA ĐỦ BẰNG CHỨNG DUYỆT PRODUCTION**, kể cả Android + AdMob. Đây là báo cáo khảo sát đang tiếp tục, không phải chứng nhận an toàn hay tuân thủ pháp lý.

Báo cáo trước đã kết luận vượt bằng chứng. Đính chính trực tiếp:

- Không suy ra hoàn thành 73 vòng audit chỉ từ tên round hoặc lịch sử commit.
- Không coi suite có hai test FAIL là đạt release gate, dù chạy riêng file đó PASS.
- Không gộp kết quả nhiều thiết bị thành một lượt full suite. Lượt 134 PASS thuộc TECNO trong round 73, không phải full suite trên cả TECNO/Pixel/S24 và không phải lượt mới trên 3.4.4.
- Có `dispose()` và hủy listener không chứng minh không memory leak. Chưa profile heap/native memory trong phiên này.
- Cơ chế consent/policy trong source không chứng minh tuân thủ mọi quốc gia, mọi placement hoặc mọi cấu hình của ứng dụng tích hợp.
- Keychain không bảo đảm chống lặp trial tuyệt đối hay tồn tại vĩnh viễn. Source ghi rõ giới hạn khi xóa thiết bị, lỗi storage và restore sang thiết bị khác.
- Kiểm tra mạng khi nhập mã VIP không phải chống brute-force hay chống chia sẻ mã giữa thiết bị. Đó là product gate đã được chủ dự án chấp thuận.
- Metadata pub.dev và version local cùng số không chứng minh source archive trùng nhau. Chưa tải và so archive 3.4.4 trong phiên này.
- Chưa thực hiện kiểm chứng native đầy đủ trên iOS/AppLovin. Không rút gọn điều kiện release iOS thành chỉ thử một iPhone.

Các giới hạn đã được chủ dự án chấp thuận không bị mở lại thành yêu cầu đổi thiết kế: activation VIP cần mạng, VIP đã cấp dùng offline, mã khuyến mãi có thể dùng trên nhiều thiết bị, Android anti-reinstall best-effort, AppLovin không hỗ trợ đổi age-status giữa phiên, QA hashes luôn bật và AVP1/AVP2 cùng tồn tại.

## 2. Bằng chứng mới trong phiên 2026-10-08

| Kiểm tra | Quan sát | Giới hạn |
|---|---|---|
| Git baseline | `2d31e36`, working tree sạch trước khi sửa báo cáo | Không chứng minh toàn bộ source đã được đọc/audit |
| pub.dev API | Latest lúc truy vấn: `3.4.4`, published `2026-10-08T13:30:31.090433Z` | Snapshot ngày 2026-10-08, chưa so archive |
| pub.dev metrics | Scorecard thuộc `3.4.3`; sections: 30/30 + 20/20 + 20/20 + 30/50 + 30/40 = **130/160** | Top-level score trả 0/0; không gán điểm này cho 3.4.4. Báo cáo cũ ghi 110/160 là sai phép cộng |
| Pana trên 3.4.3 | Warning return Future trong try tại `ad_flight_recorder.dart:632`; info deprecation `cacheExtent` tại `in_feed_ad_list_view.dart:170` | SDK Flutter mới hơn máy local; chưa xác minh hậu quả runtime của warning |
| Analyze SDK | Exit 1, một info `curly_braces_in_flow_control_structures` tại `example/integration_test/r73_android_admob_fixes_test.dart:195:43` | Không gọi kết quả này là analyze sạch; sạch trên máy local không chứng minh sạch trên mọi SDK được hỗ trợ |
| Analyze example | Exit 1, cùng info trên | Chưa sửa |
| Unit/widget full suite ban đầu | **2.631 PASS, 2 FAIL**, exit 1 | Hai ca trong `r23_coppa_midinit_flip_test.dart` |
| Unit/widget full suite sau fix A74-02/A74-04 | **2.635 PASS, 0 FAIL**, exit 0 | Đã xác minh chạy trọn vẹn full suite, `All tests passed!`, exit code 0 |
| Rerun riêng r23 sau fix | **9 PASS**, `All tests passed!` | 8 ca cũ + 1 regression test A74-02 đều xanh |
| API golden riêng | **2 PASS** | Bề mặt API khớp golden |
| Example widget tests | **67 PASS**, `All tests passed!` | Không phải kiểm chứng UI/native ads trên thiết bị |
| Pinning check | Tool báo exit 0 khi chạy `./tool/check_pinning_wall.sh` | Output hiển thị không có dòng resolved Pod; không khẳng định đã quan sát `AppLovinSDK 13.6.3`. Script mặc định không build Android/iOS |
| Release readiness script | Exit 0, `release gate: all passed` | Chỉ chứng minh phạm vi script, không thay full test/native/policy gate |
| Thiết bị | `adb devices` không có Android; Flutter liệt kê macOS/Chrome, không có iPhone kết nối; iOS simulator đang shutdown | Chưa chạy smoke/manual/native integration mới trong phiên này |

Log full SDK suite: `/private/tmp/claude-502/-Users-LoiTP-StudioProjects-roy-applovin-admob-sdk-packages-ad-sdk/5d9532f2-f8d7-4d8b-941b-ca444d33d09f/tasks/b5q1337r9.output`. Đây là file tạm local, không được coi là evidence lưu bền trong repo.

### Hai ca test đỏ ban đầu (Đã giải quyết hoàn toàn)

- Hai ca fail ban đầu (`an age gate that answers ADULT mid-init schedules a retry` và `onComplete fires exactly once, not twice, when a retry is scheduled`) đã được xác định nguyên nhân: race condition do `setConsent()` không `await` tiếp tục chạy ngầm sau `destroy()`, kích hoạt re-init mồ côi vào native plugin thật.
- Đã vá triệt để tại Issue A74-02 bằng epoch guard trong `ad_manager.dart` và đồng bộ hoá async trong `r23_coppa_midinit_flip_test.dart`. Chạy lại full suite 2.635 test: **100% PASS, 0 FAIL**.

## 3. Bằng chứng round 73 — lịch sử, không phải lượt chạy mới

Nguồn: `audit_claude_round73.md`. Báo cáo đó vẫn ghi **CHƯA DUYỆT PRODUCTION**.

- Full suite cuối trên **TECNO KJ7**: 135 file, **134 PASS, 1 all-skipped, 0 FAIL, 0 retry**, real exit 0.
- Opt-in cases và sáu file chủ ý loại không nằm trong bằng chứng full suite đó.
- Pixel/S24 có kiểm chứng khác; không coi là full suite giống TECNO.
- Có ca dùng seam để mô phỏng callback refresh failure, suspend timer và show failure. Không coi là lỗi native tự nhiên đã tái hiện.
- Offline/reconnect banner có mạng thật kết hợp seam connectivity; không suy ra MREC/native recovery và toàn bộ lifecycle matrix đều đã pass.
- iOS trước đó chỉ có bằng chứng một phần; rewarded/app-open dismiss chưa đủ trong các lượt được báo cáo. Watchdog hard-cap không thay callback dismiss thật.
- Chưa profile memory; chưa có AppLovin inventory thật cho cả Android/iOS.

Các commit mới sau baseline round 73 gồm thay đổi VIP expiry/resume và consent recheck. Cần coverage trên bản hiện tại, không kế thừa kết luận PASS từ bản cũ mà không kiểm lại.

## 4. Đánh giá từng yêu cầu — cơ chế thấy được và phần còn thiếu

| Yêu cầu | Cơ chế quan sát trong source | Chưa chứng minh |
|---|---|---|
| Android/iOS và hai provider | Có adapter riêng, cấu hình provider và platform ID | Native matrix 2 platform × 2 provider trên bản hiện tại; build/link success mới |
| Online/offline | Manager có connectivity gate; round 73 có inline recovery wiring | Cold-start offline, mất mạng mid-request, reconnect, captive portal và lifecycle matrix của cả hai provider |
| Ad types/lifecycle | Có AdSlot, fullscreen guard, per-instance inline registry và widget teardown | Hai chu kỳ show/dismiss/reload thật, bỏ rewarded sớm, callback trễ, rotation, route/tab/overlay và teardown trên mọi nhánh native |
| Memory | Banner/MREC/native có dọn notifier/listener/timer và native ad instances | Heap/native profiling lặp nhiều chu kỳ; không tuyên bố zero leak |
| Trial 1 ngày | `FirstInstallVipGrace.auto` phân biệt debug 30s/release 24h; có first-install guard | Cửa sổ release 24h thật, restart/suspend/reinstall/restore/storage-failure trên thiết bị |
| VIP không backend | Có chữ ký Ed25519, bundle/expiry checks, ledger và secure-storage paths | Toàn bộ tamper/rollback/replay/storage failure/dispose matrix bản hiện tại; quản lý private key của app tích hợp |
| Consent | Có UMP, ATT, TCF storage, CCPA/RDP, COPPA/TFUA và init-time AppLovin gate | Required/reject/withdraw/reopen/error/offline trên native; cấu hình dashboard/CMP/partner và mọi jurisdiction của host |
| Policy | Có throttle/caps, modal/fullscreen guards, QA hashes và AdChoices UI | Nội dung placement/reward disclosure thật, app-ads.txt, privacy disclosures và policy hiện hành; không bảo đảm tài khoản không bị hạn chế |

### Giới hạn tích hợp phải giữ rõ

- Bare `IndexedStack` không tự được `VisibilityDetector` phát hiện. Host phải truyền `active` hoặc dùng cấu trúc visibility phù hợp; không tuyên bố SDK tự xử lý mọi tab ẩn.
- Custom `OverlayEntry` cần host khai báo qua `markCustomOverlayOnScreen`; nested Navigator cần observer/helper đúng. Guard root Navigator không bao phủ mọi modal tự động.
- Đọc public key không đủ tạo chữ ký Ed25519 hợp lệ nếu private key an toàn; điều này không ngăn sửa binary hoặc entitlement storage trên thiết bị bị kiểm soát.
- Mã VIP là promotion, không phải giấy phép globally single-use. Không đề xuất backend/IAP như thay đổi bắt buộc cho phạm vi này.
- Keychain và Android backup có giới hạn đã ghi trong `FirstInstallGuard`. Không gọi chống reinstall tuyệt đối.
- Bộ throttle/CTR là giảm rủi ro, không chứng nhận Google/AppLovin policy compliance.

## 5. Issues và quyết định

### A74-01 — Báo cáo kết luận vượt bằng chứng

**Đã đính chính ngày 2026-10-09 theo lựa chọn người dùng: sửa trực tiếp.** Bỏ duyệt production và điểm đánh giá tự chấm; tách evidence mới/cũ; sửa phép cộng Pana; bỏ khẳng định tuyệt đối về memory, trial, VIP và pháp lý. Không thay behavior SDK.

### A74-02 — Hai ca r23 đỏ trong full suite (Race condition COPPA re-init qua teardown)

**Đã sửa và có regression test:**
- **Nguyên nhân gốc:** Khi gọi `setConsent()` không `await`, luồng này chạy ngầm và gọi `applyConsentToProviders()`. Khi `destroy()` chạy giữa chừng, `destroy()` dọn dẹp adapter và mock channels. Sau khi `applyConsentToProviders()` hoàn tất, nhánh COPPA re-init cũ không kiểm tra lại `consentSessionEpoch`, vẫn tiếp tục gọi `initialize(config: cfg)` ngầm trên session đã bị hủy, dẫn đến gọi vào adapter native thật (`MissingPluginException`) và làm kẹt test kế tiếp (timeout 30s).
- **Vá SDK:** Tại `lib/src/core/ad_manager.dart:5605`, bổ sung kiểm tra `consentEpoch == _consentIntentEpoch && consentSession == _consentSessionEpoch` cả trước và sau khi `await applyConsentToProviders(...)`. Nếu session đã thay đổi (do `destroy()`) hoặc intent bị ghi đè, lập tức hủy tiến trình re-init và ghi log an toàn.
- **Vá Test:** Trong `test/r23_coppa_midinit_flip_test.dart`, đồng bộ hóa `await consentFuture` trước khi hoàn tất test; thay polling `delayed(100ms)` bằng `_pumpUntil(() => calls > 0)`.
- **Regression test:** Bổ sung ca test `Round-74 regression — a teardown occurring while applyConsentToProviders is in flight cancels the COPPA re-init instead of leaking initialize()`. Xác nhận: không có guard test ĐỎ (fail với `Expected: <0>, Actual: <1>`), có guard test XANH. Toàn bộ 9/9 test trong file PASS.

### A74-03 — Analyze exit 1 vì thiếu braces trong integration test

**Đã sửa theo lựa chọn người dùng:** thêm braces cho đúng đoạn `if`, không đổi logic. Dart MCP analyze `lib/`, `test/`, `example/` trả `No errors`. Chưa chạy integration trên thiết bị cho thay đổi này; không tính thành native PASS.

### A74-04 — Warning Future trong try của verifier

**Đã sửa và có regression test:** thêm `await` tại `lib/src/compliance/ad_flight_recorder.dart:632`. Viết test mới `signed overflowing numeric input fails closed, never throws` trong `test/ad_flight_recorder_test.dart`: khi chưa có `await`, test đỏ với `Converting object to an encodable object failed: Infinity`; có `await`, test bắt được lỗi và trả `false` an toàn. Toàn bộ file 34/34 PASS; analyze sạch.

### A74-05 — `cacheExtent` deprecated trên Flutter mới

**Đã xử lý theo lựa chọn người dùng:** Thêm `// ignore: deprecated_member_use` trên dòng `cacheExtent: widget.cacheExtent` trong `lib/src/widget/in_feed_ad_list_view.dart:170`. Giữ nguyên floor tương thích Flutter `>=3.38.1` (thuộc tính thay thế chưa có trên floor cũ) đồng thời triệt tiêu info warning khi pana trên pub.dev phân tích tĩnh với Flutter 3.47+. Analyze sạch.

## 6. Điều kiện đánh giá lại production

- Xác minh và xử lý hai test đỏ tận nguyên nhân; full suite mới PASS không retry che lỗi.
- Analyze SDK/example PASS; tách warning theo Flutter mới khỏi lỗi runtime.
- Native tests/manual trên bản hiện tại, ghi rõ platform/provider/device, skipped/blocked và mock/seam.
- Consent required/reject/withdraw/reopen/error và ATT trên thiết bị phù hợp; policy/dashboard của ứng dụng tích hợp được đối chiếu nguồn chính thức hiện hành.
- Profile memory/native resources trong chu kỳ route, inline ads và fullscreen teardown.
- Build thực Android/iOS với pinning combo đã duyệt; không suy ra build success từ pub get/pod install.

Chưa có kết luận toàn diện mới về production. Các phần chưa kiểm chứng là thiếu bằng chứng, không tự được gọi là bug SDK. Không sửa SDK, bump dependency/version, commit, push hoặc publish trong bước đính chính này.

## Nguồn

- https://pub.dev/packages/applovin_admob_sdk
- https://pub.dev/api/packages/applovin_admob_sdk
- https://pub.dev/api/packages/applovin_admob_sdk/metrics
- `doc/audit/audit_claude_round73.md`
- Source và log được nêu ở trên; chưa đối chiếu đầy đủ policy hiện hành trong phiên khảo sát này.
