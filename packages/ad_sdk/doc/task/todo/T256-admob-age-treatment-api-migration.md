# T256 — Theo dõi migration sang AdMob ageRestrictedTreatment

- **Loại:** Compatibility follow-up
- **Priority:** P3 · **Effort:** M
- **Confidence:** FOLLOW-UP explicitly noted in repo guidance; not current failure
- **Status:** todo · defer until Google deprecation/removal signal or approved dependency window
- **Evidence:** `CLAUDE.md` pinning notes; `lib/src/adapters/admob_adapter.dart` legacy child/under-age flags; `lib/src/adapters/gma_bridge.dart`; `pubspec.yaml` Google Mobile Ads pin/comment; `test/admob_adapter_test.dart`, consent tests
- **Dependency:** upstream API/deprecation status; consuming-app CocoaPods/pinning-wall validation

## Giá trị

SDK đang dùng cặp legacy `tagForChildDirectedTreatment` / `tagForUnderAgeOfConsent`. Hướng dẫn repo ghi rõ migration sang `RequestConfiguration.ageRestrictedTreatment` là follow-up, legacy pair vẫn được hỗ trợ trong giai đoạn hiện tại và Google dependency không được bump tùy tiện vì pinning/build regression. Theo dõi chính sách/API trước khi sửa để tránh migration sớm gây lệch consent semantics.

## Discovery gate (Xác minh 2026-10-15 & 2026-10-24)

- [x] Đã chọn: theo dõi và migrate khi có deprecation/removal trigger hoặc dependency window đã duyệt; không migrate ngay.
- [x] Xác minh trạng thái chính thức của Google API: Google xác nhận cặp legacy `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent` tiếp tục hoạt động qua hết năm 2026; không có kế hoạch gỡ bỏ trước bản release lớn dự kiến H1 2027 (ghi nhận tại Audit round 43).
- [x] Pinning wall: `google_mobile_ads` được pin cứng `>=9.0.0 <9.1.0` để khớp với `gma_mediation_applovin 2.6.2/2.6.3` (AppLovinSDK 13.6.3) và tránh lỗi build Xcode non-modular-header trên bản 9.1.0. Không bump dependency khi chưa có bản vá upstream.
- [x] Kiểm tra mã nguồn `google_mobile_ads 9.0.0` (2026-10-24): `RequestConfiguration` trong bản 9.0.0 chưa có thuộc tính `ageRestrictedTreatment`; nó chỉ hỗ trợ `tagForChildDirectedTreatment` và `tagForUnderAgeOfConsent`. Do đó việc migrate ở phiên bản hiện tại là bất khả thi về mặt kỹ thuật nếu không nâng dependency.
- [x] Kết luận: Tiếp tục DEFERRED — giữ nguyên cặp legacy, không đổi code, không rủi ro vỡ CocoaPods pinning wall.

## Acceptance criteria nếu qua gate

N/A — discovery gate xác nhận tiếp tục hoãn (deferred); không có code change trong giai đoạn hiện tại.

- [ ] Mapping child-directed/under-age hiện tại sang age-restricted treatment được xác nhận bằng docs/API thật; không làm yếu COPPA/consent behavior.
- [ ] Unit tests mọi tổ hợp consent/age flags; xác nhận không gửi conflicting legacy + new values nếu plugin/native API không cho phép.
- [ ] Widget tests cho host-visible consent state/update paths nếu UI contract thay đổi; nếu adapter-only ghi N/A.
- [ ] Android/iOS integration tests qua bridge/native cho config request thực; kiểm tra platform divergence.
- [ ] Smoke test Android/iOS trên test app, xác nhận init/config và consent path; không dùng production ad IDs.
- [ ] Pinning-wall và build verification chạy theo project policy; API golden/changelog nếu public surface đổi; audit độc lập >9/10.

## Prompt vòng lặp

Không implement T256 trước discovery gate. Đọc current `pubspec.yaml` comments, root/package CLAUDE, adapter/bridge và upstream API docs; không đoán ngày deprecation hay nâng dependency. Nếu timing chưa phù hợp, kết luận deferred. Nếu được xác nhận, viết tests đỏ cho mapping consent/COPPA trên cả provider/platform trước, chạy pinning wall và build thật theo policy. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke device Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.