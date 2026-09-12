# T211 — Coalesce duplicate ad-load requests (ENHANCE)
Priority P2 · Status done.

Nhiều widget/callback có thể gọi load cùng slot gần như đồng thời. Khuyến nghị per-slot in-flight future và request generation, vẫn tôn trọng placement/policy; debounce toàn cục có thể làm trễ ad hợp lệ.

Tests: unit concurrent success/failure/cancel/stale; widget mount storm; integration lifecycle burst; device smoke đo native request count.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Completion audit (2026-09-12)

- Added per-slot in-flight futures for interstitial, rewarded, and rewarded-interstitial loads.
- Concurrent callers now join one native request; independent ad slots remain parallel.
- Generation tokens invalidate stale completions across destroy/re-initialize and failed futures are removed for retry.
- Added unit tests for concurrent success and failure/retry, widget mount-storm coverage, and Android integration smoke coverage.
- Verification: `flutter analyze` clean; full package suite **1,920 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.2/10**. App-open callback fan-out remains a follow-up because its callback contract needs separate compatibility work.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
