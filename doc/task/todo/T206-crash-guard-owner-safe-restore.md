# T206 — Crash guard owner-safe và reversible (FIX)
Priority P0 · Status todo · Source audit Codex: `lib/src/core/ad_crash_guard.dart`, `lib/src/core/ad_manager.dart:6002`.

SDK không nên giữ global Flutter/platform error handler sau destroy hoặc ghi đè handler host. Khuyến nghị token ownership, chain handler cũ và restore khi session cuối kết thúc; option chỉ đặt handler một lần không xử lý re-init.

Tests: unit install/restore/nested owner; widget uncaught-error path; integration destroy→reinit; Android+iOS device smoke với handler của host.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 mới commit+push.
