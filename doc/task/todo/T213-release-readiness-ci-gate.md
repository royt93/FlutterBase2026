# T213 — Release-readiness CI gate (NEW)
Priority P1 · Status todo.

CI phải gate analyzer, full tests, integration smoke, secret scan, public API diff, package-size regression và license/dependency audit. Khuyến nghị staged required checks; một job khổng lồ khó debug.

Tests: unit pipeline parser; widget/integration sample app; device smoke trên Android+iOS CI/emulator; prove fail/pass fixtures.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.
