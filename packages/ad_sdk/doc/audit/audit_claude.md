# Audit round 38 — independent nested-CLI review (Claude, 2026-09-05, v2.9.17)

**Method:** Per orchestrator instructions, this audit was produced by an actually-separate, non-interactive
`claude -p --dangerously-skip-permissions` process (PID 85395), launched from this worktree's repo root so it had
full filesystem access to `packages/ad_sdk`, with no shared context/conversation with the orchestrating agent. That
process split the audit into 8 parallel internal subagents (one per area of `packages/ad_sdk/lib/src/`, ~31.7k
lines), each reading its area line-by-line, cross-checking every claim in `doc/audit/audit_round37_consolidated.md`
against current source (not just trusting the prior report), then self-verified its own new findings before
reporting. The orchestrating agent then independently re-read the cited source for both new MAJOR findings and the
one MINOR it spot-checked, confirming all of them against the actual code below (see "Orchestrator verification"
under each finding).

Scope covered: `packages/ad_sdk/lib/`, `packages/ad_sdk/test/`, `packages/ad_sdk/example/`, against the six owner
requirements (dual-provider Android+iOS, offline/online resilience, per-ad-type lifecycle/leak correctness, 1-day
trial, no-backend VIP-by-code security, consent for every jurisdiction) plus general AdMob/AppLovin policy risk.

Nested CLI invocation did **not** fail — it ran to completion, so no fallback section is needed.

---

## MAJOR-1 (new): AppLovin `NativeAdWidget` gets stuck permanently blank after one load failure — no recovery path ever clears it

**Files:** `lib/src/widget/native_ad_widget.dart:130-140` (`_onNativeErrorChanged`), `:319-335` (`_buildAppLovin`);
`lib/src/adapters/applovin_adapter.dart` (`native()`/`reviveNativeInstance()`/`disposeNativeInstance()`)

**Mechanism (orchestrator-verified against current source):**
- `_buildAppLovin()` (native_ad_widget.dart:319-323) checks `AdManager().nativeHasError(this).value`; if `true` it
  returns `SizedBox.shrink()` and never mounts `_AppLovinMaxNativeView` again.
- The only place `hasError` gets reset to `false` is inside `_AppLovinMaxNativeView.onAdLoadedCallback` — which
  can't fire because the widget that would create it is never mounted while `hasError == true`. Chicken-and-egg.
- `_onNativeErrorChanged`'s 30s retry `Timer` (native_ad_widget.dart:130-140) only does
  `_allowed.value = false; _initNative();` — confirmed by reading it directly: **it does not call
  `mgr.disposeNativeInstance(this)`**.
- By contrast, the sibling handlers in the same file, `_onPersonalisationWithdrawn` (line 146-151) and
  `_onCanRequestAdsChanged` (line 164-188), both call `mgr.disposeNativeInstance(this)` *before* `_initNative()` —
  confirmed via `grep -n disposeNativeInstance lib/src/widget/native_ad_widget.dart`, which shows exactly those two
  call sites and no third one in `_onNativeErrorChanged`.
- `disposeNativeInstance(key)` (applovin_adapter.dart) removes the key's `BannerListenables` bundle from
  `_nativeListenablesByKey` and disposes it; the next `native(key)`/`nativeHasError(key)` call then rebuilds a
  fresh bundle with `hasError: ValueNotifier<bool>(false)` (confirmed at applovin_adapter.dart:518,528). Without
  that call, the same stale `hasError=true` notifier lives on forever.
- `_initNative()`'s AppLovin branch (native_ad_widget.dart:223-228) only logs `'MaxNativeAdView loads on mount'` —
  it has no independent load trigger; mounting is the only load mechanism, and mounting is exactly what's blocked.

**Concrete failure scenario:** a single native-ad no-fill or transient network blip on the AppLovin path fires
`onAdLoadFailedCallback` → `markError()` → `hasError=true`. The widget shrinks to nothing. The 30s retry timer keeps
firing forever but has no effect because it never clears the stale bundle. The user sees an empty space where a
native ad should be for the remainder of that screen's lifetime — permanent AppLovin native-ad revenue loss on that
surface (the AdMob native path is unaffected: it calls its own independent `loadAdmobNativeIfNeeded`/`preloadNative`
rather than going through this mount-triggered path, so this is AppLovin-only).

**Suggested fix:** in `_onNativeErrorChanged`'s `Timer` callback, call `mgr.disposeNativeInstance(this)` immediately
before `_initNative()`, mirroring `_onPersonalisationWithdrawn`/`_onCanRequestAdsChanged`. One-line fix, no
refactor needed.

---

## MAJOR-2 (new): `AdManager.setConsent()` has no epoch/ordering guard on its own tail write — two overlapping calls can leave the native SDK applying a stale, already-superseded consent value

**File:** `lib/src/core/ad_manager.dart:3842-4000` (`setConsent()`), specifically the final
`_adapter?.applyConsent(consent)` write (~line 3992) and `_consentProviderApplyInFlight` bool (~3985-3989)

**Mechanism (orchestrator-verified against current source):**
- `setConsent()` bumps `_consentIntentEpoch` at entry, and synchronously assigns `_consent = consent;` early in the
  function, before any `await`. So far so good for the *field* `_consent`/`ConsentManager.current`.
- But the function's **tail write to the native provider**, `_adapter?.applyConsent(consent)`, uses `consent` — the
  parameter captured in this call's own closure — not a re-read of the latest `_consent`/epoch. It runs after
  `await applyConsentToProviders(consent, config: _config)` resolves, with no epoch check in between.
- Every *other* consent-recovery code path in the same file that writes to a provider after an `await`
  (`_recoverConsentGate` at ~4736, and the similar paths near 4852/4918/5184) captures
  `final epoch = _consentIntentEpoch;` at entry and is structured to lose to a newer intent — confirmed by reading
  `_recoverConsentGate` (ad_manager.dart:4726-4736), which explicitly captures `epoch` with a comment stating "every
  await below is a window in which a real consent decision can start, and this recovery must lose to it." `setConsent()`
  itself — the primary host-facing API and the place the epoch is actually incremented — is the one path that
  doesn't apply this same discipline to its own tail write.
- `_consentProviderApplyInFlight` (only set/cleared for the "tightening" case) is a single bool, not a token/counter,
  so a `finally` from an older overlapping call can clear it while a newer call is still in its own tightening
  window — same class of bug.

**Concrete failure scenario:** host calls `setConsent(declined)` immediately followed by `setConsent(granted)`
(rapid double-toggle in a settings screen, or one path driven by a server-restored value racing a user tap in the
UI). Nothing guarantees the platform-channel `await` inside the `declined` call resolves before the `granted` call's
does. If the `declined` call's tail `_adapter?.applyConsent(declined)` executes *after* the `granted` call's, the
native AdMob/AppLovin SDK ends up actually running non-personalized/declined ads while `_consent` and everything the
host reads back (`ConsentManager.current`, compliance reporting) correctly says `granted` — a real divergence
between reported and enforced consent state, or the reverse (reported declined, native still personalised).

**Suggested fix:** capture `final epoch = ++_consentIntentEpoch;` once at function entry (or otherwise snapshot it),
and guard the tail `_adapter?.applyConsent(consent)` write with `if (epoch == _consentIntentEpoch) { ... }` so a
superseded call's write is dropped — same "latest wins" pattern already used by the other recovery paths in this
file. Replace the `_consentProviderApplyInFlight` bool with a token/counter for the same reason.

---

## MINOR (new)

1. **`lib/src/widget/debug_ad_overlay.dart:212-234`** — `_FillRateRegressionRowsState._trySubscribe()` doesn't
   track the identity of `AdManager().fillRateBaselineMonitor` across a `destroy()`+`initialize()` cycle in the same
   session; the old monitor is disposed (its `StreamController` closed) and this widget keeps listening to the dead
   one. The sibling `_SlotRows` correctly gates on `AdManager().initRevision` via `ValueListenableBuilder<int>`; this
   widget doesn't. Impact is limited to the dev-only debug overlay (self-heals if the panel is closed/reopened), not
   a production-path bug. Fix: gate on `initRevision` the same way `_SlotRows` does.

2. **`lib/src/vip/vip_manager.dart:1364-1366`** — orchestrator-verified directly:
   ```dart
   } catch (e) {
     SafeLogger.w(_tag, 'redeemSignedKey error: $e');
     return SignedVipRedeemResult.invalid('$e');
   }
   ```
   Any non-`VipKeyException` error's raw `toString()` is returned in the public `SignedVipRedeemResult.error` field.
   The bundled `VipRedeemScreen` doesn't surface this field to end users, so there's no leak through the SDK's own
   UI, but a consuming app that builds its own redeem UI directly against this public API could display an internal
   exception message (stack-trace-adjacent text) to an end user on an unusual input. Fix: return a fixed message
   (e.g. `'invalid key format'`) here, keep `$e` only in the `SafeLogger.w` call.

3. **`lib/src/core/iab_storage.dart` GPP probe** — round 37's fix to `usPrivacyOptedOut()` widened it from a ≤3-key
   check to a sequential-await read of up to 22 GPP section keys, run unconditionally on every app resume inside
   `_reconcileDeviceUsPrivacy()`, which sits inside `_resumeAdWorkAfterConsent`'s hard 5s budget. The old doc
   comment describing this as "cheap, only touches the UMP channel on disagreement" is now stale — the probe runs
   unconditionally. On a device with a slow platform channel (~250-300ms/read), 22 sequential reads can approach or
   exceed the 5s budget, causing that resume cycle to skip refilling banner/MREC/App Open. Not a compliance gap
   (still fail-closed) — a silent UX/revenue regression on slow devices. Fix: `Future.wait` the 22 reads in parallel
   instead of sequentially.

## NITPICK (new)

- **`lib/src/core/ad_route_observer.dart:83-85`** — orchestrator-verified: `resetState()`'s docstring still reads
  "Called by `AdManager.destroy`..." even though round 37 correctly *removed* that call (per its own consolidated
  report, item #8/`resetState`/`popupDepth`). The stale docstring risks a future maintainer re-adding the exact call
  round 37 deliberately removed, reintroducing that bug. Fix: update the docstring to say it's now only called by
  tests.

---

## Already-verified round-37 claims — confirmed correct, not re-reported

Both the nested audit and this orchestrator's own follow-up spot-checks confirm the following round-37 fixes are
genuinely in place in current source (v2.9.17), so they are **not** re-reported:

- **BLOCKER (admob dispose-while-showing):** all four `load*()` functions in `admob_adapter.dart` have the
  `&& !slot.isShowing` guard at the correct position.
- **Backoff overflow:** `state/backoff.dart` verified by hand for large `n` — stops correctly at the 30-minute cap,
  no overflow/negative value.
- **Daily-cap clock-rollback:** UTC high-water-mark present and distinct from VIP's own separate high-water-mark
  key (`ad_sdk_vip_max_observed_clock_ms`) — checked specifically for the "wind clock back to extend VIP/trial"
  angle and confirmed both are independently protected.
- **Double-tap dialog guard:** `isDialogOnTop` check present in all three of `canShowInterstitial`/
  `canShowRewardedAd`/`canShowRewardedInterstitialAd`.
- **`resetState()` no longer called from `destroy()`:** confirmed correct (only the docstring is stale — see
  NITPICK above).
- **`delivered` double-invoke guard:** present, and set before the real callback fires, in all four of
  `showAppOpenAd`/`showInterstitial`/`showRewardedInterstitialAd`/`showRewardedAd`.
- **GPP 21/21 US-state sections:** one internal subagent independently encoded fixtures for all 19 states + USNAT +
  California via the real `@iabgpp/cmpapi` reference encoder and ran them through the SDK's decoder — 100% match,
  including the Maryland/Indiana/Kentucky/Rhode Island `SectionID`+`Version`-omission edge case.
- **AppLovin COPPA hard-stop:** `ad_manager.dart:3915-3963` intact, matches MJ7 design.
- Also confirmed clean on re-check: no ad-revenue double-counting, crash-guard doesn't swallow host exceptions, no
  PII/GAID/raw-IP in compliance logs, VIP Ed25519 not forgeable/cross-protocol-replayable, other caps (hourly/
  session/CTR) aren't loosened by clock rollback (rollback only ever tightens them, consistent with the daily-cap
  fix's own high-water-mark approach).

---

## Verdict: production readiness

The dual-provider / offline / lifecycle / VIP / consent foundation remains solid after 37+ rounds — no BLOCKER
found in this round, and no false claim found among round 37's "fixed" items. However, reading with genuinely fresh
eyes (not trusting the prior conclusion) again surfaced **2 real MAJORs, reachable through public API, that 37 prior
rounds missed** — and notably the same *shape* of bug as round 37's own BLOCKER: AdMob has a guard that AppLovin
lacks (MAJOR-1), and a consent-apply path elsewhere in the file has an ordering guard that `setConsent()` itself
lacks (MAJOR-2). This is the second time in two consecutive rounds this exact asymmetry pattern — "the fix exists
for one code path but wasn't ported to its sibling" — has produced the most serious finding, which is itself worth
flagging as a systemic review blind spot: files reviewed repeatedly still get missed bugs when each review pass
follows the specific bug being fixed rather than symmetrically diffing sibling branches/providers against each
other.

Both MAJORs have small, well-scoped fixes (no refactor required) and were independently re-verified against actual
source by the orchestrating agent, not just taken on the nested CLI's word.

**Score: 9.0/10.** Deducted for the two MAJORs (one direct AppLovin native-ad revenue loss with no self-recovery,
one rare-but-reachable consent-state divergence between reported and enforced state — a real compliance-reporting
correctness issue even though it doesn't defeat fail-closed behavior on its own). Not deducted further because: no
BLOCKER, every other part of the six owner requirements (dual-provider parity, offline resilience, per-ad-type
lifecycle/no-leak, 1-day trial, no-backend VIP crypto, consent for every jurisdiction) checked out clean against
actual mechanism (not just pattern-matching), and both new findings have narrow, low-risk fixes ready to apply.
