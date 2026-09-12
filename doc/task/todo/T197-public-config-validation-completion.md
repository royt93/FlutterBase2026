# T197 — Runtime validation cho public config knobs (FIX)
Priority P2 · Status todo · Sources `fill_rate_monitor.dart:38-81`, `fill_rate_baseline_monitor.dart`, `bypass_audit_trail.dart:75-83`.

Window <=0, threshold ngoài [0,1], maxEntries<=0 chỉ assert/không validate; release có monitor vô dụng hoặc lỗi runtime. Khuyến nghị ArgumentError runtime (clamp là option resilient nhưng che lỗi; giữ assert không đủ).

Tests: unit boundary/negative/release; widget config form; integration bad config; debug/release device smoke.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 mới commit+push.
