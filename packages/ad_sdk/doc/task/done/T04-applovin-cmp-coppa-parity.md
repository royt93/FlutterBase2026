# T04 — AppLovin CMP + tín hiệu COPPA parity

- **REQ:** 6 (apply chuẩn AppLovin)
- **Priority:** P1 · **Severity:** HIGH · **Status:** done
- **Files:** `core/ad_consent.dart`, `core/ad_manager.dart` (`:662-679`), `adapters/applovin_adapter.dart` (`:125`), `config/ad_config.dart` (`:132`, `:287`)

## Vấn đề (Why)
`applyConsentToProviders` cho AppLovin chỉ gọi `setHasUserConsent` + `setDoNotSell`. **Không** dùng AppLovin CMP/Terms & Privacy Flow, **không** set cờ age-restricted (comment ghi 4.x bỏ `setIsAgeRestrictedUser` nhưng không thay thế) ⇒ nếu app child-directed, AppLovin **không được báo**.

## Acceptance criteria
- [x] Nếu AppLovin là provider ở EEA: dùng AppLovin CMP flow (hoặc đồng bộ consent từ UMP sang AppLovin), tránh double-prompt với UMP.
  - `AdConfig.disableAppLovinCmpFlow` mặc định `true` (`ad_config.dart:132`) → `AppLovinAdapter.initialize` skip AppLovin's own Terms & Privacy Flow khi UMP là consent source (`applovin_adapter.dart:125`).
  - Footgun warning chủ động ở `ad_manager.dart:662-679`: nếu `disableAppLovinCmpFlow=true` **và** app chưa gọi `requestUmpConsent()`/UMP status vẫn `unknown`, log cảnh báo lớn "no consent flow ran at all" — tránh trường hợp tắt cả 2 CMP.
  - Test: `applovin_adapter_test.dart` — mặc định tắt AppLovin CMP; `disableAppLovinCmpFlow:false` giữ AppLovin CMP bật.
- [x] Tín hiệu child-directed/age-restricted được forward tới AppLovin bằng API hiện hành (kiểm tra `applovin_max` version), hoặc tài liệu hoá rõ COPPA chỉ delegate AdMob (kèm cảnh báo split-provider).
  - Xác nhận `applovin_max` 4.6.4 **không có** `setIsAgeRestrictedUser` API → chọn hướng "tài liệu hoá rõ giới hạn": `applyConsentToProviders` log `SafeLogger.w('AdConsent', ...)` mỗi khi `isAgeRestrictedUser=true`, nêu rõ AdMob vẫn nhận qua `tagForChildDirectedTreatment` còn AppLovin thì không, và hướng dẫn dùng AppLovin dashboard-level child-directed setting thay thế.
- [x] Không còn khoảng trống: khi `isAgeRestrictedUser=true`, cả AdMob và AppLovin đều nhận tín hiệu phù hợp (hoặc doc rõ giới hạn).
  - AdMob nhận qua `tagForChildDirectedTreatment` (đã có sẵn, test cũ). AppLovin không có API tương đương → giới hạn được document loudly (không silent), khớp acceptance criteria phần "(hoặc doc rõ giới hạn)".

## Ghi chú kỹ thuật
- Xác minh API AppLovin SDK đang dùng (CMP existing/new user, cờ privacy). Liên quan T01 (nguồn consent) & T05 (tách cờ) — cả 2 đều done.
- Kết luận: `applovin_max` 4.x chưa expose COPPA API tương đương `setIsAgeRestrictedUser`; approach "loud warning + doc" là lựa chọn đúng cho tới khi AppLovin bổ sung API (theo dõi CHANGELOG của `applovin_max` khi bump version).

## Test
- [x] Unit: `age-restricted=true` → verify cảnh báo COPPA-gap được log đúng tag/nội dung (`ad_consent_test.dart`, group "applyConsentToProviders (T04 — COPPA documented-limitation warning)", 2 test case: warning fires khi `true`, không fire khi `false`).
- [x] `flutter analyze` sạch, `flutter test` — 261/261 xanh (full suite, không regression).
