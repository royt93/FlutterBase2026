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

## Still open (not part of round 7's scope)

* Two Minors: an `AdSlot` that is `reset()` but whose ad object is never
  disposed. `AdSlot.reset()` already cancels its watchdogs (round-7 Minor fix);
  the disposal half is untouched.
* Device verification of the consent path under EEA debug geography. Green
  tests do not prove the UMP path works on hardware — that lesson is already
  paid for once (`tcfConsentString` passed four rounds while returning null on
  every real device).
* pub.dev 2.3.2 is live and still carries the z2 Blocker. Everything above is
  unpublished.
