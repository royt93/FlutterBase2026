# T232 — Tính năng độc quyền: Trọng tài eCPM thời gian thực không gửi request ngầm

- **Loại:** Flagship (Độc quyền)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ❌ REFUTED (không code — trùng lặp hạ tầng đã có, xem bảng so sánh)

## Vấn đề (Why)

Chính sách của AdMob và AppLovin cấm gửi request quảng cáo ngầm (shadow request) khi không có ý định hiển thị. Làm sao để chọn nhà mạng có doanh thu cao nhất cho phiên kế tiếp mà không vi phạm chính sách?

## Đề xuất giải pháp gốc

`ZeroDropYieldArbitrator` kết hợp `FillRateBaselineMonitor` + `CohortOptimizer`, dùng Multi-Armed Bandit (Thompson Sampling/Epsilon-Greedy) thuần offline trên thống kê eCPM theo khung giờ/quốc gia, chọn provider tốt hơn cho phiên KẾ TIẾP, zero shadow request, claim tăng 15-25% doanh thu ròng.

## Điều tra (bắt buộc trước khi code) — đã đọc IN FULL

- `doc/task/done/T90-ab-testing-provider-splitter.md`, `T93-deterministic-ab-bucketing-helper.md`, `T97-client-side-fill-rate-regression-detector.md`, `T136-waterfall-tuner-self-healing-on-device.md`, `T143-zero-shadow-dual-provider-failover.md`, `T146-privacy-safe-cohort-optimizer.md`
- `lib/src/monetization/fill_rate_baseline_monitor.dart`, `cohort_optimizer.dart`, `waterfall_tuner.dart`, `provider_failover_advisor.dart`, `self_healing_observer.dart`
- `AdManager.pickProviderCohort`/`pickSessionProvider`/`experimentBucket`/`applyProviderFailover`/`enableWaterfallTuner`/`enableProviderFailoverAdvisor` trong `lib/src/core/ad_manager.dart`

## Bảng so sánh — claim của ticket vs. cái đã tồn tại

| Claim của T232 | Đã có ở đâu | Ghi chú |
|---|---|---|
| Chọn provider eCPM cao hơn cho phiên/install KẾ TIẾP, hoàn toàn on-device | `CohortOptimizer.recommendedProviderForNextInit()` (T146) | So trung bình eCPM ký Ed25519, verify offline, trả `null` khi thiếu dữ liệu (`minSessionsPerProvider=3`) |
| So sánh fill-rate × eCPM per (provider, format, placement), khuyến nghị đổi provider phiên sau | `WaterfallTuner.recommendation()` (T136) | Đã có ngưỡng `minSampleSize=6` cả 2 phía (load lẫn revenue), đã qua 3+ vòng audit sửa race/TOCTOU |
| Zero shadow/parallel ad request — mọi điểm số chỉ từ event thật | Cả `WaterfallTuner` VÀ `CohortOptimizer` | Doc comment `WaterfallTuner` dòng 42-44 ghi rõ: "No shadow ad is ever requested for the non-active provider" |
| Explore/exploit thật (epsilon-greedy) giữa 2 provider bằng phiên THẬT (không giả lập) | `AdManager.pickSessionProvider(explorationRate: ...)` (T136) | Đây CHÍNH LÀ epsilon-greedy: xác suất `explorationRate` mỗi phiên chạy provider thay thế bằng ad request thật (không phải shadow), có rate-limit `minIntervalBetweenExplorations`, tự động skip phiên VIP |
| Cơ chế dự phòng khi provider hiện tại fail liên tục | `ProviderFailoverAdvisor` + `AdManager.applyProviderFailover()` (T143) | Circuit breaker có half-open probe, độc lập khỏi tín hiệu eCPM (tín hiệu reliability riêng) |
| Baseline fill-rate/eCPM 7 ngày on-device để phát hiện regression | `FillRateBaselineMonitor` (T97) | Đã opt-in, đã persist, đã audit nhiều vòng |
| Multi-Armed Bandit "thật" (Thompson Sampling / Bayesian posterior) thay vì so trung bình đơn giản | **KHÔNG có, và KHÔNG nên build** | Xem phần "Vì sao không build phần Thompson Sampling" bên dưới |
| Phân khúc theo khung giờ (time-of-day) + quốc gia | **KHÔNG có** | Xem phần dưới — lý do kỹ thuật thật, không phải bỏ sót |

## Vì sao không build phần "mới" duy nhất còn lại

1. **Thompson Sampling/Bayesian bandit thay so-sánh-trung-bình hiện tại:** `CohortOptimizer` cần tối thiểu 3 session/provider, `WaterfallTuner` cần tối thiểu 6 mẫu/phía để tin một so sánh. Ở cỡ mẫu n=3-6 trên MỘT thiết bị, một posterior Bayesian không cho quyết định ổn định hơn so sánh trung bình đơn giản đang chạy — độ phức tạp thêm vào (ước lượng phân phối, cập nhật alpha/beta hay Gaussian theo mỗi request) không đổi lại được lợi ích thống kê thật nào ở cỡ mẫu này. Thay code đã qua audit nhiều vòng (WaterfallTuner: 4 vòng, ProviderFailoverAdvisor, CohortOptimizer) bằng thuật toán phức tạp hơn để giải quyết vấn đề không tồn tại vi phạm thẳng nguyên tắc YAGN mà backlog này đã nhấn mạnh.

2. **Phân khúc theo khung giờ/quốc gia:** dữ liệu vốn đã thưa (per-device, per-provider) — chia nhỏ thêm theo giờ (24 bucket) × quốc gia sẽ làm ngưỡng "đủ mẫu để tin" (`minSampleSize`/`minSessionsPerProvider`) gần như KHÔNG BAO GIỜ đạt được trên một thiết bị thật trong vòng đời hợp lý, đi ngược lại chính mục tiêu ticket (chọn provider tốt hơn thực tế). Quốc gia của một install gần như không đổi (không có gì để "phân khúc" cho chính thiết bị đó). Đây không phải thiếu sót — đây là giới hạn thống kê thật của kiến trúc on-device-only đã được thừa nhận rõ ở T146 ("Effort XL vì cần thiết kế cẩn thận ngưỡng đủ dữ liệu để tin").

3. **Claim "15-25% net revenue uplift":** không phải acceptance criterion kiểm chứng được — không có cách đo trên chính SDK này (không backend, không aggregate cross-install). Ngôn ngữ marketing, không phải spec.

4. **Kiến trúc single-provider-per-install (T143):** bất kỳ hình thức "arbitrator thời gian thực" nào ngụ ý so sánh 2 luồng quảng cáo sống song song đều đụng đúng giới hạn T143 đã ghi nhận và owner đã chấp nhận scope nhỏ hơn (session-based, không runtime dual-adapter). T232 không đưa ra yêu cầu mới nào vượt qua giới hạn đó.

## Kết luận

Toàn bộ hành vi vận hành ticket yêu cầu — "chọn provider eCPM cao hơn cho phiên/install kế tiếp, thuần on-device, epsilon-greedy explore/exploit bằng phiên thật, zero shadow request, có baseline regression detection, có failover khi fail liên tục" — **đã tồn tại end-to-end** qua `CohortOptimizer` (T146) + `WaterfallTuner` (T136) + `AdManager.pickSessionProvider` (epsilon-greedy thật) + `ProviderFailoverAdvisor` (T143) + `FillRateBaselineMonitor` (T97). Phần duy nhất còn lại trong ticket (Thompson Sampling thật, phân khúc giờ/quốc gia) không phải một cải tiến nhỏ, cô lập, có giá trị thống kê thật ở cỡ mẫu on-device hiện có — build nó chỉ để có thuật ngữ "Multi-Armed Bandit" là gồng ép code không cần thiết.

**Verdict: REFUTED.** Không có thay đổi code. Không hành vi mới nào được thêm → không cần unit/widget/integration test mới hay device build mới (verify test/build trùng lặp trên hành vi không đổi không chứng minh được gì thêm).

## Verify đã chạy (không sinh test mới vì không có hành vi mới)

- `flutter analyze`: sạch (không sửa file nào).
- Test file liên quan trực tiếp đã chạy lại để xác nhận baseline vẫn xanh trước khi đóng ticket: `test/waterfall_tuner_test.dart`, `test/cohort_optimizer_test.dart`, `test/provider_failover_advisor_test.dart`, `test/fill_rate_baseline_monitor_test.dart`, `test/ad_manager_fill_rate_baseline_test.dart` — **All tests passed!** (57 test case cuối cùng trong file cuối, không lỗi).
- Không chạy widget/integration test hay build device riêng cho ticket này — không có hành vi mới để chứng minh; `WaterfallTuner`/`ProviderFailoverAdvisor`/`CohortOptimizer` đã có smoke-test thật trên device ở chính các round T136/T143/T146 khi chúng được xây (xem done-file tương ứng). Thiết bị Tecno KJ7 (`115333744A005844`) xác nhận có kết nối qua `adb devices` (trong 30s cap) cho lần build device chung kế tiếp sau khi nhánh T231 merge — không cần build riêng cho một ticket REFUTED, không-đổi-code.
