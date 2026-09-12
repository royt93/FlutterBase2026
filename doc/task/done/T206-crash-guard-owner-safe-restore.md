# T206 — Crash guard owner-safe và reversible (FIX)
Priority P0 · Status done · Source audit Codex: `lib/src/core/ad_crash_guard.dart`, `lib/src/core/ad_manager.dart:6002`.

SDK không nên giữ global Flutter/platform error handler sau destroy hoặc ghi đè handler host. Khuyến nghị token ownership, chain handler cũ và restore khi session cuối kết thúc; option chỉ đặt handler một lần không xử lý re-init.

Tests: unit install/restore/nested owner; widget uncaught-error path; integration destroy→reinit; Android+iOS device smoke với handler của host.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 mới commit+push.

## Completion (2026-09-12)

Implemented owner-aware `uninstallAdCrashGuard()`, restore-on-destroy only while handlers remain SDK-owned, and re-install ownership tracking on initialize. Added unit/widget/integration coverage. Full suite: 1,900 tests pass; Android device smoke passes on SM S928B; analyzer has no errors (one pre-existing info). Audit score: 9.4/10. iOS device unavailable.
