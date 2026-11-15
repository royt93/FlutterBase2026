# T282 — AdMob response diagnostics discovery

- **Type:** Product/API discovery
- **Priority:** P3 · **Severity:** LOW
- **Confidence:** Hypothesis only; no defect or partner demand confirmed.
- **Status:** refuted / no-change (2026-11-15); revisit only with a reproducible partner case.
- **Evidence:** `lib/src/state/ad_event.dart:34-44, 133-170`; `lib/src/adapters/admob_adapter.dart:155-225, 910-940`; `lib/src/adapters/gma_bridge.dart:47-59`; `lib/src/core/ad_manager.dart:1576-1598`; `lib/src/monetization/ad_diagnostics.dart:25-33, 85-91, 173-218`; `test/privacy_safe_diagnostics_test.dart:8-46`; `README.md:1930-1948`.

## Question

Do AdMob partners need response/no-fill detail beyond the current public event stream and safe aggregate diagnostics?

## Findings

- `AdLoadEvent` reports success/failure and optional `errorCode`; it does not expose the native failure message or `ResponseInfo`.
- Paid AdMob events include revenue fields and mediation adapter class names when the callback provides response info. This is not request-level no-fill telemetry: no paid event means the persisted revenue-derived waterfall snapshot may have no corresponding entry.
- `AdManager.diagnostics()` is a read-only aggregate snapshot. It sources the last waterfall from persisted revenue events and includes enabled aggregate fill-rate, baseline, arbitrator, and revenue-integrity signals. It does not expose raw response data or request-level no-fill causes.
- `AdDiagnostics.toSafeJsonString()` bounds and redacts known sensitive values. Existing tests cover redaction, checksum verification, size bounds, and the empty facade. This does not establish that arbitrary raw Google response fields are safe to persist or export.
- No concrete partner report, reproducible scenario, or evidence that current signals block diagnosis was found in the ticket or inspected repository. The ticket's limitation is real, but does not by itself justify adding public API or retained diagnostic data.

## Decision

No implementation ticket now. Close this discovery as **refuted/no-change for lack of validated demand**, not as proof that no partner could need this. Reopen only when a partner supplies the ad format, reproducible success/no-fill/failure scenario, exact diagnostic fields needed, and decision those fields would enable. Then verify Google field semantics, privacy, retention, opt-in behavior, and public API compatibility in a separate implementation proposal. Do not retain or export raw `ResponseInfo` by default.

## Test matrix

- **Unit/widget/integration/device/golden/interruption/network/memory/profile/frame-jank/mediation:** N/A — discovery only; no runtime or API changes.
- **IAP:** N/A — host-app scope.
- `git diff --check` is the applicable validation for this ticket update.
