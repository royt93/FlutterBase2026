# Audit round 40 — Claude (in-session), independent direct-read pass

**Date:** 2026-09-06
**Codebase version audited:** v2.9.19 (post round 39, `packages/ad_sdk/`)
**Baseline:** `flutter analyze` — 0 issues. `flutter test` — 1656/1656 pass.
**Scope:** Full re-audit (not diff-since-round-39) of the 7 required criteria,
with priority attention on `ad_manager.dart` (7851 lines), the two adapters,
`consent_manager.dart`/`ump_consent.dart`/`iab_storage.dart`, `vip_manager.dart`
+ `_first_install_guard.dart`, and the banner/MREC widget dispose paths.

This file is my own direct-code-read audit, done in parallel with two
external CLI passes (`codex exec`, `agy`) run against an isolated `/tmp` copy
of the repo — see `audit_codex.md` and `audit_gemini.md` for those, and
`audit_round40_consolidated.md` for the merged verdict.

## Method note

40 rounds deep, everything a first read turns up has already been fixed —
what's left needs mechanism-tracing, not pattern-matching (per
`audit-must-be-slow-and-adversarial` in project memory). Two things below
were surfaced by `codex exec`'s independent pass; I did not take its word for
either — I re-read the cited lines myself and checked whether the code (or
its own doc comments) already treats the behaviour as a considered,
documented trade-off before counting it as new.

## Findings

### R40-A (MAJOR, confirmed real, NOT previously flagged) — GPP multi-section priority order can silently drop a real opt-out signal

`lib/src/core/iab_storage.dart:229-240` (`usPrivacyOptedOut`) and `:398-406`
(`_gppUsStatesOptedOut`) resolve US privacy signal by checking sources in a
fixed priority order — legacy `IABUSPrivacy_String` → GPP US National →
GPP California → the 19 other US state sections, section-ID ascending — and
return on the **first non-null (i.e. definitive) answer**, `true` or `false`.

```dart
static Future<bool?> usPrivacyOptedOut() async {
  final usp = await read(keyUsPrivacy);
  if (usp != null && usp.length >= 3) {
    final flag = usp[2].toUpperCase();
    if (flag == 'Y' || flag == 'N') return flag == 'Y';
  }
  final usNational = await _gppUsNationalOptedOut();
  if (usNational != null) return usNational;          // <-- stops here even on a definitive `false`
  final california = await _gppCaliforniaOptedOut();
  if (california != null) return california;
  return _gppUsStatesOptedOut();
}
```

If a device's storage holds a **definitive** "Did Not Opt Out" in a
higher-priority section (US National `SaleOptOut=2`/`SharingOptOut=2`, a
resolvable non-null `false`) *and* a genuine "Opted Out" (`true`) sitting in
a lower-priority section (California, or one of the 19 states), the function
returns `false` — the real opt-out is never read, because the code stops at
the first non-null value instead of continuing until it finds a `true` or
exhausts every section. `_gppUsStatesOptedOut()` has the identical shape one
level down: `Future.wait` reads all 19 state keys, but the loop returns the
first non-null result in `_usStateSkipBits`' insertion order rather than
scanning for any `true` among them.

This propagates into `AdManager._reconcileDeviceUsPrivacy()`
(`lib/src/core/ad_manager.dart:5192-5227`), which only raises `doNotSell` on
a `true` result — so RDP is never sent to AdMob and `setDoNotSell(true)` is
never sent to AppLovin for a user whose real, lower-section opt-out got
shadowed this way.

**Why this is plausibly real and not the "no signal" case already handled:**
the code already has a test for the *null*-shadowing case —
`test/ad_manager_core_test.dart` ~3970 ("USNAT with no usable signal must
not shadow a real California-only opt-out") — proving the team already cared
about this exact failure shape. But that test only covers USNAT returning
`null` (all fields "Not Applicable"). There is no test anywhere in
`ad_manager_core_test.dart` or `consent_us_privacy_propagation_test.dart` for
USNAT returning a **definitive `false`** while a lower-priority section
returns `true` — the gap the null-case test was written to guard against is
still open one level up.

**Is the underlying scenario realistic?** MSPA's convention has a CMP
populate only the one section matching the user's actual jurisdiction, with
others left absent or all-"Not Applicable" — in the well-behaved case this
bug is inert. It stops being inert in two realistic-enough situations: (1) a
user relocates between US jurisdictions (e.g. moves from a state with no
dedicated GPP section, so the CMP wrote US National, to California) and the
CMP does not clear the now-stale US National key on the next run, or (2) an
app swaps CMP vendors and the new one starts writing a different section
without wiping the old one first. Both leave a stale-but-definitive value in
a higher-priority slot next to a fresh, real signal in a lower one. This is a
known integration gotcha with GPP in practice, not a contrived edge case.

**Recommendation (not applied — this task is audit-only):** change the
merge rule from "first non-null wins" to "any `true` wins; only return
`false` once every section has been read and none said `true`". That is a
mechanical change to `usPrivacyOptedOut()` and `_gppUsStatesOptedOut()`
(read every section unconditionally instead of short-circuiting), plus two
regression tests: USNAT=false + California=true, and state-9=false +
state-10=true.

### R40-B (not new — verified already-documented, tagging false-positive-as-"new-finding") — connectivity watch can go stale after a failed re-init

`codex exec`'s pass also flagged: `_connectivityReady`
(`lib/src/core/ad_manager.dart:1283`) is a process-level flag never reset by
`_stopConnectivityWatch()` (`ad_manager.dart:7658-7663`, which cancels
`_connectivitySub` but leaves the flag alone), while the periodic self-heal
branch only re-attempts `_startConnectivityWatch()` when `!_connectivityReady`
(`ad_manager.dart:7602-7607`) — so a re-init whose watch attempt fails can
leave the manager "ready" with no live subscription, and reconnect-triggered
refill silently stops firing until the next 5-minute poll.

I re-read the code immediately above that `if` and it's already covered: the
comment block right before it (`ad_manager.dart:~7593-7601`) states this
exact gap in these words — *"The residual gap is real but narrower and
deliberately left: a teardown cancels `_connectivitySub`, so after a
re-init whose watch failed we can be 'ready' with no live subscription and
therefore no refill-on-reconnect... gating this re-attempt on the
subscription instead would fix it, but under `flutter test` the connectivity
checker then runs for real... so it would cost test-only seams to buy back a
path the 5-minute poll already covers, just less promptly."* This is a
correctly-identified mechanism, but not a new bug — it's a previously
considered and consciously accepted trade-off, already in the source. Noting
it here only so the consolidated report doesn't double-count it as a fresh
MAJOR the way a less careful pass would.

### Everything else — no new findings

I read `ad_manager.dart`'s `setConsent()` (lines 3850-4149, the area rounds
38-39 spent most of their fixes on), the VIP anti-clock-rollback logic in
`vip_manager.dart` (`_effectiveNow`, lines 365-400), `_first_install_guard.dart`
end-to-end, and the banner/MREC widgets' `dispose()` methods
(`banner_ad_widget.dart:443-455`, `mrec_ad_widget.dart:314-325` — every
`addListener`/`RouteAware.subscribe`/`ValueNotifier` in `initState`/build has
a matching teardown call). All of it is consistent with what's documented
and already covered by regression tests from prior rounds. No new BLOCKER or
MAJOR runtime bug found in these areas this round.

## Verdict contribution

0 BLOCKER, 1 MAJOR genuinely new (R40-A, GPP multi-section fallthrough), 0
MINOR new. R40-B is a false alarm relative to "new finding" framing (already
documented, already a conscious trade-off). See
`audit_round40_consolidated.md` for the production-readiness call combining
this with `audit_codex.md` and `audit_gemini.md`.
