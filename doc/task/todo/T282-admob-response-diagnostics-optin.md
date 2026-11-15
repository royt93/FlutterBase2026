# T282 — Kiểm tra nhu cầu diagnostics mediation AdMob

- **Loại:** Idea / Enhancement proposal (discovery only)
- **Priority:** P3 · **Severity:** LOW
- **Confidence:** IDEA; chưa có defect hoặc partner demand đã xác nhận
- **Status:** todo (không phải cam kết phát triển API)
- **Evidence:** `lib/src/adapters/gma_bridge.dart:47-59`; `lib/src/adapters/admob_adapter.dart:155-225`; `lib/src/state/ad_event.dart:142-166`; `lib/src/monetization/ad_diagnostics.dart:15-33, 85-90, 173-218`; `test/privacy_safe_diagnostics_test.dart`
- **Dependencies:** Partner use case cụ thể; rà ResponseInfo contract/privacy; owner approval trước API change

## Ý tưởng & giả thuyết giá trị

SDK đã đưa `mediationWaterfall` vào `AdRevenueEvent` và `AdDiagnostics.lastWaterfallBySlot` tổng hợp waterfall từ persisted revenue events. Giả thuyết cần kiểm tra: partner AdMob cần nhìn mediation response/no-fill details cho request không tạo paid event. Không có evidence hiện tại rằng public diagnostics mới cần thiết; feature có thể trùng dữ liệu ResponseInfo mà host đã lấy trực tiếp hoặc API chẩn đoán hiện tại đã đủ.

## Discovery gate

1. Thu một case thật từ partner: màn/format, failure scenario, dữ liệu họ cần, quyết định họ muốn đưa ra.
2. Thử giải bằng `AdManager.events`, `AdManager.diagnostics()` và `AdDiagnostics.toSafeJsonString()` trước khi đề xuất API mới.
3. Kiểm tra chính xác metadata mà Google Mobile Ads trả ở success/no-fill và qua các version constraints hiện có.
4. Rà privacy, retention, ID/redaction, ổn định schema và chi phí public API.
5. Nếu không có gap thực hoặc không có partner demand, đóng/refute proposal; không code, không push.
6. Nếu đủ bằng chứng, tạo implementation ticket riêng với field schema/compatibility scope; ticket này vẫn discovery-only.

## Acceptance criteria

- [ ] Partner demand có ví dụ tái hiện và trường dữ liệu cụ thể được ghi nhận.
- [ ] Chứng minh API/event/export hiện có không đáp ứng; không duplicate `AdDiagnostics`/`AdRevenueEvent`.
- [ ] Có tài liệu source đáng tin cậy về ResponseInfo semantics khi no-fill và compatibility.
- [ ] Privacy review: không lộ ad/user IDs, credentials, raw consent payload hoặc dữ liệu không cần thiết.
- [ ] Outcome rõ: no-change/refuted hoặc implementation ticket mới; không để proposal treo như bug.
- [ ] Unit/widget/integration/device/golden/interruption/network/memory/profile/frame-jank N/A ở discovery vì không đổi behavior/API; IAP ngoài SDK scope. Nếu mở implementation ticket, ghi test matrix liên quan tại ticket đó.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T282 như product/API discovery; không bắt đầu code. Đọc `lib/src/adapters/gma_bridge.dart`, `lib/src/adapters/admob_adapter.dart`, `lib/src/state/ad_event.dart`, `lib/src/monetization/ad_diagnostics.dart`, `test/privacy_safe_diagnostics_test.dart`, README và `lib/applovin_admob_sdk.dart`. Tìm partner case cụ thể và thử giải bằng `AdManager.events`, `AdManager.diagnostics()` và `AdDiagnostics.toSafeJsonString()` trước. Xác minh ResponseInfo trả field nào trên success/no-fill theo tài liệu Google/version hiện dùng; đánh giá privacy, retention và API stability. Nếu không có demand/gap rõ, ghi refuted/no-change và đóng, không tạo API. Nếu có, viết implementation ticket tách biệt; không triển khai trong T282. Independent review kết luận và chấm /10; không yêu cầu unit/widget/integration/device/golden/perf tests khi không có code change—ghi N/A có lý do; IAP ngoài SDK. Không push proposal.
```
