# T256 — Theo dõi migration sang AdMob ageRestrictedTreatment

- **Loại:** Compatibility follow-up
- **Priority:** P3 · **Effort:** M
- **Confidence:** FOLLOW-UP explicitly noted in repo guidance; not current failure
- **Status:** implementation + static/build gates complete; physical-device consent smoke remains before closure
- **Evidence:** `CLAUDE.md` pinning notes; `lib/src/adapters/admob_adapter.dart` legacy child/under-age flags; `lib/src/adapters/gma_bridge.dart`; `pubspec.yaml` Google Mobile Ads pin/comment; `test/admob_adapter_test.dart`, consent tests; 2026-11-06 pub.dev `google_mobile_ads` 9.1/9.2 changelog/API docs and `gma_mediation_applovin` 2.6.5 metadata
- **Dependency:** upstream API/deprecation status; consuming-app CocoaPods/pinning-wall validation

## Giá trị

SDK đang dùng cặp legacy `tagForChildDirectedTreatment` / `tagForUnderAgeOfConsent`. Hướng dẫn repo ghi rõ migration sang `RequestConfiguration.ageRestrictedTreatment` là follow-up, legacy pair vẫn được hỗ trợ trong giai đoạn hiện tại và Google dependency không được bump tùy tiện vì pinning/build regression. Theo dõi chính sách/API trước khi sửa để tránh migration sớm gây lệch consent semantics.

## Discovery gate và migration evidence (cập nhật 2026-11-06)

- [x] Đã chọn: theo dõi và migrate khi có deprecation/removal trigger hoặc dependency window đã duyệt; không migrate ngay.
- [x] Xác minh trạng thái chính thức của Google API: Google xác nhận cặp legacy `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent` tiếp tục hoạt động qua hết năm 2026; không có kế hoạch gỡ bỏ trước bản release lớn dự kiến H1 2027 (ghi nhận tại Audit round 43).
- Historical note (2026-10-24): `google_mobile_ads 9.0.0` lacked `ageRestrictedTreatment`, and 9.1.0 had an iOS header regression. Both blockers are addressed by the 9.2.0 API/header fix; candidate compatibility and builds are now verified below. Upstream fix: [PR 1516](https://github.com/googleads/googleads-mobile-flutter/pull/1516).
- [x] Candidate fixture check 2026-11-06 (bản copy cô lập tại `/tmp/t256_candidate`, repo không đổi dependency): `flutter pub get` và `pod install --repo-update` resolve `AppLovinSDK 13.6.3`, `GoogleMobileAdsMediationAppLovin 13.6.3.0`, `Google-Mobile-Ads-SDK 13.11.0`, `google_mobile_ads 9.2.0`, `gma_mediation_applovin 2.6.3`, `applovin_max 4.6.4`; `flutter build apk --debug` và `flutter build ios --simulator --debug` pass. Bản copy test runs bị nhiễu vì không có `.git` (5 release-readiness test fail với `fatal: not a git repository`), nên dùng repo git thật để chứng minh suite/gate.
- [x] Implementation 2026-11-06: migrated `GmaBridge`/AdMob initialization and consent re-application to `RequestConfiguration.ageRestrictedTreatment`; either COPPA or TFUA true maps to `child`, otherwise `unspecified`. Legacy public `ConsentSimulationResult` fields retained and deprecated; additive `admobAgeRestrictedTreatment` added. API golden, example diagnostics, changelog updated. Focused mapping/bridge/CCPA-test-device tests passed.
- [x] Repo verification: full `flutter test --reporter=compact` passes 2,846 tests; `flutter analyze lib/ test/ example/lib/` reports no issues; `./tool/release_readiness_gate.sh all` passes; example analyzer/widget tests pass; example Android debug APK and iOS simulator debug builds pass. Tracked pinning fixture lock refreshed; `tool/check_pinning_wall.sh --with-builds` passes in the actual repository, resolving AppLovinSDK 13.6.3 and building Android/iOS simulator.
- [x] Android physical-device smoke (TECNO KJ7, AdMob test IDs, 2026-11-06): TFUA true/false with doNotSell true/false passed; outgoing `ageRestrictedTreatment` and test-device IDs confirmed. UMP geography was `notRequired`; no EEA UMP form shown.
- [x] Android COPPA smoke (TECNO KJ7, AdMob test IDs, 2026-11-06): `COPPA forwards child age treatment to native Android` passed; outgoing `ageRestrictedTreatment=child` and effective test-device IDs confirmed.
- [ ] Remaining device coverage: iOS physical-device smoke and EEA/debug-geography UMP form. No production ad traffic used.
- Final analyzer after migration reports no issues. Keep T256 open until remaining device coverage is complete.

## Acceptance criteria

- [x] Mapping được xác nhận theo Google API: COPPA true hoặc TFUA true => `child`; không cờ nào => `unspecified`; không phát sinh teen signal.
- [x] Regression tests cho cả 4 tổ hợp COPPA × TFUA; bridge serialization, consent re-apply và test-device retention tests pass.
- [x] Public compatibility giữ legacy simulator fields deprecated; thêm enum field; API golden và CHANGELOG cập nhật.
- [x] `flutter pub get`, example `flutter pub get`, CocoaPods resolve; tracked pinning fixture updated; `tool/check_pinning_wall.sh --with-builds`, Android/iOS simulator builds, and repo release gate all pass.
- [x] SDK full suite: 2,846 pass; analyzer no issues; example analyzer and widget tests pass; example Android/iOS simulator builds pass.
- [x] Android physical-device smoke (TECNO KJ7, AdMob test IDs, 2026-11-06): TFUA true/false with doNotSell true/false passed; outgoing `ageRestrictedTreatment` and test-device IDs confirmed. UMP geography was `notRequired`; no EEA UMP form shown.
- [x] Android COPPA smoke (TECNO KJ7, AdMob test IDs, 2026-11-06): `COPPA forwards child age treatment to native Android` passed; outgoing `ageRestrictedTreatment=child` and effective test-device IDs confirmed.
- [ ] Remaining device coverage: iOS physical-device smoke and EEA/debug-geography UMP form. No production ad traffic used.

T256 remains in progress until the device smoke is done; no release/publish approval is implied.

## Prompt vòng lặp

Không implement T256 trước discovery gate. Đọc current `pubspec.yaml` comments, root/package CLAUDE, adapter/bridge và upstream API docs; không đoán ngày deprecation hay nâng dependency. Nếu timing chưa phù hợp, kết luận deferred. Nếu được xác nhận, viết tests đỏ cho mapping consent/COPPA trên cả provider/platform trước, chạy pinning wall và build thật theo policy. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke device Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.