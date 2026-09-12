# T208 — Provider health circuit breaker (ENHANCE)
Priority P1 · Status todo · Depends on T143/T180.

Bổ sung trạng thái closed/open/half-open, cooldown và bounded probe cho provider lỗi; không phá fail-open revenue policy. Option static threshold đơn giản hơn nhưng dễ oscillation; khuyến nghị state machine có persistence revision.

Tests: unit transitions/cooldown/race; widget health indicator; integration provider failover/recovery; device smoke với network outage và phục hồi.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
