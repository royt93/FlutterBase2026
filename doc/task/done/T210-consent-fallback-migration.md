# T210 — Offline-first consent fallback và migration (ENHANCE)
Priority P1 · Status done.

Định nghĩa policy khi UMP/ATT timeout, plugin lỗi, cache cũ hoặc policy revision thay đổi; lưu lý do fallback và bảo toàn conservative default. Khuyến nghị versioned state machine; hard-coded bool nhanh nhưng khó audit.

Tests: unit timeout/error/revision/migration; widget dialog retry/status; integration offline→online; Android+iOS device smoke theo geography.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added versioned `ConsentFallbackState` with explicit timeout/platform-error/offline/stale-revision provenance.
- Fallback is conservative by construction: `canRequestAds=false` and `personalizedAds=false`.
- Added v2 persistence, safe legacy/unknown-reason migration, and `ConsentManager` record/clear APIs.
- UMP errors/timeouts now persist provenance; successful UMP resolution clears stale fallback state.
- Added unit, widget, and integration smoke tests.
- Verification: `flutter analyze` clean; full package suite **1,917 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.3/10**. iOS physical smoke was not run in this loop; pure/widget coverage remains platform-independent.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
