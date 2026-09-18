# Audit round 43 — AdMob-only policy/compliance re-audit

Date: 2026-09-18. Scope: focused, AdMob-only re-audit requested after round 42 (which
covered both providers together). Two independent subagents, each with live internet
access, re-checked source against Google's CURRENT (fetched today) policy/developer docs
rather than relying on training-data recollection or round 42's own conclusions. Neither
read round 42's report before forming its findings.

## 1. Ad placement, density, reward-granting — CLEAN

Live docs fetched: "Disallowed interstitial implementations", "Recommended interstitial
implementations", rewarded ads policy, App Open ad guidance (all `support.google.com/admob`).

- No interstitial is wired to app launch/exit lifecycle events — only App Open is, which
  is exactly the Google-sanctioned ad type for that moment.
- App Open shows before the user reaches app content (from the splash route, before
  `_goHome()`/`pushReplacement`), matching the live guidance's "before, not after" rule.
- `_fullscreenBusyReason` + `minTimeBetweenFullscreenAds` (60s) apply uniformly across
  App Open/Interstitial/Rewarded, satisfying "don't show ads immediately before/after an
  App Open ad."
- `AdMobAdapter`'s `earned = true` is set in exactly two places, both strictly inside
  GMA's own `onUserEarnedReward` callback — traced end to end, no other path (debug seam
  or otherwise) sets it. `vipAutoGrant`'s no-ad VIP perk never touches an AdMob object at
  all, so it isn't an AdMob reward-policy question.
- `AdLoadingDialog.showAdBuffer` ahead of every fullscreen show call site matches Google's
  own recommended "insert a loading/please-wait screen" pattern.
- Safety caps (`AdSafetyConfig.canShowFullscreenAd`) are checked and can `return` before
  any native `show*` call — load-bearing, not cosmetic.
- Example call sites are each a standalone button with no adjacent frequently-tapped
  control — no accidental-click risk.

**Observational note (not a finding):** Google's "no more than one interstitial per two
user actions" rule can't be enforced by a generic SDK that doesn't know what a "user
action" means in an arbitrary host UI — `AdSafetyConfig` only throttles by wall-clock
time and counts. Already the host's documented responsibility (`CLAUDE.md` item 6); no
code change indicated.

**Verdict:** compliant with Google's live policy text as of today. No BLOCKER/MAJOR/MINOR.

## 2. Consent/privacy (GDPR/UMP, US states, COPPA) — 1 MINOR, 1 NIT

Live docs fetched: `developers.google.com/admob/flutter/privacy` (canonical UMP setup
page), `.../privacy/us-states`, `.../privacy/gdpr` (partial), Android targeting doc
(TFCD/TFUA deprecation notice), `google_mobile_ads` pub.dev changelog.

**Resolved ambiguity (not a finding):** the canonical live Flutter UMP page does NOT
require `MobileAds.instance.initialize()` to be gated behind consent resolution — only ad
*requests* must be gated via `canRequestAds()`. This SDK's existing design (UMP resolves
consent while native `initialize()` proceeds concurrently, ad loads/shows separately gated
on `canRequestAds`) matches this exactly, confirmed against live text rather than assumed.

- **MINOR (non-urgent, already tracked) — `tagForChildDirectedTreatment`/
  `tagForUnderAgeOfConsent` are now deprecated Google APIs.** `lib/src/core/ad_consent.dart:107-115`
  and `lib/src/adapters/admob_adapter.dart:445-454` only ever set the legacy TFCD/TFUA
  enums. Google's live Android targeting doc confirms these are deprecated in favor of a
  unified `setAgeRestrictedTreatment()` (TFAT), available in `google_mobile_ads` **9.1.0**.
  This package pins `google_mobile_ads: ^7.0.0` (Flutter/Dart floor reasons already
  documented in `CLAUDE.md`'s pinning-wall section), so TFAT isn't reachable yet. Google
  states legacy TFCD/TFUA "will continue through 2026," full removal not expected before
  a major release in H1 2027 — not urgent, and not an independent problem: it's the same
  Flutter/Dart floor bump already blocked for other reasons. Folded into the existing
  `CLAUDE.md` pinning-wall note rather than filed as a new standalone risk.

- **NIT — stale doc comment scopes "Privacy Options" requirement to EEA/UK only.**
  `lib/src/core/ump_consent.dart:385-399`'s doc comments say the durable Privacy Options
  entry point is required "for EEA/UK users." Google's UMP SDK also supports a
  US-states/GPP consent message type, and nothing in the live docs scopes this
  requirement to EEA/UK only. No functional impact (the code just proxies the native
  status without branching on region) — doc-only fix.

**Verified against live docs, no finding:** RDP forwarding (`extras: {'rdp': '1'}`) is
still Google's current documented mechanism; `updateRequestConfiguration()` before
`initialize()` is still the current requirement; TCF was not replaced by GPP (they're
parallel — EEA vs. US-state) and this code's key-namespace split matches; TCF's
2026 v2.2→v2.3 migration doesn't change purposes 1/3/4's semantics, so
`tcfAllowsPersonalisedAds()`'s triad remains correct.

**Not independently re-verified this round:** the 19 US-state GPP bit offsets in
`iab_storage.dart` (already empirically verified in a prior round per its own comments;
re-deriving needs the IAB's reference encoder, out of scope for this pass — treated as
unverified-by-this-round, not confirmed-wrong).

**Verdict:** compliant with Google's live requirements as of today.

## Actions taken this round

- Fixed the NIT (stale EEA/UK-only doc comment in `ump_consent.dart`).
- Added a note to `CLAUDE.md`'s pinning-wall section recording the TFCD/TFUA→TFAT
  deprecation as a fact to remember once/if that Flutter/Dart floor bump ever happens —
  no code change, since the underlying blocker (CI-pinned Flutter 3.35.1) is unchanged.

## Production-readiness impact

None — no BLOCKER/MAJOR/MINOR-requiring-immediate-fix findings. Round 42's AdMob-related
conclusions (reward integrity, COPPA/GDPR signal separation, test-ID separation) hold up
under a fresh, live-doc-checked re-audit.
