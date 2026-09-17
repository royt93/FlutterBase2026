# Audit round 42 — consolidated verdict

Date: 2026-09-17/18. Checkout/pub.dev version: `2.9.21` (verified matching, no drift).

## Brief given to all three independent reviewers

Full audit of `packages/ad_sdk/` (SDK + example), against this checklist (user's own
words, translated): provider abstraction (AdMob/AppLovin) works for Android **and** iOS;
works with and without network; correct legal/lifecycle/no-leak behavior for
banner/app-open/rewarded/interstitial; 1-day trial mode; VIP activation by code with
**no server/backend**; consent for every country, applied correctly to both AdMob and
AppLovin; policy compliance with AdMob/AppLovin rules. Each reviewer was told to read the
whole codebase end-to-end as if round 1 (no diff-against-history framing — see
`audit-must-be-slow-and-adversarial` in this session's memory for why that framing has
previously hidden real bugs here), rate findings BLOCKER/MAJOR/MINOR/NIT, and give an
explicit yes/no/conditional production-readiness verdict.

## The three sources

| Reviewer | Method | Verdict given | Reliability this round |
| --- | --- | --- | --- |
| `codex` (`audit_codex_round42.md`) | Isolated detached worktree, `codex exec --dangerously-bypass-approvals-and-sandbox` | **No — 2 BLOCKER, 2 MAJOR** | High — every BLOCKER/MAJOR claim independently re-verified against source below |
| `gemini`/`agy` (`audit_gemini_round42.md`) | Isolated detached worktree, `agy --dangerously-skip-permissions` | **Yes — 0 BLOCKER/MAJOR** | Low — repeats this reviewer's well-documented pattern (see file's own editorial note) of scoring everything PASS; its factual subsystem descriptions are accurate, its "nothing wrong" verdict is not |
| `claude` (`audit_claude_round42.md`, this session, 7 parallel subagents + my own direct re-reads) | Same repo, in-process subagents, one whole subsystem each | **Conditional — 1 confirmed BLOCKER, several MAJOR** | This is my own work; see below for how I weighted it against the other two |

Both external reviewers independently confirmed pub.dev's live listing shows `2.9.21`,
matching `pubspec.yaml` exactly — no version drift to account for.

## Final finding list (my own severity calls, after independently verifying every
MAJOR-or-above claim against source myself — not just trusting either external reviewer)

### BLOCKER (1) — must fix before shipping the affected feature

**AppLovin native ads are missing the mandatory privacy-information icon
(`MaxNativeAdOptionsView`).** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:658-694`
builds the whole `MaxNativeAdView` child tree — icon, title, star rating, media, body,
CTA — and never includes `MaxNativeAdOptionsView`. I read the file myself and confirmed
this directly: there is no reference to it anywhere in the file. AppLovin's Flutter
native-ad integration guide requires this view for policy compliance (it's the
AdChoices-equivalent privacy control). This is unconditional — **every** AppLovin native
ad impression from this SDK, on every consuming app, on both platforms, ships without it.
**Scope of impact**: only affects apps that (a) select AppLovin as a provider and (b) use
the native ad format specifically (`NativeAdWidget`/`buildNative()`). Banner, MREC, App
Open, Interstitial, and Rewarded are unaffected. **Fix is small and mechanical**: add a
correctly positioned `MaxNativeAdOptionsView` to the existing `Column` in
`_buildAppLovinNativeAd` (or wherever the AppLovin branch constructs its child tree), plus
a widget test asserting its presence.

### MAJOR (5) — real, don't block a general release, but need a tracked fix

1. **AppLovin stale-reward creativeId ambiguity can misattribute a reward to the wrong
   caller.** `applovin_adapter.dart:637-641,1844-1882,1903-1948`. This is in the fix I
   shipped THIS session (commit `8d8d990`, published as 2.9.21) to a prior, worse bug
   (100% of real callbacks discarded as stale). The new design correctly stops discarding
   real events, but when `MaxAd.creativeId` is empty or repeats (AppLovin's own
   test-mode creatives do this; some real mediated networks may too, per AppLovin's own
   Creative-ID support-matrix docs), a genuinely stale cycle-A reward event arriving after
   cycle B has begun showing gets attributed to **whichever caller currently occupies
   `_rewardedDone`** — i.e., cycle B — rather than being recognized as ambiguous. In the
   narrow window where A's 10s show-confirmation watchdog has just resolved A as
   `skipped` and B's `showRewarded()` has begun, a late A reward with an
   empty/repeated creativeId can tell B "your ad was shown, reward earned" before B's own
   ad has actually finished. I traced this myself (see `audit_claude_round42.md` for the
   full mechanism trace) and confirm it's real, though narrow (requires the exact
   timing race described). Needs a proper fix — a genuine per-show quarantine window or a
   native-round-tripped identifier — not a quick patch to the existing `_isStaleAd`
   comparison. Tracked as a named follow-up, not reverting `8d8d990` (the prior state was
   categorically worse: unconditional, 100%-of-the-time reward loss on every device).

2. **`vipAutoGrant` reuses the "ad reward earned" boolean for a no-ad VIP perk.**
   `ad_manager.dart:7778-7791`; demonstrated in `example/lib/main.dart:2982-3015`'s "Watch
   ad for +10 coins" button, which fires this path for VIP users with no ad ever
   requested. I downgraded this from codex's BLOCKER rating after direct verification:
   the path short-circuits before any provider is called, so it cannot violate
   AdMob/AppLovin's ad-serving reward policy (no ad request is made to either network in
   this path — their policy governs genuine ad-serving completion, not an entirely
   separate, already-documented, opt-in, caller-controlled entitlement decision that
   defaults to `false`). It IS a real API-naming/documentation smell and the bundled
   example's button text is misleading for this specific path. Fix: rename/split the
   signal (e.g. a distinct `RewardOutcome.vipBenefitGranted`) so a future integrator can't
   confuse it with provider-confirmed completion, and fix the example's button copy to
   disclose the no-ad VIP case.

3. **Dual-CMP conflict**: `disableAppLovinCmpFlow: false` (to deliberately use AppLovin's
   own CMP, per that flag's own doc comment) without also setting `autoRequestUmpConsent:
   false` runs BOTH consent flows concurrently on the same EEA user, and
   `consentFootgunWarning` never detects this specific combination despite the file's own
   stated philosophy of surfacing consent misconfigurations loudly. Found by my own
   consent subagent, not raised by either external reviewer. Not hit under any default
   config. Fix: add the missing warning condition (cheap, matches the existing pattern).

4. **Example app cannot validate AdMob on iOS.** `example/lib/main.dart:249-269` sets
   only the (Android-valued) shared AdMob test IDs, no `ios*Id` overrides for any format
   — an iOS run of the example silently exercises Android test ad units. Confirmed by
   direct read. This is an example/demo-quality issue, not a defect in the SDK library
   code itself, but it means the example — the reference integration a real developer is
   meant to copy and validate against — has never actually round-tripped AdMob on iOS.

5. **First CRL cache is trust-on-first-use.** `vip_manager.dart:195-215` — a rooted
   device could plant a self-signed, future-dated CRL before ever syncing a real one,
   permanently blocking that one device's future real revocations. Rooted-device-only,
   no cross-user impact, already partially self-diagnosed in the source's own comments.
   Found by my own trial/VIP subagent.

### MINOR (6) / NIT (2)

See `audit_claude_round42.md` and `audit_codex_round42.md` for full detail: AVP2
bundle-binding fail-open on `PackageInfo` failure (confirmed by two independent
reviewers), `CompatibilityMatrix` missing an (iOS, AppLovin) declaration (self-inflicted,
currently inert since CI doesn't exercise it), incomplete test-ad-ID footgun coverage for
`rewardedInterstitialId`/`mrecId`/`nativeId`, `NativeAdWidget`'s documented 120px height
example falling below AdMob's recommended medium-template minimum, undisposed
`RemoteSafetyDemoPage` in the example globally rewiring live safety config with no
cleanup, stale integration-test-file counts in `CLAUDE.md`/`CHANGELOG.md`, public
`bypassSafety` being a broad trust-the-caller escape hatch (already self-documented), and
a `vipKeyValidator` docstring that contradicts actual release-mode behavior.

## What's genuinely solid (independently confirmed by 2-3 sources, not just one reviewer's say-so)

- Offline/no-network handling: every network-dependent path is timeout-bounded, fails
  toward the safe/conservative direction, no hang or infinite retry found by 2
  independent full reads.
- Ad lifecycle (Banner/MREC/Native/App Open/Interstitial): no confirmed native-object
  leak or double-show path, confirmed by 2 independent full reads.
- Trial-mode clock-tamper defense (high-water mark + monotonic session anchor): real,
  correctly closes the "wind clock forward/back" attack — I verified the arithmetic
  myself.
- VIP Ed25519 signing: real cryptography, private key never ships, decompiling the public
  pub.dev source cannot forge a new valid code.
- Consent propagation to both providers for GDPR/CCPA/GPP/COPPA is correct under every
  *default* configuration and fails closed on read errors.
- pub.dev listing matches this checkout exactly (`2.9.21`), 150/160 pub points, no
  version drift, no unexpected analyzer warnings.

## Production-readiness verdict

**Conditional — not the gemini/agy blanket "yes," and not quite codex's blanket "no"
either. My own independent verdict, after personally re-verifying every severity-critical
claim against source:**

- **If the consuming app does NOT use AppLovin's native ad format**: the SDK is safe to
  ship to production today. The one confirmed BLOCKER is scoped entirely to that one
  format; every other surface (Banner, MREC, App Open, Interstitial, Rewarded, VIP,
  trial, consent) held up under three independent adversarial passes covering ~9
  subsystems, with only narrow, mostly-non-default-configuration MAJOR findings
  remaining — not "walk away" territory for a package this mature after 42 audit rounds.
- **If the app DOES use AppLovin native ads**: fix finding #1 first (small, mechanical:
  add `MaxNativeAdOptionsView`) — this is a real, unconditional AppLovin policy violation,
  not a hypothetical.
- **Before relying on this session's AppLovin rewarded-callback fix (2.9.21) at scale**:
  track MAJOR #1 above as a genuine follow-up. The current state is a large improvement
  over what shipped before today (100% reward loss → a narrow timing-race
  misattribution), but it is not the final word on that code path.
- **If AppLovin's own CMP is used instead of UMP**: explicitly set `autoRequestUmpConsent:
  false` alongside `disableAppLovinCmpFlow: false` — don't rely on the single-flag
  guidance in that field's own doc comment alone until MAJOR #3 is fixed.
- **Before using the bundled example as an iOS integration reference**: know that it has
  never actually validated AdMob on iOS (MAJOR #4) — populate real iOS test IDs and
  re-verify on a real device before trusting it as a cross-platform template.
- **Trial mode / VIP-by-code**: both are legitimate, well-engineered, backend-free
  designs with explicitly documented and bounded residual risk (Android
  reinstall/clear-storage bypass, cross-device code replay). Neither is a silent gap —
  both are self-diagnosed in the source with a stated business trade-off. Acceptable for
  production as long as the product owner has actually seen and accepted those
  trade-offs, not merely inherited them by not reading the doc comments.

**In short: yes, use it — for every format except AppLovin native ads until the
privacy-icon fix lands, and with the four MAJOR items above tracked as real follow-up
work, not dismissed as either "this SDK is broken" (codex's framing) or "nothing to see
here" (gemini/agy's framing).**
