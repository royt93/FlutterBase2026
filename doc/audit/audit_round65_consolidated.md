# Audit round 65 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD (round 64's fix + doc on top of round
63's fix; published pub.dev **3.0.2**, `pubspec.yaml` still `3.0.2`,
CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, per round 64's recommendation to pick the
next stalest under-audited area now that the deliberately-targeted list
of large safety-critical files (`ad_manager.dart`, `ad_config.dart`,
`ad_safety_config.dart`) is exhausted.

1. **Fork W** — fresh, assumption-free re-read of all 11 files in
   `lib/src/widget/` (4487 lines), last independently full-passed round
   57 (8 rounds ago). Deliberately did not trust round 57's "clean"
   verdict.
2. **Fork A** — fresh full pass over `lib/src/adapters/applovin_adapter.dart`
   (2821 lines) and `lib/src/adapters/admob_adapter.dart` (2620 lines),
   last dedicated full pass round 58 (7 rounds ago). Also directed to
   resolve round 58's flagged-but-unconfirmed lead about the missing
   `_isStaleAd` guard on click callbacks.

Both forks directed to hunt the recurring bug shapes this session keeps
finding: clock-rollback gaps, two independent paths touching one shared
mutable field inconsistently, cross-cycle/cross-adapter callback identity
gaps (round 49's `creativeId` fix class), and copy-paste drift between
the banner/mrec/native widgets or the AppLovin/AdMob adapters.

## Findings

**1 real, MAJOR.** Found and fixed same-day, never shipped.

### Fork W: `native_ad_widget.dart` missing R46-03's cross-adapter identity guard on load callbacks

Round 46 (R46-03) added `if (!identical(adapter, capturedAdapter)) return;`
to `_AppLovinMaxNativeView`'s `onAdClickedCallback`/`onAdRevenuePaidCallback`,
because a `destroy()` + re-`initialize()` swap hands the widget's platform
channel a brand-new `AppLovinAdapter` instance, and a late callback still
closing over the old one falling through to `AdManager().adapter` would
land on the new session.

`onAdLoadedCallback`/`onAdLoadFailedCallback` never got the same guard.
The existing doc comment reasoned this was safe because a disposed-key
write throws (caught by the surrounding `try/catch`) — but that reasoning
only covers a **same-adapter** per-key dispose via the `_disposedNativeKeys`
tombstone. It does not cover a **cross-adapter** swap: the new adapter's
registry has never heard of the old `instanceKey`, so `adapter.native(instanceKey)`
doesn't hit any disposed sentinel — it creates a brand-new **live**
`BannerListenables` entry in the new adapter's registry and sets
`isLoaded.value = true` (or `markError()`), contaminating the new session
with a stray entry from a widget instance that no longer belongs to it.
Same contamination class R46-03 exists to prevent, on the two callbacks
that were missed when that fix was written.

Verified empirically: a throwaway probe (mirroring the existing
destroy+reinit click test) swapped in a fresh `AppLovinAdapter`, fired
`onAdLoadedCallback` with the OLD listener closure, and confirmed
`newAdapter.native(instanceKey).isLoaded.value` was `true` before the fix
(RED).

**Fix:** added the same `identical(adapter, capturedAdapter)` guard to
both callbacks (`lib/src/widget/native_ad_widget.dart`, 2 lines). 2 new
regression tests in `test/native_ad_widget_test.dart` (load-succeeded and
load-failed siblings). Confirmed GREEN after.

### Fork W: checked and ruled out (not bugs)

- `banner_ad_widget.dart` / `mrec_ad_widget.dart` have no equivalent gap
  — they use an adapter-push model (`preloadBanner`/
  `loadAdmobBannerIfNeeded`), not native's self-loading
  `MaxNativeAdView` callbacks, so this bug class is structurally
  native-only.
- `banner_ad_widget.dart`: full mounted-guard / Timer-cancellation /
  RouteAware / TickerMode / VisibilityDetector trace — consistent with
  rounds 29/31/39/46, no drift.
- `mrec_ad_widget.dart`: faithful mirror of banner minus AdMob adaptive-
  width machinery — no drift.
- `ad_loading_dialog.dart`: epoch/generation logic (MJ16/MJ17/T115/T13)
  still closes every show/showAdBuffer/dismiss/resetState race.
- `ad_readiness_splash_controller.dart`: `_navigated` (round 26) /
  `_started` (T134) guards correctly short-circuit every late-callback /
  double-start path traced.
- `adaptive_ad_surface.dart`: fullscreen-busy re-check inside the
  debounced Timer (round 29) is self-correcting once fullscreen clears.
- `debug_ad_overlay.dart`, `revenue_panel.dart`, `top_toast.dart`,
  `shimmer_view.dart`: `kDebugMode`-gated or cosmetic; dispose/Timer/
  animation-cancellation correct.
- **Low-confidence lead, not a bug:** `inline_ad_controller.dart::attach()`
  applies a pending pause before consuming `_pendingRefresh`, so a
  `pause()` + `refresh()` both called while detached can skip the
  eventual `controllerRefresh()` call. Traced the full path: a later
  `resume()` independently triggers `_initBanner`/`_initNative` if the
  widget never loaded, so the net effect is equivalent to the refresh
  happening anyway. Not calling it a bug today; flagged in case a future
  change to the resume path removes that self-correction.

### Fork A: no findings — adapters genuinely clean, round 58's lead resolved

Traced the full load→show→dismiss→reload cycle for all 4 fullscreen ad
types (App Open/Interstitial/Rewarded/RewardedInterstitial) in both
adapters side by side — `cycleEnded`/quarantine/identity guards correct,
no drift between providers on any of the recurring bug shapes. `isAdFresh`'s
clock-rollback guard (`age.isNegative`) correct. Both adapters' `dispose()`
reset every field with no shared-state gap. Banner/MREC/native inline
click-guards (`isCurrent(key, slot)`) present and consistent across both
adapters and all 3 inline formats.

**Round 58's flagged lead — resolved as not a bug.** Round 58 noted
`onAdClickedCallback` for App Open/Interstitial/Rewarded in
`applovin_adapter.dart` has no `_isStaleAd` guard, unlike
displayed/hidden/revenue/displayFailed on the same listeners, and
couldn't confirm from source alone whether it mattered. This round
confirmed the identical shape exists symmetrically in
`admob_adapter.dart` across all 4 fullscreen types — not provider-specific
drift, a consistent design choice. Reason it's harmless:
`AdSafetyConfig.recordAdClick(fullscreen: true)` is a format-agnostic
aggregate CTR-fraud counter with no per-cycle argument, and the emitted
`AdClickEvent` is always correctly labeled for the listener it fired on
regardless of which physical ad cycle triggered it — unlike
displayed/hidden, a late click has no per-cycle mutable state to corrupt;
it's a real click that happened, and counting it late misattributes
nothing. Also confirmed the tracked creativeId used by `_isStaleAd` can't
change while an ad is genuinely on-screen (it only updates on the next
`onAdLoadedCallback`, which for fullscreen types only fires after
dismiss+reload, never concurrently with an active display). Closing this
lead permanently.

Also checked and ruled out: both adapters' `onAppPaused`/`onAppResumed`
deliberately excluding native ads from the background auto-refresh hold
— correct, since neither provider's native ads have an auto-refresh
ticker (load-once, self-contained); fullscreen-hide already covers native
separately since round 44.

## Test status

Full `packages/ad_sdk` suite: **2204/2204 passing** (2202 baseline + 2
new regression tests). `flutter analyze`: 0 issues.

## Publish-gate status

Round 65 found & fixed 1 real MAJOR — not clean. Rounds 57 through 65
have each found at least one real issue except round 64 (7 MAJOR + round
57's self-introduced-and-fixed bug + 2 MINOR through round 63, plus round
65's finding here); the two-consecutive-clean-rounds bar remains unmet.

## Recommendation

No blockers — round 65's finding never shipped. `lib/src/widget/` and
`lib/src/adapters/` have both now had a fresh full pass this session,
closing the two areas round 64 identified as stalest. With the
deliberately-targeted list of large/stale files exhausted a second time,
remaining unaudited surface is comparatively smaller/lower-blast-radius
(`ad_preferences.dart`, `iab_storage.dart`, `ump_consent.dart`,
`ad_slot.dart`, `consent_manager.dart`, `ad_provider_adapter.dart`) —
flagging back to human for the publish decision or a round 66 targeting
one of those.
