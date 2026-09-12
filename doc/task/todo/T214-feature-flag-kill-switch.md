# T214 — Safe feature-flag kill switch (ENHANCE)
Priority P2 · Status todo.

Cho phép tắt riêng experimental tuner/arbitrator/prefetcher/digital-twin khi có incident, không cần app release. Khuyến nghị signed/versioned local-remote flags, fail-safe defaults và audit trail; remote unsigned flags là rủi ro injection.

Tests: unit precedence/signature/expiry; widget debug controls; integration rollback/offline; device smoke bật/tắt và re-init.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
