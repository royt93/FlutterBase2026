# T208 — Provider health circuit breaker (ENHANCE)
Priority P1 · Status done · Depends on T143/T180.

Bổ sung trạng thái closed/open/half-open, cooldown và bounded probe cho provider lỗi; không phá fail-open revenue policy. Option static threshold đơn giản hơn nhưng dễ oscillation; khuyến nghị state machine có persistence revision.

Tests: unit transitions/cooldown/race; widget health indicator; integration provider failover/recovery; device smoke với network outage và phục hồi.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Completion (2026-09-12)

Implemented `ProviderCircuitState` with closed/open/half-open transitions, configurable positive cooldown, injected clock for deterministic tests, and single-probe gating. Existing failover API remains compatible. Added unit/widget/integration coverage; `flutter analyze` reports no issues; full suite has 1,909 passing tests; Android device smoke passed on SM S928B. Audit score: 9.4/10. iOS device unavailable.
