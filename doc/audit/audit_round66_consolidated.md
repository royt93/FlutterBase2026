# Audit round 66 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `21c8363` (round 65's fix + doc on top
of round 64's doc; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, continuing round 65's recommendation to
work through the remaining, comparatively-smaller-blast-radius files
that have never had a dedicated full pass this session.

1. **Fork C** — `lib/src/core/ump_consent.dart` (535 lines) +
   `lib/src/core/iab_storage.dart` (624 lines). Last dedicated full pass
   round 56 (10 rounds ago). Also spot-checked (not full-audited)
   `ad_manager.dart`'s call sites into both files for the round-46/62/63
   shared-mutable-state drift class.
2. **Fork P** — `lib/src/utils/ad_preferences.dart` (1041 lines) +
   `lib/src/state/ad_slot.dart` (517 lines) + `lib/src/core/ad_provider_adapter.dart`
   (433 lines, exported interface — no interface-change proposals per
   this repo's own "adding a member is breaking" convention). No round
   had given these 3 files a dedicated full pass together before.

## Findings

**None.** Both forks report clean after real, adversarial full passes —
first double-clean-fork round since round 64.

### Fork C: `ump_consent.dart` / `iab_storage.dart` — no findings

Re-verified `markUmpFormOnScreen()`/`release()` ref-counting (round 7),
`requestUmpConsentFlow()`/`requestPrivacyOptionsFlow()` dismiss-completer
double-complete guards, GPP two-segment parsing (round 56), the US-state
bitfield true-beats-false combination logic, and `tcfAllowsPersonalisedAds()`'s
fail-closed contract — no regressions, no drift.

Two leads traced and explicitly ruled out as **vendor-package properties,
not SDK bugs**:
- `requestConsentInfoUpdate`'s completer lacks an `isCompleted` guard
  (unlike every other completer in the file) — traced into
  `google_mobile_ads`' `UserMessagingChannel.requestConsentInfoUpdate`
  source: structurally exactly one of success/failure ever fires, so the
  missing guard is cosmetic, not exploitable.
- That same vendor method is declared `async` returning `void` (not
  `Future<void>`) — per Dart semantics, a non-`PlatformException` throw
  after its first `await` would escape as an unhandled zone error,
  uncatchable from this SDK's calling code. Confirmed vendor-side, and
  confirmed the only realistic trigger (unregistered platform channel)
  would already break every other MethodChannel call this SDK makes —
  not a narrower SDK-specific risk worth a defensive wrap.

### Fork P: `ad_preferences.dart` / `ad_slot.dart` / `ad_provider_adapter.dart` — no findings

Re-verified the singleton-init `Completer` guard (round 30), confirmed
no real read-modify-write race on the legacy `SharedPreferences` cache
(synchronous mutation before any `await` yields control — no
interleaving window), re-verified `clearSdkData`'s 32-key vs. 15-entry
entitlement-key bucketing by hand (every key in the correct bucket), and
cross-checked all 14 real `.reset()` / `beginLoad()` call sites in both
adapters for the round-46 "stale value read across a cycle boundary"
class — none found.

One fragility named, not a bug: `ad_slot.dart`'s `_watchdogTimer` is only
cancelled by `reset()` and `armLoadWatchdog()`'s own top-of-function
cancel — `markReady()`/`markFailed()` don't defensively cancel it
themselves. Every one of the 14 real call sites today pairs
`beginLoad()`/`beginReload()` with an immediate `armLoadWatchdog()` call
with no `await` in between, so no live failure scenario exists — but the
safety property depends on caller discipline rather than the class
enforcing it. Worth remembering if a future load path is added without
that pairing; not fixing today since there's nothing to regression-test
against.

## Test status

No code changed this round. Full `packages/ad_sdk` suite unaffected:
**2204/2204 passing** (baseline carried from round 65), `flutter
analyze`: 0 issues.

## Device smoke test (S24 Ultra, SM-S928B, Android 16)

Built and installed current `main` HEAD (round 65's fix included) as a
debug APK. Navigated Banner ad, Native ad, and Native demo's shimmer
placeholders. Confirmed **no crash** across the session (app stayed in
foreground throughout). Confirmed **layout**: both the native ad's
`AndroidView` (round 65's fix target) and the banner's shimmer
placeholder span the full width of their parent container
(1013/1013 logical px, edge-to-edge) — no narrow/misaligned rendering.
Neither native nor banner received a real ad fill during this test
window (native stayed on its gray placeholder; banner's container
collapsed to zero height, matching AdMob's documented "hides on no
fill" behavior) — this is ad-serving fill variability on this
device/session, not a layout or code regression, and out of scope for
what round 65's fix (a cross-adapter `destroy()`+re-init identity guard)
changes. The specific scenario round 65 fixed — a live callback racing a
`destroy()`+re-init swap — isn't reachable through normal UI navigation;
it remains covered by the two new unit regression tests, not this
manual pass.

## Publish-gate status

Round 66 found **zero** real issues across both forks — clean. Round 65
found 1 real MAJOR (not clean). The two-consecutive-clean-rounds bar is
**still unmet**: round 64 was clean, round 65 broke the streak, round 66
is clean again but alone. Round 67 would need to also come back clean to
satisfy it.

## Recommendation

No blockers — nothing shipped between rounds 65 and 66 needed fixing.
Remaining never-dedicated-full-pass surface after this round:
`lib/src/consent/consent_manager.dart` (417 lines — spot-checked via
call sites only during round 63, never itself full-passed this
session), and any file not explicitly named across rounds 57-66.
Flagging back to human for round 67 direction or a publish decision.
