# Audit round 42 — claude (in-session, 7 parallel subagents + direct verification)

Method: 7 independent `general-purpose` subagents, each given one whole subsystem end to
end (not a diff of recent changes), instructed to ignore `doc/audit/` prior history and
form an independent view from source, per this repo's own established audit method (see
`audit-must-be-slow-and-adversarial` session memory). I then personally re-verified every
finding a subagent or the two other independent reviewers (codex, gemini/agy) raised that
was rated MAJOR or above, by reading the cited source directly myself before accepting it
into this report — see "Findings I personally re-verified" below.

Scope split:
1. Cross-platform provider abstraction (Android + iOS)
2. Offline / no-network behavior
3. Ad type lifecycle correctness (Banner, App Open, Rewarded, Interstitial)
4. Trial mode (1-day) + VIP activation by code (no backend)
5. Consent for all countries (GDPR/CCPA/GPP/COPPA), both providers
6. AdMob/AppLovin policy compliance (with live WebFetch/WebSearch cross-checks)
7. Example app quality + pub.dev listing check

## Summary verdict from my own subagents (before cross-checking codex)

6 of 7 subagents found **no BLOCKER or MAJOR** in their subsystem. The exception was the
consent subagent (1 new MAJOR, a dual-CMP conflict) and the trial/VIP subagent (a
MAJOR-adjacent rooted-device CRL-cache gap). Two subagents' full write-ups are folded
into the findings below rather than reproduced separately since they overlap.

## Findings — new, not previously raised by round 1-41 or by codex/gemini this round

### MAJOR — dual-CMP conflict: `disableAppLovinCmpFlow: false` + default `autoRequestUmpConsent` runs two consent flows on the same EEA user

**File:** `packages/ad_sdk/lib/src/config/ad_config.dart:412` (`autoRequestUmpConsent`
defaults `true`), `:416,656-661` (`disableAppLovinCmpFlow` defaults `true`, doc comment
says "set false only if you deliberately use AppLovin's CMP instead of UMP"). Gap:
`packages/ad_sdk/lib/src/core/ad_manager.dart:349-364` (`consentFootgunWarning`).

`disableAppLovinCmpFlow`'s own doc comment tells an integrator to flip it to `false` to
use AppLovin's native CMP "instead of" UMP — but nothing forces or warns that
`autoRequestUmpConsent` must also become `false` at the same time. Following that doc
comment literally (only touching the one flag it names) leaves both consent flows
running concurrently for an AppLovin-only app: AppLovin's own Terms/CMP flow prompts the
EEA user (`applovin_adapter.dart:746-753` never disables it), and the SDK's own UMP flow
prompts the *same* user with Google's form, unawaited
(`ad_manager.dart:3588`, `runZonedGuarded`). Whichever result lands last
(`_applyUmpConsentResult` → `applyConsentToProviders`) overwrites
`AppLovinMAX.setHasUserConsent()`/`setDoNotSell()`, non-deterministically deciding which
of two separate consent transactions the AppLovin SDK actually ends up holding.
`consentFootgunWarning`'s `appLovinCmpCovers` check treats `disableAppLovinCmpFlow ==
false` as sufficient on its own and never checks whether `autoRequestUmpConsent` is
*also* still on — so this exact, doc-encouraged misconfiguration produces zero warning,
despite this file's own stated philosophy of surfacing every consent misconfiguration
loudly (see `coppaUmpMismatchWarning` for the pattern this should follow).

**Not hit under any default configuration** — requires the explicit, doc-encouraged
single-flag override. That is exactly why it survived 41 prior rounds: those rounds'
AppLovin-CMP scenarios apparently always paired both flags correctly by convention; this
is a first-principles trace of the documented single-flag path a real integrator would
follow from the doc comment alone.

**Fix (cheapest, matches this file's existing pattern):** also warn in
`consentFootgunWarning` when `appLovinCmpCovers && config.autoRequestUmpConsent`.

### MAJOR (rooted-device-only) — first CRL cache is trust-on-first-use, can permanently deafen future revocations

**File:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:195-215`

The very first CRL (VIP-key revocation list) cache on a device is verified against
whichever public key is embedded in the *cached record itself*, and
`refreshRevocationList` only ever accepts a **newer** `issuedAt` than what's cached. A
rooted device could pre-plant a self-signed CRL dated in the far future before ever
receiving a real one; the real CRL would then need a later `issuedAt` than that
fictitious future date to ever get accepted, which may never happen. This is already
self-diagnosed in the source's own doc comment (which frames it as a known, only
partially-mitigated gap: the device does eventually reconcile once a real CRL bearing a
later timestamp than the forged one shows up), and it only affects a device the attacker
has already rooted for their own benefit — it doesn't let one user forge VIP for a
different, unrooted user. Rated MAJOR rather than BLOCKER because the practical impact is
narrow (revocation-efficacy-only, single attacker's own device, no cross-user harm) but
it is a genuine, not-fully-closed gap worth a tracked follow-up.

## Findings I personally re-verified (from codex / cross-agent overlap)

I read the cited source directly for every MAJOR-or-above claim from codex before
accepting or adjusting its severity for the consolidated report. Full detail and my
severity reasoning is in `audit_round42_consolidated.md`; summary of what I checked
myself:

- **Confirmed as BLOCKER, read directly**: `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:658-694`
  builds the entire `MaxNativeAdView` child tree (icon/title/rating/media/body/CTA) with
  no `MaxNativeAdOptionsView` anywhere in the file. AppLovin's own native-ad
  documentation requires this for the mandatory privacy-information/AdChoices-equivalent
  icon. This is unconditional for every AppLovin native-ad impression — codex's BLOCKER
  rating is correct.
- **Confirmed as real, but downgraded from codex's BLOCKER to MAJOR**:
  `vipAutoGrant` (`ad_manager.dart:7778-7791`) reusing `onEarnedReward(bool)` to signal
  "VIP gets the perk with no ad shown." My own lifecycle subagent independently reached
  the same conclusion I did on direct read: this path never requests an ad from either
  network at all (VIP suppression short-circuits before any provider call), so it cannot
  violate AdMob/AppLovin's *ad-serving* reward-integrity policy — that policy governs
  what gets reported back to their ad-serving pipeline, not an entirely separate,
  documented, opt-in (`vipAutoGrant` defaults `false`), caller-controlled entitlement
  decision. It is a real API/naming and example-UX smell (the bundled example's "Watch ad
  for +10 coins" button fires this path for VIP users without disclosing no ad played)
  worth fixing, but does not meet the bar of "must not ship" the way finding 1 does.
- **Confirmed as real MAJOR, read directly**: the AppLovin stale-reward creativeId gap
  (`applovin_adapter.dart:637-641`, `1844-1882`) — see next section; this is in code I
  personally wrote and shipped this session (commit `8d8d990`, published as 2.9.21), so I
  verified it especially carefully rather than taking codex's word for it.
- **Confirmed as real MAJOR, read directly**: `example/lib/main.dart:249-269` sets only
  the shared (Android-valued) AdMob test IDs with no `ios*Id` overrides for any format —
  an iOS run of the example resolves Android test ad units for every AdMob surface.
- **Confirmed as real MINOR, matches my own trial/VIP subagent's independent finding**:
  AVP2's bundle-id binding (`vip_manager.dart:1357-1365`) fails open (skips the bundle
  check entirely) if `PackageInfo.fromPlatform()` throws. Two independent reviewers
  (codex and my own subagent) found this same line independently — raises my confidence
  it's real, not a misread.
- **Not independently re-verified in full depth, accepted at codex's stated severity**:
  findings 5 (native template height 120 vs recommended 320), 7 (public `bypassSafety`),
  8 (`vipKeyValidator` docstring) — read the cited lines, agree they're accurately
  described and the severity (MINOR/MINOR/NIT) is reasonable.

## My own re-verification of the AppLovin stale-reward gap (finding I shipped this session)

I fixed a BLOCKER in commit `8d8d990` (published as pub.dev 2.9.21) where 100% of real
AppLovin fullscreen `displayed`/`hidden`/earned-reward callbacks were discarded as
"stale" because the old guard compared Dart object identity against a plugin that
deserializes a fresh object per callback. The fix replaced identity with
`MaxAd.creativeId` comparison, deliberately trusting the callback whenever either side's
creativeId is empty (documented rationale: AppLovin's own test-mode creatives commonly
report an empty creativeId, and wrongly rejecting a real event is far more costly than
wrongly accepting a stale test-mode one).

Codex's finding 3 is a real, narrower residual gap in that same design that I did not
fully think through when I shipped it: the cost model I documented ("wrongly-accepted
stale test-mode event costs nothing, $0 either way") assumed the wrongly-accepted event
would be attributed to *no one in particular* or to a slot that's otherwise idle. Tracing
`showRewarded`'s actual mechanics (`applovin_adapter.dart:1903-1948`) shows this isn't
quite right: `_rewardedDone` holds whichever caller is *currently* in-flight, and a
second `showRewarded()` call can only begin once `AdSlot.beginShow()` succeeds — which
requires the *prior* cycle to have already left the `showing` state, including via the
10-second show-confirmation watchdog (`onShowNeverConfirmed`) firing and resolving the
old caller as `skipped`. In that specific window — cycle A's watchdog just fired,
`_rewardedDone` now belongs to cycle B, and cycle A's real native reward callback then
arrives late with an empty or coincidentally-repeated `creativeId` — the callback is
trusted (correctly, for the "is this genuinely stale" question) but gets attributed to
**whichever caller currently occupies `_rewardedDone`**, i.e., cycle B, not "no one." If
B's own ad hasn't actually finished yet, B incorrectly receives `earned: true` for
someone else's completion (A's), not simply "a harmless phantom test-mode event." Codex
is also correct that this isn't purely a test-mode concern: AppLovin's own docs describe
creativeId support as network/format-dependent within real mediation, so some genuinely
monetized networks in the waterfall may not populate it either.

This is a real, if narrow, correctness gap (needs: cycle A's watchdog to fire, cycle B to
begin showing within the same window, and a delayed native callback with an
empty/repeated creativeId) — I agree with codex's MAJOR severity, not BLOCKER (the
pre-fix state — 100% of rewards dropped on every device, unconditionally — was
categorically worse than this narrow race, which is why I don't consider this a reason to
revert 8d8d990). It needs a proper follow-up fix (a genuine per-show quarantine or
another native-round-tripped identifier, not another quick patch to `_isStaleAd`) rather
than being folded into this round's response, and I'm recording it here rather than
silently deferring it.

## Corroborating "what's actually solid" (cross-checked directly, not just relayed)

Everything below, I either read myself or a subagent traced end-to-end and I spot-checked
the specific citations — these are not just relaying codex/gemini's claims:

- Offline/no-network: every network-dependent await across UMP, adapter init, GAID fetch,
  remote-safety fetch, and ad loads is timeout-bounded; fail-closed on real errors,
  fail-open only for the debug/test "plugin not wired" case. No hang scenario found by
  either my subagent or codex.
- Ad lifecycle: no confirmed leak or double-show path in Banner/MREC/Native/App
  Open/Interstitial/Rewarded across two independent full reads (my subagent's, codex's).
- Trial-mode clock defense (high-water mark + monotonic session anchor) is real,
  correctly closes the "wind clock forward, redeem, wind back" attack, verified by
  tracing the arithmetic myself against `vip_manager.dart`'s `_effectiveNow`/`_isLive`.
- VIP Ed25519 signing is real cryptography (not a stub), private key never ships, mint
  tooling refuses `--priv` as a CLI arg specifically because argv is observable — a
  genuinely good detail, not just a doc claim.
- Consent propagation for GDPR/CCPA/GPP/COPPA (outside the one dual-CMP MAJOR above) is
  correctly wired to both providers, fails closed on read errors, and defaults toward the
  more consent-protective behavior for unrecognized jurisdictions.
- pub.dev listing (`https://pub.dev/packages/applovin_admob_sdk`, fetched live) shows
  `2.9.21`, matching this checkout's `pubspec.yaml` exactly — no version drift. 150/160
  pub points, the only deduction being the already-documented (`CLAUDE.md`) "gated on a
  Flutter/Dart SDK floor bump" dependency-freshness score.

## Minor findings (mine + corroborated)

- **MINOR** — `CompatibilityMatrix.minimum` (`lib/src/config/compatibility_matrix.dart:20-36`)
  has no (iOS, AppLovin) entry, so `isSupported()` reports `false` for a combination the
  adapter code actually handles fine. Self-inflicted doc/CI gap (CI's
  `compatibility-matrix` job only runs `platform: [android]` today, so it's currently
  inert), but contradicts the SDK's own dual-platform claim and would hard-fail CI the
  moment anyone widens that matrix to iOS without also adding this entry.
- **MINOR** — `packages/ad_sdk/lib/src/core/ad_manager.dart`'s test-ad-ID release guard
  (`_adUnitIdFootgunWarnings` and the release test-ID check) only covers
  `banner/interstitial/appOpen/rewarded`, not `rewardedInterstitialId`/`mrecId`/
  `nativeId` — a release build shipping a leftover test ID on those three specific slots
  gets no warning at all, unlike the identical mistake on the other four formats.
- **MINOR** — example app's `RemoteSafetyDemoPage` (`example/lib/main.dart:4349` onward)
  has no `dispose()` at all despite owning an un-disposed `ValueNotifier` and, more
  importantly, having globally rewired the live `AdManager`'s safety config via
  `initialize(remoteSafetyProvider: _provider, ...)`. Navigating away without tapping the
  page's own "Restore demo defaults" button leaves the app's real ad-safety config
  altered for the rest of the session. A production app copying this pattern for its own
  remote-config screen would inherit the same class of bug.
- **MINOR** — stale integration-test-file counts in `CLAUDE.md` ("52 files") and
  `CHANGELOG.md` ("65/65", 2 releases old); actual count in this checkout is 132 test
  suites + 1 helper = 133 files. Doc-only, but materially understates
  `sdk-integration-ios`'s real per-shard wall-clock time for anyone estimating CI cost
  from the docs.

## Direct answers to each area of the user's request

1. **Provider abstraction works for Android + iOS**: yes, mechanically — no
   platform-channel argument mismatch found, ATT/COPPA/ad-unit-resolution all correctly
   platform-gated. Two caveats: the package's own AppLovin *native ad* layout violates
   AppLovin's own mandatory layout on **both** platforms (finding 1, BLOCKER), and the
   bundled example cannot actually validate AdMob on iOS because it never sets iOS test
   IDs (MAJOR, example-only).
2. **Works with/without network**: yes. Every network-dependent path is bounded and
   fails toward the safe/conservative side; no hang or infinite-retry found by either
   independent reviewer.
3. **Ad-type correctness, legal, lifecycle, no leaks**: yes for lifecycle/leak safety
   across all 4 core formats (2 independent full reads agree). Reward-integrity has one
   real MAJOR residual gap I introduced this session and am flagging for follow-up
   (creativeId ambiguity), separate from the VIP-auto-grant naming issue (also MAJOR, not
   an ad-serving policy violation).
4. **Trial mode (1 day)**: real, correctly-implemented clock-tamper defense; a documented,
   accepted Android reinstall bypass (bounded damage, not a silent gap).
5. **VIP by code, no backend**: real Ed25519 offline verification, correctly can't be
   forged from the published source; cross-device replay is inherent-and-accepted;
   two real, fixable gaps (AVP2 bundle-fail-open MINOR, first-CRL-cache trust-on-first-use
   MAJOR-on-rooted-devices).
6. **Consent for all countries, both providers**: yes for all default configurations;
   one real MAJOR gap in a specific, doc-encouraged non-default configuration
   (AppLovin-native-CMP override without also disabling UMP).
7. **AdMob/AppLovin policy compliance**: not fully compliant as shipped — the AppLovin
   native-ad privacy-icon omission is an unconditional, confirmed policy violation for any
   app using that format. Reward-granting, COPPA/GDPR signal separation, and
   test-ID-vs-production separation in the example are otherwise policy-correct.

See `audit_round42_consolidated.md` for the final cross-reviewer severity table and
production-readiness verdict.
