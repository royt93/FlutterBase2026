# T214 — Safe feature-flag kill switch (ENHANCE)
Priority P2 · Status done.

Cho phép tắt riêng experimental tuner/arbitrator/prefetcher/digital-twin khi có incident, không cần app release. Khuyến nghị signed/versioned local-remote flags, fail-safe defaults và audit trail; remote unsigned flags là rủi ro injection.

Tests: unit precedence/signature/expiry; widget debug controls; integration rollback/offline; device smoke bật/tắt và re-init.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added signed/versioned Ed25519 feature-flag payloads with canonical JSON, revision monotonicity, and expiry checks.
- Added fail-safe `AdManager.applySignedFeatureFlags()` that rejects malformed/tampered/stale/expired payloads without mutating live state.
- Kill switches disable arbitrator, waterfall tuner, journey prefetcher, and self-healing observer independently; invalid flags cannot enable features.
- Added unit signature/tamper/expiry/precedence coverage, widget operator-status coverage, and Android integration smoke.
- Verification: `flutter analyze` clean; full package suite **1,932 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.3/10**. Remote transport/persistence remains host-owned by design; SDK verifies before applying.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
