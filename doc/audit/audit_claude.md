# Audit round 44 — Claude (in-session), independent direct-read pass

**Date:** 2026-09-18
**Codebase version audited:** v2.9.23 (`packages/ad_sdk/`) — confirmed matches the
version currently published on pub.dev (fetched live; no version drift).
**Baseline:** `flutter analyze` — 0 issues. `flutter test` — 2165 tests, 2161
pass / 4 fail. The 4 failures are all `MissingPluginException(... on channel
plugins.it_nomads.com/flutter_secure_storage)` inside `VipEntriesStore` /
`VipManager` retry-logging paths — a `flutter_secure_storage` platform channel
not mocked in this particular headless test run, not a code defect (same
"4 env flake" pattern noted in round 42/43; not reproduced as a real bug this
round either).
**Scope:** Full re-audit, 7 required criteria, done as a from-scratch direct
read against real source (not a diff since round 43), in parallel with two
external CLI passes (`codex exec`, `agy`) run against isolated throwaway
copies with no visibility into `doc/audit/` — see `audit_codex.md` /
`audit_gemini.md` for those, `audit_round44_consolidated.md` for the merged
verdict.

## Method note

44 rounds deep. Per project memory ("audit-must-be-slow-and-adversarial"),
a prior round's PASS is not itself evidence — this round re-verified the
underlying *mechanism* (not just the doc comments describing it) for the
highest-risk subsystems: VIP Ed25519 signature/CRL verification, the
first-install trial-grace anti-bypass guard, AppLovin/AdMob consent
propagation, and the connectivity-watch race guards. All traced correctly;
no regression found in any of them since round 43. Given how mature this
codebase already is (43 prior rounds, 5+ BLOCKERs and 40+ MAJORs/MINORs
already fixed across that history), this round's real yield was one new,
previously-unflagged finding outside the code itself (see R44-A) plus
confirmation that nothing already-accepted has quietly regressed.

## Findings

### R44-A (MINOR, new, not previously flagged) — pubspec `homepage`/`repository`/`issue_tracker` point at the private repo, 404 to anyone without access

`packages/ad_sdk/pubspec.yaml:11-13`:

```yaml
repository: https://github.com/royt93/FlutterBase2026/tree/main/packages/ad_sdk
homepage: https://github.com/royt93/FlutterBase2026
issue_tracker: https://github.com/royt93/FlutterBase2026/issues
```

`curl -I https://github.com/royt93/FlutterBase2026` returns **HTTP 404** —
confirmed live during this audit, not a training-data guess. This matches
what pub.dev's own scoring page shows independently: the "Follow Dart file
conventions" pana check currently still awards 10/10 for "Valid pubspec.yaml"
but appends a note that the homepage URL "doesn't exist" / was "unreachable"
during analysis.

**Failure scenario:** anyone on the pub.dev listing page who clicks
"Repository", "Homepage", or "Issue Tracker" hits GitHub's 404 page.
Currently costs 0 pub points (pana hasn't started penalizing this — yet),
but is a real, live broken link on a published package's public page today,
and CLAUDE.md's own repo context says the actual repo access model is
"currently private" — so pointing pub.dev visitors at a private/renamed/
nonexistent repo is a dead end regardless of scoring.

**Fix options (pick one, not both — not scoping this beyond flagging it):**
either make that repo reachable at the URL declared (public, or renamed
correctly), or stop declaring `homepage`/`repository`/`issue_tracker` fields
that point at a repo the public can't reach.

### Re-verified, not new — everything below was already known/accepted in CLAUDE.md or prior audit rounds; listed only because this round re-traced the mechanism itself rather than trusting the prior verdict

- **Trial mode (1 day) bypass surface** (`lib/src/vip/_first_install_guard.dart`)
  — Android has no anti-bypass (uninstall+reinstall without Auto Backup
  farms a fresh 24h grace indefinitely); iOS uses a Keychain flag with
  `KeychainAccessibility.first_unlock`, which blocks same-device reinstall
  but has a documented false-positive row (restoring a NEW device from an
  old device's backup wrongly denies grace). Re-verified against the actual
  `hasAlreadyGranted()`/`markGranted()` code, not just the doc comment — the
  described behavior matches the implementation exactly. This is the SAME
  trade-off re-raised and re-confirmed at round 39 (documented rationale:
  no server, by design; see `CLAUDE.md`'s VIP entitlement section) — not a
  fresh finding.
- **VIP redemption crypto** (`lib/src/vip/signed_vip_key.dart`) — Ed25519
  signature verification over AVP1/AVP2 payloads, key-rotation list (any of
  several comma-separated public keys can verify), AVP2 adds per-key expiry
  and bundle-id binding inside the signed payload, and the CRL (revocation
  list) format uses proper domain separation (`"CRL1|"` prefix folded into
  the signed bytes) so a broadcast CRL can't be replayed as a forged AVP1
  key — traced the actual byte construction in both `verifySignedVipKey` and
  `verifySignedCrl`, confirms the domain-separation claim in the doc comment
  is real, not just asserted. No forgery path found. Known, accepted
  residual risk (documented, not new): a leaked already-signed code is
  reusable on any device that hasn't already redeemed it — true global
  one-time-use needs a server this SDK deliberately doesn't have.
- **Consent propagation to both providers** (`lib/src/core/ad_consent.dart`
  `applyConsentToProviders`) — traced the actual AppLovin
  (`AppLovinMAX.setHasUserConsent`/`setDoNotSell`) and AdMob
  (`MobileAds.instance.updateRequestConfiguration`) calls fire from the same
  decided `AdConsent`, confirmed both are attempted independently (one
  provider's exception doesn't block the other) and results tracked via
  `appLovinApplied`/`adMobApplied` flags. AppLovin MAX 4.x genuinely has no
  `setIsAgeRestrictedUser` API — the code correctly logs a warning instead of
  silently dropping the COPPA signal for that provider, and AdMob still
  receives it via `tagForChildDirectedTreatment`. Matches CLAUDE.md's round-43
  note that this legacy API pair is deprecated-but-functional through 2026 —
  not independently urgent.
- **Connectivity watch races** (`lib/src/core/ad_manager.dart`, generation
  counter `_connectivityWatchGen`) — re-checked that
  `_startConnectivityWatch`/`_stopConnectivityWatch` can't leave two live
  subscriptions or fire a stale callback after a fresh
  `initialize()`/`destroy()` cycle; generation guard is checked correctly at
  the one callback site (`_onConnectivityChanged`).
- **Banner widget disposal** (`lib/src/widget/banner_ad_widget.dart:663-677`)
  — `dispose()` detaches the controller, cancels the debounce timer, removes
  both `ValueListenable` listeners, unsubscribes from `adRouteObserver` when
  subscribed, calls `AdManager().disposeBannerInstance(this)`, and disposes
  all three owned `ValueNotifier`s. No leak found.

## Verdict

**Yes, conditionally** — same conditional as prior rounds, unchanged by this
one. This SDK is production-ready from a code-correctness, lifecycle, and
compliance-mechanism standpoint: 44 rounds of adversarial audit (this one
included) have not found an unaddressed BLOCKER in the core ad lifecycle,
consent, or VIP/trial subsystems, and this round's own from-scratch trace of
the highest-risk mechanisms (crypto verification, consent propagation,
connectivity races) confirms the code actually does what its documentation
claims — not just that the documentation *sounds* right.

Before shipping to a NEW production app that hasn't already integrated this
SDK, still resolve — these are pre-existing, not new to this round:

1. **The pubspec dead-link issue (R44-A, this round)** — small, but a
   ready-in-five-minutes fix (make the repo reachable or remove the fields).
2. **CLAUDE.md's own documented pending item**: the leftover
   `private_key.pepk` (Play App Signing key) retrievable from git history at
   `60a1f3d` — decided low-priority while the repo stays private, but must be
   handled (check Play Console usage, rotate if it was ever live, then purge
   history) before the repo's access ever widens.
3. **Product-owner sign-off on the two accepted trade-offs** that are
   trade-offs, not bugs: Android trial-grace farmability via reinstall, and
   single-device VIP-code reuse (no global one-time-use without a server).
   Both are working as documented; a host app with a harder anti-abuse
   requirement needs its own server-side layer on top, not a fix inside this
   SDK.

No new BLOCKER or MAJOR found this round.

## Addendum — post-hoc cross-check against `codex exec`'s independent pass (same day)

This section was added AFTER the verdict above, once `codex exec`'s round-44
report (`audit_codex.md`) came back with 4 MAJOR findings this pass missed.
Rather than average the two verdicts, each of codex's MAJOR claims was
independently re-verified by reading the real source in this worktree
(not codex's isolated copy, not codex's own citation — the actual file). 3 of
4 confirmed real:

- **Consent-dialog footgun** (`lib/src/consent/consent_dialog.dart:282-293`,
  `lib/src/core/ad_manager.dart:2670-2739`) — confirmed. The code's own
  comment already states the built-in dialog "NOT Google-certified CMP,
  produces no TCF consent string, so 'yes' collected is not a valid legal
  basis in EEA" — yet when `autoRequestUmpConsent: false`, tapping Allow
  still sets `hasUserConsent: true`, gets written straight to AppLovin's
  `setHasUserConsent`, and clears `_footgunBlocked`. My own pass's "consent
  propagation" check (above) verified the write mechanically happens
  correctly — it did not check whether the *value being written* had a
  valid legal basis to begin with. That's the miss.
- **`setDoNotSell` pre-init drop** (`lib/src/core/ad_manager.dart:5024-5029`)
  — confirmed. The docstring literally says "Safe to call before
  initialize() — ConsentManager persists the choice through AdPreferences
  regardless." The actual code: `if (mgr == null) { ...log 'ignored'...
  return; }`. A CCPA opt-out called before `initialize()`, as the public API
  explicitly promises is safe, is silently discarded.
- **TCF purpose-only boolean reused for AppLovin vendor consent**
  (`lib/src/core/iab_storage.dart:535-539` + `lib/src/core/ad_consent.dart`)
  — confirmed. `tcfAllowsPersonalisedAds` deliberately skips
  `IABTCF_VendorConsents` with a documented, reasonable rationale specific to
  *Google's* vendor id (avoiding a fragile bitfield mis-parse). That same
  purpose-only boolean is then reused as `AdConsent.hasUserConsent` and fed
  to `AppLovinMAX.setHasUserConsent` — a different vendor, without the
  rationale that justified skipping vendor consent for Google applying to
  it.
- 4th finding (native ads excluded from the App Open "hide every inline
  surface" pass) also independently confirmed by reading
  `admob_adapter.dart:307-315` (its own comment: "never registered with
  `_inlineVisibility`... never hides them the way banner/mrec are hidden") —
  same file both codex and I read, same conclusion.

**Why my from-scratch pass missed these:** I re-traced *whether the
mechanism does what its own documentation/comments claim* (a stronger bar
than round 43's, which just re-read the comments). Every one of these bugs
passes that bar — the code's comments are honest, sometimes literally naming
the exact gap ("NOT Google-certified CMP", "never hides them"). What I
didn't do was independently ask, for each write into `AdConsent`, "is this
input legally valid on its own terms" rather than "does the pipe from input
to provider call work." Per project memory
(`self-review-misses-what-independent-review-catches`): this is the same
shape of gap — self-review checks the mechanism does what it claims,
independent review checks whether what it claims is the right thing to
claim. Codex's genuinely fresh pass (no round history, no CLAUDE.md
familiarity) asked the second question; mine, even doing a real from-scratch
trace, still inherited the first question's framing from 43 prior rounds.

**Revised verdict for this file: see `audit_round44_consolidated.md` — the
"Yes, conditionally" above is superseded. The 3 confirmed consent findings
are real MAJOR compliance gaps for EEA/UK/CH-facing production use**, not
already-accepted trade-offs. They need fixing, not sign-off.
