# T256 — Theo dõi migration sang AdMob ageRestrictedTreatment

- **Loại:** Compatibility follow-up
- **Priority:** P3 · **Effort:** M
- **Confidence:** FOLLOW-UP explicitly noted in repo guidance; not current failure
- **Status:** todo · defer until Google deprecation/removal signal or approved dependency window
- **Evidence:** `CLAUDE.md` pinning notes; `lib/src/adapters/admob_adapter.dart` legacy child/under-age flags; `lib/src/adapters/gma_bridge.dart`; `pubspec.yaml` Google Mobile Ads pin/comment; `test/admob_adapter_test.dart`, consent tests
- **Dependency:** upstream API/deprecation status; consuming-app CocoaPods/pinning-wall validation

## Giá trị

SDK đang dùng cặp legacy `tagForChildDirectedTreatment` / `tagForUnderAgeOfConsent`. Hướng dẫn repo ghi rõ migration sang `RequestConfiguration.ageRestrictedTreatment` là follow-up, legacy pair vẫn được hỗ trợ trong giai đoạn hiện tại và Google dependency không được bump tùy tiện vì pinning/build regression. Theo dõi chính sách/API trước khi sửa để tránh migration sớm gây lệch consent semantics.

## Discovery gate

- [ ] Đã chọn: theo dõi và migrate khi có deprecation/removal trigger hoặc dependency window đã duyệt; không migrate ngay.
- [ ] Xác minh trạng thái chính thức của Google API và version đã pin trước khi bắt đầu.
- [ ] Không bump `google_mobile_ads` chỉ để làm task này; phối hợp dependency window và pinning wall.
- [ ] Nếu chưa có deprecation/removal hoặc lợi ích tương thích rõ, để deferred/REFUTED, không tạo code thay đổi.

## Acceptance criteria nếu qua gate

- [ ] Mapping child-directed/under-age hiện tại sang age-restricted treatment được xác nhận bằng docs/API thật; không làm yếu COPPA/consent behavior.
- [ ] Unit tests mọi tổ hợp consent/age flags; xác nhận không gửi conflicting legacy + new values nếu plugin/native API không cho phép.
- [ ] Widget tests cho host-visible consent state/update paths nếu UI contract thay đổi; nếu adapter-only ghi N/A.
- [ ] Android/iOS integration tests qua bridge/native cho config request thực; kiểm tra platform divergence.
- [ ] Smoke test Android/iOS trên test app, xác nhận init/config và consent path; không dùng production ad IDs.
- [ ] Pinning-wall và build verification chạy theo project policy; API golden/changelog nếu public surface đổi; audit độc lập >9/10.

## Prompt vòng lặp

Không implement T256 trước discovery gate. Đọc current `pubspec.yaml` comments, root/package CLAUDE, adapter/bridge và upstream API docs; không đoán ngày deprecation hay nâng dependency. Nếu timing chưa phù hợp, kết luận deferred. Nếu được xác nhận, viết tests đỏ cho mapping consent/COPPA trên cả provider/platform trước, chạy pinning wall và build thật theo policy. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke device Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.