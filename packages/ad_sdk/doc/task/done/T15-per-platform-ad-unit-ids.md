# T15 — Ad-unit-id tách theo platform (Android/iOS)

- **REQ:** 1 (work Android + iOS)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** done
- **Files:** `config/ad_config.dart` (`AdMobConfig` `:88-105`, `AppLovinConfig`), `adapters/*` đọc id, host `main.dart`

## Vấn đề (Why)
`AdMobConfig`/`AppLovinConfig` chỉ 1 id/slot, **không phân biệt Android/iOS**. Production hầu như luôn cần ad unit id khác nhau theo platform; hiện host phải tự tách trước khi gọi `initialize()`.

## Acceptance criteria
- [x] Config hỗ trợ id theo platform: hoặc field `androidBannerId`/`iosBannerId`… hoặc factory `AdMobConfig.perPlatform(android:..., ios:...)`.
- [x] Adapter chọn id theo `Platform.isAndroid/isIOS` tại init.
- [x] Tương thích ngược: nếu chỉ truyền 1 id, dùng cho cả 2 platform (không breaking).
- [x] Ví dụ trong README + `example/`.

## Test
- [x] Unit: resolve id đúng theo platform (mock Platform).

## Kết quả (implementation notes)
- `AppLovinConfig`/`AdMobConfig` giữ nguyên constructor params cũ (`bannerId`,
  `interstitialId`, `appOpenId`, `rewardedId`) nhưng nay backing bằng private
  field; public getter cùng tên resolve qua `Platform.isAndroid`/`isIOS` với
  optional `android*Id`/`ios*Id` override (empty string coi như không có).
- Logic dùng chung qua top-level `@visibleForTesting` function
  `resolvePlatformAdUnitId` trong `config/ad_config.dart` — test trực tiếp
  bool `isAndroid`/`isIos` không cần mock `dart:io`.
- Adapter không cần sửa: chúng đọc qua getter cùng tên cũ (verified bằng grep).
- Test: `test/ad_config_platform_test.dart` (4 case). `flutter analyze`: 0
  issues. `flutter test`: 294/294 pass.
