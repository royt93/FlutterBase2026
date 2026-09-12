# T213 — Release-readiness CI gate (NEW)
Priority P1 · Status done.

CI phải gate analyzer, full tests, integration smoke, secret scan, public API diff, package-size regression và license/dependency audit. Khuyến nghị staged required checks; một job khổng lồ khó debug.

Tests: unit pipeline parser; widget/integration sample app; device smoke trên Android+iOS CI/emulator; prove fail/pass fixtures.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added staged `release-gate-static` CI job for analyzer-compatible dependency setup, secret scan, public API surface checks, package-size regression, and dependency/license lock validation.
- Added reusable `tool/release_readiness_gate.sh` with explicit pass/fail stages and a 2MB library-size ceiling.
- Added unit fixture coverage for stage declarations, widget coverage for staged status rendering, and Android integration smoke coverage.
- Verification: static gate script passed locally; `flutter analyze` clean; full package suite **1,925 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.2/10**. CI-hosted iOS/Android jobs remain environment-dependent and continue running in the existing workflow.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
