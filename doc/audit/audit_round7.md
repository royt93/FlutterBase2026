# Audit round 7 — outcome

Four independent auditors, one zone each, run against worktree snapshots of the
package on 2026-08-22/23. Zones:

| Zone | Scope |
|---|---|
| z1 | Ad lifecycle & memory (banner/MREC/interstitial/rewarded, both providers) |
| z2 | Consent (UMP, TCF, withdrawal) on both providers |
| z3 | VIP entitlement & storage |
| z4 | Safety layer, policy compliance, recovery loops |

**Verdict: 2 Blockers + 12 Majors, all closed.** `flutter analyze` clean,
1038 tests green.

## Findings → fix

| # | Severity | Finding | Fixed by |
|---|---|---|---|
| z2-1 | **Blocker** | UMP `obtained` treated as consent to personalised ads | `f5fb1a0` |
| z4-1 | **Blocker** | Rate limiter left banner/MREC permanently blank | `226a8fa` |
| z1-1 | Major | `_lastRecoveryBypassAt` held widget `State` keys forever, broke same-key remount | `226a8fa` |
| z1-2 | Major | AppLovin resurrected a banner/MREC disposed mid-`await`, leaking the native AdView | `c966504` |
| z1-3 | Major | AppLovin banner/MREC could stick in `loading` forever | `5acc14e` |
| z1-4 | Major | Interstitial/rewarded could stick in `showing` on both providers | `4de7f96` |
| z2-2 | Major | Privacy Options / re-consent did not lock ads while the native form was open | `4159db7` |
| z2-3 | Major | Consent withdrawal did not invalidate the load in flight | `883a448` |
| z2-4 | Major | A missing UMP channel failed OPEN, in release too | `7a93065` |
| z3-1 | Major | A transient secure-storage read error cost a paying customer their VIP for the session | `a5627d6` |
| z3-2 | Major | The cached CRL was never applied on a plain startup | `50b2d30` |
| z4-2 | Major | The ad-click latch was not spent by the resume that saw it | `24d63e8` |
| z4-3 | Major | A host re-init forgave the invalid-traffic escalation | `a70324c` |
| z4-4 | Major | The M6 fallback clamp rolled forward on every launch when its save failed | `e561902` |

## Three findings were already fixed before they were reported

The auditors read scratchpad worktree snapshots taken before some of the
session's own commits landed, so three of the above were reported as open
against code that no longer existed:

* z1-1 and z4-1 — `226a8fa` had already deleted `_mayBypassBackoff` and the
  `_lastRecoveryBypassAt` map and split `hasError` (display-only) from
  `needsRecovery`. The z4 Blocker's step 7 ("later resumes no longer enter
  recovery") does not hold at HEAD: the recovery loops key on `needsRecovery`.
* z2-1 — `f5fb1a0` had already replaced the `ConsentStatus.obtained` inference
  with `IabStorage.tcfAllowsPersonalisedAds()`. The z2 snapshot's copy of
  `iab_storage.dart` contains zero occurrences of that method.

Confirmed by `git log -S`, not by reading the reports.

## Deliberate non-fixes — do not re-open

* **`redeemSignedKey` works offline.** A product requirement (no backend), not
  a gap. The signature is verified locally against the shipped public key.
* **`kQaTestDeviceHashes` is always on.** QC's own AdMob test-device hashes,
  deliberately compiled in so QA never serves live ads by mistake.
* **MJ9 (clock-forward trial abuse).** Cannot be closed in pure Dart; decided
  three sessions running. See `mj9` note in `doc/audit/audit_claude.md`.
* **m25 (native ads have no RouteAware lifecycle).** The SDK ships no native ad
  surface; nothing to hook.
* **CI is red on GitHub billing, not on code.** Not to be "fixed" here.

## Accepted trade-off — the 15-minute UMP backstop

codex flagged the backstop itself as a Major in round 8: it releases the
fullscreen-ad block without evidence that the native form is gone, so in
principle an ad can be drawn over a form that is still up — the same hole the
release-on-timeout bug had, only 15 minutes later.

That is accurate, and it is deliberate. The alternative is no backstop, and
then a dismiss callback that never fires (a form torn down by the OS, a plugin
that drops the callback) blocks **every** fullscreen ad for the rest of the
process — a permanent revenue outage triggered by a platform bug we cannot see.
Both failure modes are one-sided, so the question is only which one is bounded:
the backstop is 15 minutes of exposure in a case that requires a broken
callback, versus an unbounded outage in the same case.

Fifteen minutes is chosen to sit far outside a human reading a real GDPR form
(the 206-partner list with "Learn more" expanded is minutes, not a quarter of an
hour), and firing it logs a warning naming the reason. Anything shorter starts
competing with real users again.

What would remove the trade-off: a platform signal for "is a UMP form currently
presented", which the UMP SDK does not expose. Until then this stays.

## Known limitation — a cached AppLovin fill outlives a consent change

Reported by codex as a Major in the round-7 QC gate. It is real, and it cannot
be fixed from Dart.

When consent changes mid-session, `AdSlot.consentEpoch` is bumped and every
slot loaded under the old epoch is marked `loadedUnderStaleConsent`, so the SDK
refuses to *show* it and reloads instead. That covers the AdMob side, where the
Dart layer owns the ad object and dropping the reference drops the fill.

AppLovin MAX does not work that way. Interstitial and rewarded fills are cached
**inside the native SDK**, keyed by ad unit, and `applovin_max 4.6.0` exposes no
eviction API — `destroyWidgetAdView` and the banner/MREC destroy calls only
reach widget-based surfaces. So after a consent change the native cache may
still hold a fill requested under the old consent string; the SDK's own reload
request goes out with the new one, but which of the two MAX serves is MAX's
decision, not ours.

Practical exposure is one already-cached fullscreen ad, on the AppLovin path
only, for one impression after a consent change — and MAX is documented to
attach the current consent flags at *request* time, which is the reload we do
issue. What is **not** verified is whether MAX actually discards the stale
cached fill.

What would close it: on-device verification (grant consent, load an
interstitial, revoke via the privacy-options form, show) with a MAX debug build,
and if the stale fill is served, a native-side patch to `applovin_max` — same
category as MJ9, an issue whose fix is out of reach of pure Dart, not an issue
the audit missed.

## Still open (not part of round 7's scope)

* ~~Two Minors: an `AdSlot` that is `reset()` but whose ad object is never
  disposed.~~ Re-checked line by line and **not reproducible**: every
  `*Slot.reset()` call site in `admob_adapter.dart` (the stale-at-show discards
  at ~853/1117/1303/1483, the `drop()` helper in `discardCachedFullscreenAds`,
  and `dispose()` itself) already calls `_disposeAd(...)` on the ad object first,
  and both adapters dispose every fullscreen slot plus the union of all per-key
  banner/MREC/native maps in `dispose()`. `AdSlot` holds no ad object at all —
  it is pure state — so `reset()` has nothing to leak. The AppLovin side has no
  Dart ad object for fullscreen at all (see the cached-fill limitation above).
  Nothing left to fix here.
* Device verification of the consent path under EEA debug geography. Green
  tests do not prove the UMP path works on hardware — that lesson is already
  paid for once (`tcfConsentString` passed four rounds while returning null on
  every real device).
* pub.dev 2.3.2 is live and still carries the z2 Blocker. Everything above is
  unpublished.
