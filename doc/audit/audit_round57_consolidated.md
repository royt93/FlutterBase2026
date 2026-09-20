# Audit round 57 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `5b16d3c` (same-day new feature —
`AdConfig.onConsentProvenanceEntryAppended`, an opt-in external-anchor hook
for `ConsentProvenanceJournal`, added earlier in this session on top of
round 56's fixes; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

`codex exec` hit its usage limit mid-round (retry window 16:55) before it
could run — per this repo's established precedent (round 56 hit the same
wall), an in-session Claude fork ran the identical adversarial brief as a
substitute rather than skipping external review entirely.

1. **Fork O** — fresh, assumption-free re-read of `lib/src/widget/` (11
   files, 4487 lines), last independently audited in round 52 (5 rounds
   ago). Deliberately not trusting round 52's "clean" verdict; traced
   dispose/lifecycle paths, RouteAware wiring, and cross-checked
   banner/mrec/native for the copy-paste-drift pattern that has produced
   real bugs before (e.g. round 46's `isStaleAppLovinCallback` guard).
2. **Fork P** — codex substitute — adversarial review of same-day commit
   `5b16d3c` (`AdConfig.onConsentProvenanceEntryAppended`), the new
   opt-in hook that lets a host app mirror `ConsentProvenanceJournal`
   entries to its own server as an external tamper-evidence anchor (see
   CHANGELOG `[Unreleased]`). Reviewed for thread-safety/re-entrancy,
   exception-handling completeness, memory/closure retention, doc-vs-code
   accuracy, and test-coverage gaps — verified empirically (throwaway
   `flutter test` probes), not just by reasoning.

## Findings

**1 real, MAJOR** — found and fixed same-day (commit `d7a701f`).

### Fork P: async callback exception leaked as unhandled zone error

`lib/src/compliance/consent_provenance_journal.dart`'s
`try { _onEntryAppended?.call(entry); } catch (_) {}` (as first written in
`5b16d3c`) only ever caught a *synchronous* throw. An `async` callback —
the natural way to write "await an HTTP call", which is exactly the use
case this hook exists for — never throws synchronously; it returns a
`Future` that rejects instead. That `Future` was neither awaited nor given
an error handler, so the rejection escaped as an **unhandled zone error**
(fatal in many Crashlytics/Sentry setups), directly contradicting the doc
comment's and CHANGELOG's explicit promise that "a throwing callback never
fails the underlying consent change." Verified empirically with two
throwaway `flutter test` probes (a `void Function(int)`-typed field holding
an async closure that throws before vs. after an `await` — both escaped).
The gap existed because the original 3 tests for this hook only exercised
a synchronous throw.

**Fix:** widened the field/param type from `void Function(...)` to
`FutureOr<void> Function(...)`, and attached a no-op `catchError` to the
returned value when it's a `Future`, without awaiting it — keeps the
documented fire-and-forget, non-blocking property while actually
swallowing async errors too. New regression test
(`test/consent_provenance_journal_test.dart` — "an async-throwing callback
does not escape as an unhandled error") covers the case the original 3
missed. 2189/2189 suite green, `flutter analyze` clean.

### Fork P: checked and found NOT bugs

- Re-entrant `append()` calls from inside the callback — traced
  `_writeQueue`'s Future-chaining; Dart's single-threaded run-to-completion
  means a reentrant call just chains safely, no deadlock.
- The callback firing inside `_appendLocked` does not block subsequent
  appends — it's fire-and-forget, never awaited.
- Closure-retention risk (a host closure capturing a `BuildContext` or
  disposed widget) — not novel to this commit; identical shape to already-
  accepted `AdConfig.onLog` / `vipKeyValidator`.

### Fork O: no findings

Read all 11 files in `lib/src/widget/` fresh. `banner_ad_widget.dart`
(1108 lines): mounted-guards complete on every async callback,
Timer/listener cancellation complete in `dispose()`; the RouteAware +
TickerMode + VisibilityDetector three-layer interaction (audited across
rounds 29/31/32/33/39/46) shows no gap. `mrec_ad_widget.dart` /
`native_ad_widget.dart`: `isStaleAppLovinCallback` /
`isNativeInstanceDisposed` guards present and consistent with round 46's
banner fix — no drift. `ad_loading_dialog.dart`: epoch/generation logic
(round-42/MJ16/MJ17 fixes) still closes every race between
`show()`/`showAdBuffer()`/`dismiss()`/`resetState()`.
`adaptive_ad_surface.dart` and `top_toast.dart` (staler files, last
touched round 29, ~27 rounds ago): debounce-Timer cancellation and
`TickerCanceled` handling correct; identity-check against wrong-toast
dismissal intact. `inline_ad_controller.dart`: attach/detach still uses
`identical()` correctly. One low-confidence lead (the external
`visibility_detector` package's static `_lastVisibility` map) was traced
to the package's own composition-callback cleanup on detach and not
reported as a finding — not this SDK's code, and no reachable leak found
in the normal dispose path.

**Verdict:** `lib/src/widget/` has reached audit saturation (9+ direct
rounds touching these files); round 58+ should not re-target it without a
new lead (a real bug report, a dependency upgrade, or a new widget added
to the directory).

## Test status

Full `packages/ad_sdk` suite: **2189/2189 passing** (1 new regression test
— async-throwing `onEntryAppended` callback). `flutter analyze`: 0 issues.

## Publish-gate status

Round 56 found & fixed 1 real MAJOR. Round 57 found & fixed 1 real MAJOR
(same-day self-introduced bug, caught before it ever shipped). The
two-consecutive-clean-rounds bar (tracked since round 55) remains unmet —
per the round 55/56 decision, run round 58 next; if it comes back clean,
round 57+58 do NOT count as the two consecutive clean rounds since 57 had
a real finding, so a genuinely clean round 58 would need a clean round 59
to close the gate.

## Recommendation

No blockers. The round-57 finding never reached a published version — it
was introduced and fixed within the same session, before commit `5b16d3c`
was ever released. Round 58 should cover a fresh, previously-unaudited or
long-stale area (candidates: `lib/src/adaptive/`, last touched round 53;
`lib/src/adapters/`, last touched round 52) to keep making progress toward
the two-consecutive-clean gate rather than re-scanning saturated ground.
