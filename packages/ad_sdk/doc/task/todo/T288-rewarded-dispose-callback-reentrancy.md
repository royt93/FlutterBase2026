# T288 — Verify AdMob dispose-callback reentrancy

- **Type:** Lifecycle follow-up / race verification
- **Priority:** P3 · **Severity:** LOW / theoretical
- **Status:** no-change (2026-11-20); reentrant host-visible defect not demonstrated, keep callback ordering unchanged.
- **Evidence:** `lib/src/adapters/admob_adapter.dart` (`dispose`, fullscreen callback fields); `test/admob_behavioral_test.dart` (`dispose() with pending callbacks that throw`).

## Hypothesis and boundary

`AdMobAdapter.dispose()` snapshots and nulls pending fullscreen callbacks, then invokes each callback with an unsuccessful/skipped result **before** resetting/disposing slots and inline registries. A host callback may synchronously re-enter the manager/adapter or inspect slot state during this interval and observe stale slot state or request new work against a disposed adapter.

The adapter sets `_fullscreenDisposed` before invoking callbacks; load entrypoints and native callbacks have disposed guards. The pre-reset callback order predates 3.7.6 and was not shown to cause a host-visible defect. Do not mark as confirmed from inspection alone.

## Disposition (2026-11-20)

No-change. The 3.7.6 fix consumes and isolates callbacks and `_fullscreenDisposed` is already set before host callbacks run. The reentrant callback can still inspect pre-reset slot state because callbacks remain before slot reset; no isolated test or host report showed that state causes duplicate presentation, a leaked resource or a false host-visible result. Changing callback order without such evidence could change callback semantics. Reopen only with a minimal regression showing a concrete unsafe effect. This ticket does not claim reentrancy was tested.

## Acceptance criteria before changing runtime

- [ ] Create a host callback that synchronously re-enters `dispose()`, attempts a new load/show, and inspects all four fullscreen slots while disposal callbacks run.
- [ ] Assert cleanup completes, each callback fires once, timers/ad handles are disposed once, and no user callback can resurrect work or see an unsafe state.
- [ ] If all reentrant paths are blocked by `_fullscreenDisposed` and no unsafe state is observable, close no-change and document the existing order. Otherwise add a failing regression before deciding whether callbacks should move after slot cleanup.
- [ ] Keep App Open, Interstitial, Rewarded and Rewarded Interstitial behavior consistent; independent review and targeted/full tests required for any fix.

## Out of scope

Do not reopen the fixed throwing-callback cleanup bug. No callback API/signature change, no broad adapter disposal refactor, no release until user approves.
