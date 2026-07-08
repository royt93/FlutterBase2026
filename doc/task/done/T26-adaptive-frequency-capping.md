# T26 — Adaptive frequency capping (on-device, cao rủi ro nhất trong epic "Trust & Analytics")

- **REQ:** 7 (policy tuân thủ, tối ưu fill/yield) + epic "Trust & Analytics"
- **Priority:** P3 · **Severity:** — (feature mới, mang tính thử nghiệm) · **Status:** done
- **Nguồn:** quyết định user 2026-07-08
- **Phụ thuộc:** nên làm SAU CÙNG trong epic (sau T23-T25) — cần `AdEventLog` (T23) làm nguồn dữ liệu instrumentation trước khi bật logic điều chỉnh thật.
- **Files dự kiến:** `packages/ad_sdk/lib/src/adaptive/adaptive_frequency.dart` (mới), `packages/ad_sdk/lib/src/core/ad_safety_config.dart` (hook điểm áp soft-cap, KHÔNG đổi hard-cap `AdSafetyParams`)

## Vấn đề (Why)

Cap hiện tại (`maxFullscreenAdsPerDay`/`PerHour`) là **hằng số cố định cho mọi user** — không phân biệt user chịu được tần suất ad cao (ít churn) với user nhạy cảm (dễ bỏ app nếu thấy ad dày). Một số ad SDK lớn (AppLovin MAX tự thân, các mediation lớn) có yield-optimization tự học theo user; SDK lightweight hiện tại chưa có.

## ⚠️ Cảnh báo rủi ro — đọc trước khi làm

Đây là task **rủi ro/effort cao nhất** trong epic, và **không có backend/telemetry tổng hợp** để validate hiệu quả thật (đúng constraint "không server" xuyên suốt SDK này). Tín hiệu "user có khó chịu vì ad không" mà SDK tự thân có được rất hạn chế (không có quyền truy cập signal retention/LTV thật — cái đó nằm ở host app, không phải SDK). Vì vậy:

- **Phase 1 (bắt buộc trước, scope của lần review đầu):** CHỈ đo lường, KHÔNG điều chỉnh cap thật. Ghi lại 2 tín hiệu proxy rẻ tiền SDK tự có: (a) session length trước khi app bị background ngay sau 1 fullscreen ad, (b) khoảng cách tới lần mở app kế tiếp (`AdSafetyConfig` đã có `_sessionStartTime`/`recordAppWentBackground` — tái dùng, không viết lại). Xuất ra qua `AdEventLog` (T23) để partner tự xem, KHÔNG tự động thay đổi hành vi ad.
- **Phase 2 (chỉ làm nếu Phase 1 cho thấy tín hiệu proxy đủ ổn định qua ít nhất vài tuần dữ liệu thật — quyết định lại lúc đó, không cam kết trước):** dùng tín hiệu Phase 1 để điều chỉnh 1 "soft cap" nằm DƯỚI hard cap hiện có (`AdSafetyParams` vẫn luôn là trần tuyệt đối, không đổi) — ví dụ giảm soft cap 1 bậc nếu tín hiệu proxy cho thấy user vừa rời app bất thường nhanh sau ad gần nhất.

**Task file này chỉ đặc tả Phase 1.** Không thiết kế thuật toán bandit/ML cụ thể trước khi có dữ liệu Phase 1 — tránh over-engineer 1 hệ thống tối ưu cho dữ liệu chưa biết có tồn tại pattern hay không.

## Fix đề xuất (Phase 1 — instrumentation only)

1. `AdaptiveFrequencySignals` — record 2 proxy tại đúng điểm `AdSafetyConfig` đã track (không thêm lifecycle hook mới): thời điểm background sau fullscreen ad gần nhất, thời điểm resume kế tiếp.
2. Ghi vào `AdEventLog` (T23) dưới dạng entry riêng (không phải `AdEvent` — đây là tín hiệu nội bộ diagnostic, không phải sự kiện ad).
3. KHÔNG expose API điều chỉnh cap nào ở Phase 1 — chỉ export xem được qua compliance/diagnostic report của T23.

## Acceptance criteria (Phase 1)
- [x] Ghi đúng 2 proxy signal, không ảnh hưởng bất kỳ hành vi cap/show/load hiện tại (test: bật instrumentation, verify `canShowFullscreenAd()`/`loadX()` behavior y hệt trước khi có T26).
- [x] Không thêm bất kỳ điều chỉnh cap tự động nào ở Phase 1 (rà lại code review, không chỉ test).
- [x] Test mới verify signal ghi đúng thời điểm cho vài kịch bản resume/background giả lập.
- [x] `flutter analyze` sạch, test SDK xanh.
- [x] Ghi rõ trong `doc/feature.md`/`doc/task/README.md`: Phase 2 chưa scope, chờ dữ liệu Phase 1.

## Kết quả

Implement `AdaptiveFrequencySignals` (`packages/ad_sdk/lib/src/adaptive/adaptive_frequency.dart`)
— static in-memory buffer (cap 500 entries), ghi đúng 2 proxy signal
(`ad_to_background`, `background_to_resume`) tại 2 điểm hook có sẵn của
`AdSafetyConfig` (`recordAppWentBackground()`, `canShowAppOpenOnResume()`) —
không thêm lifecycle hook mới. Sink-injection pattern giống T25
(`_anomalySink`): `AdaptiveFrequencySignals.setSink()` nối qua
`AdEventLog.recordAdaptiveSignal()`, wire trong `AdManager.initialize()`.
Reset dọn theo `AdSafetyConfig.resetForReinit()`. Không export qua barrel
file (`applovin_admob_sdk.dart`) — không có API public điều chỉnh cap nào,
đúng yêu cầu Phase 1 chỉ diagnostic. `AdEventLog`/`compliance_report.dart`
không cần sửa gì thêm vì đã generic theo `kind`.

- Test: 7 unit test mới (`packages/ad_sdk/test/adaptive_frequency_test.dart`)
  — không ghi nếu chưa có ad/background trước đó, ghi đúng kind+gap, sink
  nhận đúng thứ tự, gating decision không đổi có/không có sink,
  `resetForReinit()` dọn sạch buffer + sink. Tất cả pass.
- Sweep: `flutter analyze` sạch cả `packages/ad_sdk` và
  `packages/ad_sdk/example`; `flutter test` xanh toàn bộ 2 package.
- Smoke test trên Pixel 7 Pro (`2B051FDH3006MU`): cold start → background →
  resume (2 lần gặp App Open ad che màn hình, đã dừng theo rule R4 và tiếp
  tục sau xác nhận "done") → mở trang Compliance report (T23), bấm "Generate
  report" → xác nhận JSON export có entry
  `{"kind":"adaptive_signal","signalKind":"background_to_resume","gapMs":10547}`
  — instrumentation hoạt động đúng end-to-end trên thiết bị thật, không cap
  nào bị thay đổi, không có regression ở các trang demo khác.
- Phase 2 (thuật toán điều chỉnh soft-cap dựa trên tín hiệu) chưa scope —
  ghi rõ trong `doc/feature.md` và `doc/task/README.md`, chờ dữ liệu thật
  từ Phase 1 trước khi thiết kế.
