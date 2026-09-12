# T216 — Revenue anomaly detector (NEW)
Priority P2 · Status todo.

Phát hiện eCPM=0 bất thường, revenue spike, currency mismatch, duplicate impression và request-id collision; bản đầu chỉ cảnh báo, không tự đổi monetization. Khuyến nghị robust median/MAD với minimum samples; threshold tĩnh dễ false-positive.

Tests: unit anomalies/normalization/currency; widget diagnostics panel; integration event replay; device smoke offline persistence và alert throttling.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
