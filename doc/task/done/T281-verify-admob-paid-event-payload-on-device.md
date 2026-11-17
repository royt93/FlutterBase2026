# T281 — Xác minh payload doanh thu AdMob test ad trên Android

- **Loại:** Verification / Test enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Confidence:** No payload defect reproduced; native AdMob test callback verified on one Android device.
- **Status:** done (2026-11-17)
- **Evidence:** `test/admob_behavioral_test.dart:1823-1899` verifies all four fullscreen formats' request ID, valueMicros, currency, precision, type and placement via fake bridge. `example/integration_test/t185_revenue_request_id_test.dart` passed on TECNO KJ7 (Android 14/API 34), isolated app ID `com.roy.admobwrapper.t281qa`, Google test inventory, 2026-11-17. Logs showed real interstitial loaded, `showInterstitial ✅ shown`, impression callback, then the native `AdRevenueEvent` assertion matched `requestId`, nonnegative `valueMicros`, three-letter `currencyCode`, valid `precision`, interstitial type and unspecified placement. No production IDs/credentials or host package touched. The test intentionally does not dismiss the native test ad; SDK teardown completed after its bounded wait.
- **Completed:** Unit/bridge mapping assertions plus real Android test-ad callback verification for the T185 payload fields. This proves one device/build/test-inventory path, not production revenue values, all devices, or mediation waterfall availability.
- **Dependencies:** Android device có mạng; Google test inventory; không cần production account

## Bối cảnh & vấn đề

AdMob bridge chuyển `valueMicros`, `currencyCode`, `precision` vào `AdRevenueEvent`; integration test T185 xác minh paid callback thật và `requestId`, nhưng không assert payload đầy đủ. Unit/bridge tests không chứng minh native Android callback thực tế đi qua đến event với đúng đơn vị, tiền tệ, độ chính xác và mediation metadata. Đây là thiếu bằng chứng, không phải lỗi đã tái hiện. Google test ad có thể không phát paid event ổn định hoặc có giá trị cụ thể; test không được giả định amount cố định.

## Phạm vi

1. Rà lại test T185 và adapter listener để xác định assertion ổn định, không phụ thuộc giá trị doanh thu cố định.
2. Mở rộng integration test hiện có để quan sát event thật trên Android: callback xuất hiện, `valueMicros` có đơn vị như contract, `currencyCode` không rỗng, `precision` thuộc giá trị bridge hợp lệ, và `requestId` khớp ad load.
3. Kiểm tra `mediationWaterfall` chỉ khi test device response có metadata; nếu không, ghi N/A chứ không tạo expectation giả.
4. Nếu Google test inventory không đảm đảm bảo paid callback, ghi rõ limitation, giữ unit/bridge verification và đóng device assertion là unsupported; không thêm polling dài hay production test IDs.

## Acceptance criteria

- [ ] Integration assert payload fields từ callback Android thật hoặc report rõ field nào test inventory không bảo đảm.
- [ ] Không assert số tiền cụ thể; không coi `$0`/callback vắng mặt ở một lần chạy là bằng chứng bug.
- [ ] Test event không bị trộn giữa nhiều ad request; subscription luôn được hủy.
- [ ] Unit/bridge coverage xác minh mapping cả ba field, precision values và dispose boundary nếu còn thiếu.
- [ ] Chạy integration case với Google test ads trên Android device, lưu command, device model/OS, log và kết quả; không cài đè `com.roy.admobwrapper`.
- [ ] `flutter analyze` và full SDK unit suite pass nếu code/test thay đổi.
- [ ] Widget test N/A nếu không sửa UI; ghi lý do trong kết quả.
- [ ] Golden test N/A nếu không đổi golden; interruption/network-conditioning/memory-profile/frame-jank chạy nếu lifecycle có thể bị ảnh hưởng; mediation assertion chỉ khi device trả metadata. IAP N/A vì ngoài SDK scope.
- [ ] Không dùng production ad IDs, account hay credentials.

## Kế hoạch kiểm thử

- **Unit/bridge:** controlled native callback values; mapping micro-units/currency/precision; event lifecycle/dispose.
- **Widget:** N/A, không đổi widget.
- **Integration:** Mở rộng `example/integration_test/t185_revenue_request_id_test.dart` hiện có, dùng event native test-ad; nếu payload callback không được Google test inventory bảo đảm, ghi unsupported thay vì thêm flaky assertion.
- **Smoke:** thiết bị Android thật, test IDs, disposable package ID; lưu log/screenshot phù hợp. Không đụng host app.
- **Ma trận bổ sung:** golden N/A nếu không đổi rendering/API golden; interruption, network conditioning, memory/profile, frame/jank và mediation kiểm tra theo rủi ro thực tế; IAP N/A vì là host-app concern, không thuộc SDK.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T281 theo TDD; đọc ticket, `lib/src/adapters/admob_adapter.dart`, `lib/src/adapters/gma_bridge.dart`, `test/gma_bridge_test.dart` và `example/integration_test/t185_revenue_request_id_test.dart`. Xác nhận chính xác contract của `valueMicros`, `currencyCode`, `precision`, `requestId`; không suy đoán hoặc hardcode doanh thu test ad. Mở rộng test bridge/integration tối thiểu để kiểm tra callback thật nếu Google test inventory hỗ trợ; nếu không, ghi unsupported có bằng chứng và không thêm flaky assertion. Subscription phải được hủy và timeout hữu hạn. Chạy targeted tests, analyze, full SDK tests. Widget test ghi N/A nếu UI không đổi. Chạy Android smoke trên device thật bằng test IDs và disposable app ID; lưu log/result, không cài đè `com.roy.admobwrapper`, không dùng production credentials. Kiểm tra golden, interruption, network conditioning, memory/profile, frame/jank, IAP và mediation khi có thể ảnh hưởng; ghi N/A cùng lý do, không tạo coverage giả. IAP ngoài SDK scope trừ khi mở scope. Independent audit toàn bộ diff và chấm điểm /10. Chỉ push code khi mọi kiểm tra áp dụng pass, evidence thật có đủ và điểm >9/10; không push nếu kết luận là limitation/no-change.
```
