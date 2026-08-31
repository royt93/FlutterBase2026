# T106 — Enhancement: Bootstrap API 1 hàm gom ATT→UMP→initialize→splash

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (example wiring deferred — xem ghi chú)
- **Files:** `lib/src/core/ad_bootstrap.dart` (mới), `lib/applovin_admob_sdk.dart`, `README.md`, test `test/ad_bootstrap_test.dart` (mới)

## Vấn đề

Flow khuyến nghị hiện buộc host tự xâu chuỗi ATT, UMP, fallback consent, initialize và splash timeout. Example dài và dễ copy thiếu 1 bước dù SDK đã có đủ primitive. [đồng thuận 3 nguồn]

## Việc đã làm

- [x] `bootstrap(AdBootstrapOptions)` (lib/src/core/ad_bootstrap.dart) → `AdBootstrapResult { att, ump, initSuccess, gaid }`. Sequence: `requestAtt()` (skip được qua `requestAtt: false`) → `requestUmpConsent(...)` → `AdManager().initialize(...)` (callback `onComplete` được bọc thành `Future` qua `Completer`)
- [x] Không breaking — API thấp tầng (`AdManager().requestAtt/requestUmpConsent/initialize`) giữ nguyên, `bootstrap()` chỉ gọi lại chúng theo đúng thứ tự đã document. `AdReadinessSplashController` cũng không đổi — `bootstrap()` chỉ phủ đoạn consent-then-init, không đụng splash UI/App-Open display (đã ghi rõ trong doc comment + README)
- [x] README: thêm 1 "Shortcut (T106)" callout ngay cạnh callout `AdReadinessSplashController` sẵn có, kèm 1 snippet ngắn — KHÔNG viết lại toàn bộ section splash (xem ghi chú)
- [x] Test (`test/ad_bootstrap_test.dart`, 3 test): `debugRequestAtt`/`debugRequestUmp` override (không có real ATT/UMP platform channel trong `flutter test`) + `AdManager.debugAdapterFactory` trỏ vào `FakeAdProviderAdapter` con (`_OrderRecordingAdapter`, ghi lại thời điểm `initialize()` thật sự chạy) — xác nhận thứ tự `['att','ump','init']` đúng qua **initialize() thật**, không phải chuỗi giả lập. Full suite 1410→1413, không regression

## Ghi chú

- KHÔNG động vào `example/lib/main.dart` (T117 sẽ tách file này ngay sau) — tránh 2 lần rewrite cùng 1 file trong cùng batch. Ví dụ dùng `bootstrap()` nằm trong README snippet, chưa nằm trong `example/`.
- `bootstrap()` chỉ tuần tự hoá lời gọi — KHÔNG tự gate `initialize()` theo kết quả UMP (host tự quyết định dựa trên `AdBootstrapResult.ump.canRequestAds` nếu cần chặn). Test thứ 3 khẳng định rõ điều này.
- Production dùng `bootstrap()` với `AdConfig.autoRequestUmpConsent` mặc định `true` vẫn AN TOÀN (không gọi UMP 2 lần) — vì `bootstrap()` gọi `AdManager().requestUmpConsent()` thật trước, nên `initialize()`'s internal skip-if-already-requested tự động nhận biết. Test phải tắt `autoRequestUmpConsent` vì override `debugRequestUmp` cố tình bỏ qua `AdManager` nên internal state đó không được set.
