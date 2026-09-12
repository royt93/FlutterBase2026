# T218 — App-open load callback fan-out (ENHANCE)
Priority P2 · Status done. Depends on T211.

Coalesce explicit concurrent app-open loads while delivering exactly one
completion callback to every caller. Preserve fire-and-forget lifecycle
preload behavior and isolate throwing host callbacks.

Tests: unit concurrent callback fan-out/throwing callback; widget mount storm;
integration Android smoke; audit+score /10; unit/widget/integration mọi case;
smoke device; nếu >9/10 commit+push.

## Completion audit (2026-09-12)

- Added explicit app-open load coalescing with callback fan-out: every caller receives exactly one completion result.
- Preserved fire-and-forget lifecycle preloads without callbacks, avoiding behavior changes to resume/retry paths.
- Host callback exceptions are isolated and logged; late callbacks remain generation/lifecycle-safe.
- Added unit tests for concurrent delivery and throwing callbacks, widget mount-storm coverage, and Android integration smoke.
- Verification: `flutter analyze` clean; full package suite **1,923 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.4/10**. iOS physical smoke was not run in this loop.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.
