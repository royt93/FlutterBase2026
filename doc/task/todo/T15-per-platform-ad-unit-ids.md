# T15 — Ad-unit-id tách theo platform (Android/iOS)

- **REQ:** 1 (work Android + iOS)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** todo
- **Files:** `config/ad_config.dart` (`AdMobConfig` `:88-105`, `AppLovinConfig`), `adapters/*` đọc id, host `main.dart`

## Vấn đề (Why)
`AdMobConfig`/`AppLovinConfig` chỉ 1 id/slot, **không phân biệt Android/iOS**. Production hầu như luôn cần ad unit id khác nhau theo platform; hiện host phải tự tách trước khi gọi `initialize()`.

## Acceptance criteria
- [ ] Config hỗ trợ id theo platform: hoặc field `androidBannerId`/`iosBannerId`… hoặc factory `AdMobConfig.perPlatform(android:..., ios:...)`.
- [ ] Adapter chọn id theo `Platform.isAndroid/isIOS` tại init.
- [ ] Tương thích ngược: nếu chỉ truyền 1 id, dùng cho cả 2 platform (không breaking).
- [ ] Ví dụ trong README + `example/`.

## Test
- [ ] Unit: resolve id đúng theo platform (mock Platform).
