# T216 — Revenue anomaly detector (NEW)
Priority P2 · Status done.

Phát hiện eCPM=0 bất thường, revenue spike, currency mismatch, duplicate impression và request-id collision; bản đầu chỉ cảnh báo, không tự đổi monetization. Khuyến nghị robust median/MAD với minimum samples; threshold tĩnh dễ false-positive.

Tests: unit anomalies/normalization/currency; widget diagnostics panel; integration event replay; device smoke offline persistence và alert throttling.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added observe-only `RevenueAnomalyDetector` using robust median/MAD baseline and minimum-sample guard.
- Detects zero-eCPM events, spikes, mixed currencies, duplicate impressions, and cross-context request-id collisions without changing monetization decisions.
- Exposed `AdManager.revenueAnomalies()` for persisted event replay and host diagnostics.
- Added unit coverage for normal/insufficient samples, all anomaly classes, and invalid configuration; widget warning rendering; Android integration replay smoke.
- Verification: `flutter analyze` clean; full package suite **1,936 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.2/10**. Request-id population in provider adapters remains tracked by T185; detector safely handles absent IDs.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
