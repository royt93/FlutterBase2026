# T204 — Redact identifier/entitlement secrets khỏi log (FIX/SECURITY)
Priority P0 · Status todo · Source audit Codex: `ad_manager.dart:2603`, `applovin_adapter.dart:723`, `vip_manager.dart:1134`, `safe_logger.dart:100`.

Raw GAID/IDFA, test-device hash hoặc VIP key/code có thể đi vào log sink ngoài. Khuyến nghị centralized redaction (hash/truncate theo field policy), default deny secret fields; option chỉ giảm log level không đủ vì sink vẫn nhận dữ liệu.

Tests: unit logger capture với từng secret/format; widget debug panel không hiển thị raw; integration configured sink; Android+iOS device smoke ở debug/release và CI log scan.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 mới commit+push, nếu không loop.
