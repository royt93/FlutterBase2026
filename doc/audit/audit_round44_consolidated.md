# Audit round 44 — consolidated verdict

**Date:** 2026-09-18
**Codebase version audited:** v2.9.23 (matches latest published pub.dev version, confirmed via `pub.dev/api/packages/applovin_admob_sdk` — no version drift, 150/160 pub points, the missing 10 points are the already-documented `google_mobile_ads`/`package_info_plus` dependency-currency gap blocked on the Flutter-3.35.1 CI floor, see `CLAUDE.md`).
**Method:** three fully independent passes over the same 7 criteria (cross-platform abstraction, offline behavior, ad lifecycle/memory, 1-day trial, offline VIP activation, consent for all countries, AdMob/AppLovin policy compliance), run in parallel, none seeing the others' output or prior audit history until after all three finished:

| Pass | Environment | Result file | Verdict as filed |
|---|---|---|---|
| `codex exec --dangerously-bypass-approvals-and-sandbox` | isolated throwaway copy, no `.git`, no `doc/audit/` | `audit_codex.md` | **No — 4 MAJOR** |
| `agy --dangerously-skip-permissions` | isolated throwaway copy, no `.git`, no `doc/audit/` | `audit_gemini.md` | **Yes — 5 MINOR/NIT only** |
| In-session Claude fork, from-scratch re-trace | real worktree, full CLAUDE.md/history access | `audit_claude.md` | **Yes, conditionally — 1 new MINOR** (superseded, see below) |

## Why the verdicts disagree, and which one governs

codex's 4 MAJOR findings were all in the consent/privacy subsystem. Rather
than pick a verdict by majority vote, each of the 4 was independently
re-verified against the real source in this worktree (not codex's citations,
not codex's isolated copy — the actual files), by someone who had already
seen and partially trusted the Claude fork's "no regression from round 43"
conclusion. **3 of 4 confirmed real; 1 (native-ad App Open exclusion) also
independently confirmed via the same file both codex and this pass read.**

The Claude fork's and agy's passes both missed all of them. Root cause,
same shape both times: both passes verified *that consent propagates from
the SDK's internal `AdConsent` state to AdMob/AppLovin correctly* — that
plumbing is genuinely solid — but neither asked whether the *value being
computed and written into `AdConsent` in the first place* has a valid legal
basis for every code path that can set it. codex asked that second question;
the other two didn't. See the addendum in `audit_claude.md` for the detailed
self-critique. This is the same failure shape as the project's
`self-review-misses-what-independent-review-catches` precedent.

**Governing verdict for this round: CONDITIONAL — do not ship v2.9.23 to
apps serving EEA/UK/Switzerland users without fixing findings 1–3 below
first.** Everything else audited across all three passes — cross-platform
abstraction, offline/no-network handling, ad lifecycle/memory safety,
reward-integrity, trial-mode design, VIP crypto — is solid and consistent
across all three independent reviewers.

## Confirmed MAJOR findings (fix before EEA/UK/CH production use)

### 1. Non-certified built-in consent dialog can authorize personalized ads without valid EEA legal basis
`lib/src/consent/consent_dialog.dart:282-293`, `lib/src/core/ad_manager.dart:2670-2739`.
When a host sets `autoRequestUmpConsent: false` and relies on the SDK's
built-in Cupertino consent dialog, tapping "Allow" sets `hasUserConsent:
true`, is written straight to AppLovin's `setHasUserConsent`, and clears
the `_footgunBlocked` release gate — even though the code's own comment
states this dialog "is NOT a Google-certified CMP, produces no TCF consent
string, so 'yes' collected is not a valid legal basis in EEA." The README
currently oversells this as "GDPR-compliant consent UI without integrating
a third-party CMP" (`README.md:36-43`) — that claim is false for any host
using this configuration.
**Fix:** the built-in dialog must never set provider ad-personalization
consent or clear the release gate in a regulated region; require a
certified CMP (UMP or equivalent) for that. Correct the README claim.

### 2. `setDoNotSell(true)` called before `initialize()` is silently discarded, contradicting its own docstring
`lib/src/core/ad_manager.dart:5024-5029`. The docstring says "Safe to call
before `initialize()` — `ConsentManager` persists the choice ... regardless."
The implementation: if `_consentManager == null` (i.e., before init), it
logs "ignored" and returns, dropping the value. A CCPA/CPRA opt-out
gate that calls this pre-init — exactly as the public API says is safe —
silently fails to take effect.
**Fix:** buffer this call through the same pre-init mechanism `setConsent`
already uses. Add a regression test that calls it pre-init, initializes,
and asserts the value survives and reaches both providers.

### 3. TCF purpose-only consent boolean (deliberately vendor-blind for AdMob) is reused as AppLovin's vendor consent signal
`lib/src/core/iab_storage.dart:535-606`, `lib/src/core/ad_consent.dart`.
`tcfAllowsPersonalisedAds()` deliberately skips parsing
`IABTCF_VendorConsents` — a reasonable, documented choice specific to
avoiding a fragile mis-parse of Google's vendor-id bitfield. That same
purpose-only boolean then becomes `AdConsent.hasUserConsent`, which is fed
directly into `AppLovinMAX.setHasUserConsent`. AppLovin is a different
vendor; the rationale that justified skipping vendor consent for Google
does not extend to it. A user who consents to purposes 1/3/4 but denies (or
never granted) the AppLovin vendor is reported to MAX as having consented.
**Fix:** do not synthesize an affirmative MAX consent bit from purpose
consent alone — either let MAX's own documented TCF-string consumption
handle it unmodified, or evaluate AppLovin's actual vendor consent bit.

## Confirmed finding not requiring a blocking fix but worth tracking

### 4. App Open's "hide every inline surface" pass excludes native ads on both providers (MINOR)
`lib/src/adapters/admob_adapter.dart:307-315` (own comment: "never
registered with `_inlineVisibility` ... never hides them the way
banner/mrec are hidden"), same pattern in the AppLovin adapter. A live
native ad stays mounted and visible underneath an App Open ad shown on
resume — the exact ad-over-ad conflict Google's App Open policy prohibits,
just for a format the existing hide pass never covered. Lower urgency than
1–3 (narrower blast radius, not a legal-basis issue), but should be fixed
before calling App Open suppression complete.

## Everything else — consistent PASS across all 3 independent passes

- **Cross-platform abstraction**: real, not nominal — both providers resolve Android/iOS ad-unit IDs correctly, no Android-only path masquerading as cross-platform, test-device registration ordering respected for AppLovin's init-time requirement.
- **Offline/no-network**: fail-closed and bounded everywhere — 20s init/UMP timeouts, 30s load watchdogs, automatic reconnect-triggered refill, no reward fabricated on connectivity loss. One documented residual: a slot with a confirmed-shown ad has no forced timeout (by design, to avoid stacking a second fullscreen ad over a still-visible one) — defensible trade-off, not a bug.
- **Ad lifecycle/memory**: strong. Generation/identity guards discard stale ads, AdMob native objects and AppLovin listeners/timers are disposed, banner/MREC have route/background/fullscreen visibility ownership. Reward integrity confirmed: AdMob grants only from `onUserEarnedReward`, AppLovin only from `onAdReceivedRewardCallback`; both report `earned: false` on early dismiss.
- **Trial mode (1 day)**: high-water-mark clock + monotonic stopwatch defeats naive clock rollback. Reinstall bypass is a consciously accepted, documented trade-off (iOS Keychain survives; Android depends on best-effort Auto Backup) — a "retention feature," not an enforceable license, and all three passes agree this framing is honest and already correct in the docs.
- **Offline VIP activation**: Ed25519-signed, private key never ships, AVP2 binds bundle ID + expiry, per-device replay blocked by a Keychain/SharedPreferences ledger, CRL revocation supported. Cross-device sharing of an unexpired code before a CRL update is an accepted, documented no-backend limitation, not a hidden flaw.
- **Consent breadth (non-legal-basis parts)**: TCF, US Privacy, GPP Section 7, COPPA/TFUA/ATT are all read and forwarded; consent withdrawal mid-session discards cached fullscreen ads on both providers.
- **Policy posture**: ad density caps, invalid-traffic/CTR-fraud cooldown, rewarded-interstitial disclosure, fullscreen mutex against CMP/dialog overlays — all present and correctly wired, independent of findings 1–4 above.

## New MINOR finding (Claude fork, round 44)

**R44-A** — `packages/ad_sdk/pubspec.yaml`'s `homepage`/`repository`/`issue_tracker` all correctly point at this repo (`github.com/royt93/FlutterBase2026`), but the repo is **private** — confirmed the URL 404s to an unauthenticated fetch, matching this same URL being pushable/clonable with credentials. This is exactly the pub.dev pana scan's own "Homepage URL doesn't exist / unreachable" note (see the pub.dev score check above) — not a wrong/dead URL, a private-repo visibility gap. Currently just a warning note on pub.dev's own score page (still 10/10 on "valid pubspec.yaml" today), not a point deduction yet — but the kind of thing that turns into one if pana's checker gets stricter. No fix available without either making the repo public (see `CLAUDE.md`'s "Known pending security debt" note on why that isn't happening yet) or pointing these fields elsewhere; not previously flagged as its own line item in 43 prior rounds.

## Untouched from round 43 / CLAUDE.md — still standing, not re-litigated here

- `android/app/private_key.pepk` retrievable from git history at `60a1f3d` — deferred per audit round 34 decision (repo still private). No change in status this round.
- The Flutter-3.35.1 CI floor blocking `google_mobile_ads` 8/9 and the last 10 pub points — same known constraint, not independently urgent per round 43/CLAUDE.md.

## Answer to "should we use this SDK in production?"

**Conditional yes.** The architecture, lifecycle safety, offline handling,
trial design, and VIP cryptography are all genuinely solid — three
independent adversarial passes agree on that, and 43 prior audit rounds
already hammered on this code. But this round found 3 real, confirmed
MAJOR consent/legal-basis gaps that every prior round missed, because prior
rounds (and 2 of this round's 3 passes) verified *consent propagates
correctly* without verifying *the consent value itself is legally valid for
every configuration path*.

- If your production app **does not serve EEA/UK/Switzerland users**, or
  **only uses UMP as the sole consent source** (`autoRequestUmpConsent:
  true`, never relying on the built-in dialog for ad personalization), and
  **doesn't call `setDoNotSell` before `initialize()`**: you are not
  currently hitting findings 1 or 2. Finding 3 (AppLovin vendor consent)
  still applies to any EEA traffic using AppLovin as a provider.
- If your app does serve EEA/UK/CH users and uses the default/documented
  integration path: **fix findings 1–3 first.** They are GDPR-relevant
  (personalized ads served without a certified CMP's valid legal basis),
  not stylistic.
- Finding 4 (native ads under App Open) should be fixed before the next
  release regardless of region.

None of this touches the standing `private_key.pepk` decision (repo access
scope unchanged) or the trial/VIP no-backend trade-offs (already accepted
product decisions, re-confirmed sound by all three passes this round).
