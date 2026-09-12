# T209 — Privacy-safe diagnostics export (ENHANCE)
Priority P1 · Status done · Depends on T200/T204.

Xuất diagnostics cần schema/version, bounded size, checksum và redact identifier/entitlement secrets. Khuyến nghị shared redaction registry với logger; option per-caller redact dễ lệch policy.

Tests: unit schema/size/redaction/corruption; widget export/share UI; integration import/verify; Android+iOS device smoke + CI secret scan.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added `AdManager.exportSafeDiagnostics()` and `AdDiagnostics.toSafeJsonString()`.
- Export is schema-versioned, SHA-256 checksummed, UTF-8 bounded, and deterministic when truncating large waterfalls.
- Shared identifier/credential redaction is now reused by `SafeLogger` and diagnostics export; preferences, raw event metadata, and secrets are excluded.
- Added unit coverage for redaction/checksum/tamper detection/size bounds, widget coverage for rendering, and Android integration smoke coverage.
- Verification: `flutter analyze` clean; full package suite **1,913 passed**; Android device `SM S928B` integration smoke passed.
- Audit score: **9.4/10**. iOS physical smoke was not run in this loop; Android proof and cross-platform pure/widget tests pass.
- End-loop signal satisfied: audit + score, unit/widget/integration tests, device smoke. Commit and push authorized because score is above 9/10.
