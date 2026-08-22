# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — lifecycle & cache-expiry round (audit MINOR m15/m16/m18/m22/m24/m36)

Each item below is backed by a test that was verified red against its own
reverted fix, and nothing else.

- **A cached ad could read as "fresh" for the rest of the session after a
  clock change.** The freshness check compared wall-clock `now` against the
  wall-clock load stamp with no lower bound, so a backwards clock change
  (manual, or an NTP correction) put the stamp in the future, made the computed
  age negative, and kept the ad inside its validity window forever. Both the
  reuse-on-load and the refuse-to-show-a-stale-ad guards stopped working. A
  negative age now counts as stale.
- **Discarding an expired ad blocked its own replacement.** All four AdMob
  full-screen formats recorded a cache expiry as a *load failure*, which starts
  the exponential-backoff cooldown. The refill fires from the very callback the
  discard invokes, so it landed inside a cooldown window the discard had just
  created and the slot stayed empty until the next periodic retry — no ad for
  the next several show attempts. An expiry now just empties the slot; the load
  path never failed.
- **`canShowInterstitial()` / `canShowRewardedAd()` could report `true` for an
  ad that would not be shown.** Both only asked whether the slot was ready, so
  a cached AdMob ad that aged past its 1h content validity while the host was
  polling still reported showable — and the show call then discarded it. A host
  gating a button on these got a button that did nothing.
- **Revenue could be reported for a disposed full-screen ad.** Every
  `google_mobile_ads` wrapper cleared its full-screen content callback on
  dispose but left the paid-event listener wired, so a paid event arriving after
  disposal still emitted revenue through the old event sink.
- **AppLovin: destroy retries outlived the adapter.** The retry that makes
  `destroyWidgetAdView` succeed once the native view has finished detaching
  slept on an untracked timer, so a chain started by the last widget unmount
  before teardown kept calling into the bridge for up to ~1.7s after
  `dispose()` had already cleared every native listener. The retries are now
  cancelled by `dispose()`.
- **Per-widget notifiers were leaked when a key never got a slot.** Both
  adapters' `dispose()` walked only the slot maps, but the per-key listenable
  bundles (and AppLovin's per-key ad-view-id notifiers) are created
  independently of the slot, so any key that only ever had those kept its
  `ValueNotifier`s alive for good.

## [2.3.2]

### Fixed — independent review, round 3

Two independent QC passes over the round-5 work found these. As above, each
claim is backed by a test verified red against its own reverted fix.

- **AppLovin native ads never came back after a consent change.** Withdrawing
  personalisation consent (or closing and reopening the consent gate) makes the
  widget drop its live native instance and immediately re-load — reusing the
  same instance key, because that key *is* the widget's `State`. A tombstone
  added to stop late callbacks from resurrecting a dead key was permanent, so
  the reload got a disposed slot and disposed `ValueNotifier`s instead: the ad
  never returned for the rest of that widget's life, and callbacks wrote to
  disposed notifiers. The tombstone is now lifted when a live widget re-loads
  the key, while a late callback for a key nobody revived still gets the shared
  disposed sentinel — so the leak the tombstone exists to prevent still cannot
  happen. AdMob was unaffected (it guards by slot identity, not by key).
- **A throwing event-bus subscriber could take down the splash screen.**
  `SimpleEventBus.fire` guarded every listener so one failure couldn't block
  the others, but the later-added replay in `listen` did not — so a subscriber
  that threw escaped straight out of `listen()` into its caller. Per the
  integration contract that caller is a `listen()` line in the consuming app's
  splash. Guarded, matching `fire`.

### Fixed — independent review, round 2

A second independent reviewer went over the round-5 diff after it shipped
(same discipline as the first: every claim below is backed by a test that
fails against the reverted fix, not taken on trust).

- **An abandoned consent form could mute the UMP gate for the rest of the
  session.** The round-1 fix for "the backstop could present a second form on
  top of one our own timeout couldn't close" simply stopped retrying entirely
  once that happened — worse than not having the fix at all: a user who
  answered the still-open native form 10 seconds later got zero ads until an
  app restart, whereas the un-patched backstop at least kept retrying and
  could reopen the gate. Both the periodic backstop and the reconnect retry
  (which never checked this state at all) now recheck Google's local,
  already-cached consent decision — no form, no network call — so they can
  self-heal without risking a second dialog.
- **The App Open hard-cap watchdog compared a field to itself.** It read
  `_appOpenAd` fresh when the timer fired and checked that value against
  itself, which is always true and guards nothing. Not reachable through any
  load/show path today (other guards happen to cover it), but a maintenance
  hazard for the next change here — fixed to capture the specific ad at arm
  time, same as every other call site in the file already does.
- **A test canary asserted its own hand-rolled copy of a config object,
  never production's.** Deleting the field it exists to guard from the real
  code left the test green. The production build is now exposed for the test
  to call directly.

### Fixed — 8 of 12 round-5 fixes that shipped with no regression test

Same review found a large fraction of round-5's diff was revertible in bulk
with the suite staying green — the fix existed but nothing exercised it. Each
one below now has a test verified red against its own reverted fix:

adapter-orphan-on-failed-init disposal, the new banner/MREC/native load
watchdog (plus its dead-cache cleanup and a dispose-during-await race in the
banner path), the AppLovin COPPA re-init reachability fix, the UMP mutex's
240 s self-heal timeout, `AdLoadingDialog.show()`'s flag-ordering fix, and
the banner widget's consent-withdrawal listener (the fix already existed;
only a counter was asserted, not the widget behaviour it drives). Two related
fixes — the identical one for MREC/native widgets, and a rewarded-dialog
ownership check that turned out to be unreachable through any current call
path — remain unverified; see `doc/audit/audit_claude.md`'s handover section.

Round-5 audit, commits 2–3: the rest of the consent surface, then the
fullscreen-lifecycle failures that could kill a surface for a whole session.

### Fixed — issues found by an independent review of the fixes above

An independent reviewer was pointed at the round-5 diff before it shipped. It
found that three of the flagship fixes did not work on their own main path, and
that one of them made a transient hang permanent. All of it was confirmed by
reading the code, not taken on trust — and one of the reviewer's own
recommendations was rejected after reading the test that documents the opposite
invariant (see below).

- **The "withdrawing personalisation discards cached ads" fix was dead code.**
  It compared `_consent` against the incoming consent inside the listener, but
  `setConsent()` assigns `_consent` *first* and only then calls
  `ConsentManager.set()`, whose `ValueNotifier` notifies synchronously — so the
  listener always saw the new value on both sides and the guard could never
  fire. Every withdrawal route (`showPrivacyOptions()`, `requestUmpConsent()`,
  a host's own `setConsent`) goes through exactly that sequence, so personalised
  fullscreen ads already in the cache were still shown. Now compares against
  what was last actually applied to the adapter, which no assignment order can
  break. Regression test included, and verified to fail against the old code.
- **Its inline-ad half was a no-op too.** Bumping `initRevision` cannot rebuild
  a banner that is already showing: each widget's listener only re-inits when it
  has no ad, and withdrawing personalisation does not close the `canRequestAds`
  gate that would clear that state. A dedicated `personalisationRevision`
  signal now tells banner/MREC/native to drop their live instance and reload.
- **The COPPA-on-AppLovin recovery could not be reached.** `setConsent()`
  returned early when the SDK was not initialised, *above* the block that
  rebuilds the adapter — but the child-directed abort is exactly what leaves it
  uninitialised, so the host's later "not a child after all" call returned
  before the recovery ran. The block now runs first, and the last known-good
  config survives adapter teardown so there is something to rebuild from.
- **The new banner/MREC/native load watchdog relabelled the slot without
  clearing the dead ad.** `loadBanner` early-returns while the key is still in
  `_bannerAdsByKey`, so the cached-but-dead ad blocked every later load for
  that widget instance; only a remount (which produces a new key) appeared to
  recover. The watchdog now drops the ad object as `onAdFailedToLoad` does.
- **The UMP in-flight mutex had no deadline** — the one guard added this round
  without one. `setConsent` → `_persist()` → `updateRequestConfiguration` are
  all unbounded, so a single wedged channel meant every later
  `requestUmpConsent()` joined a future that could never complete: the gate
  would stay shut with no self-heal, strictly worse than the lockout this round
  set out to fix. Now capped at 240 s, and the lock is only released by the
  call that owns it.
- **After the 180 s form timeout the periodic backstop could present a second
  consent form** on top of the first, which `Future.timeout` does not close.
  The backstop now recognises that state and rechecks Google's already-cached
  consent decision (no form, no network call) instead of presenting another
  one — see "Fixed — independent review, round 2" below for why the first cut
  of this (standing down entirely) was itself a regression.
- Smaller ones from the same review: the IAB read's deadline now covers
  `PackageInfo` (an unbounded channel it was skipping), `AdLoadingDialog.show()`
  got the same flag-ordering fix its sibling already had, the rewarded path no
  longer claims ownership of a dialog it did not open, and the App Open hard cap
  clears the field by identity like the callbacks do.

### Changed — after the review

- `AdConfig.autoShowConsentDialog` now documents that it has **no effect** with
  the default `autoRequestUmpConsent: true`. The behaviour was introduced above
  on purpose — the built-in dialog is not a certified CMP and produces no TCF
  string — but shipping a default-true flag that silently does nothing, with no
  word in its own doc, is its own kind of trap.
- `shared_preferences_android` is declared without an upper bound. A `<3.0.0`
  cap would become a new pinning wall for every consuming app the moment
  `shared_preferences` requires 3.x. A compile-time canary test guards the
  platform API this package leans on instead.

### Fixed — lifecycle (commit 3)

- **App Open could die for the rest of the session, and leak two native ads
  doing it.** After the 90 s hard cap force-dismissed a show, AdManager
  reloaded and a new ad took the field — and then the abandoned ad's native
  callback arrived and cleared that field unconditionally, destroying the
  replacement. `appOpenSlot` still reported ready, so `showAppOpen` returned
  false against a null ad forever, and `_retryRefillAds` only refills
  idle/cooldown slots so nothing repaired it. Callbacks now clear the field
  only while it still points at their own ad, and the watchdog disposes the ad
  it gives up on instead of just forgetting it.
- **The App Open watchdog was armed after `await ad.show(...)`.** If the
  platform call itself never resolved — the exact hang the watchdog exists for
  — it was never armed at all. Armed before the await now.
- **`AdLoadingDialog.showAdBuffer` could block every fullscreen ad for the
  session.** It set `_isShowing = true` before `Navigator.of()` and the route
  push, neither guarded, and every caller is fire-and-forget: a throw left the
  flag stuck true, so `_fullscreenBusyReason` reported "ad loading buffer
  showing" forever, and `onComplete` never ran — hanging a splash that awaited
  it. The flag is now raised only once the route exists, and a failure still
  calls `onComplete` as the docstring promises.
- **`AdLoadingDialog.dismiss()` could strand a later dialog with no way to
  close it.** Unlike `resetState()` it did not bump the generation, so a
  sleeping `showAdBuffer` timer woke up, believed it was still current, and
  cleared state belonging to a NEWER dialog — which then had
  `barrierDismissible: false`, `PopScope(canPop: false)` and a `dismiss()`
  that early-returns: a frozen UI. The rewarded on-demand path also stopped
  dismissing dialogs it never opened.
- **A failed `initialize()` left the adapter alive.** AppLovin wires its four
  native listeners before awaiting SDK init, so on the 20 s timeout branch the
  native side could still come up and keep calling into slots this manager had
  abandoned — up to four orphans across the retry chain, each holding ~15 live
  `ValueNotifier`s.
- **Banner / MREC / native could sit "loading" forever.** They had no load
  watchdog (all four fullscreen formats do), so a GMA listener that never fired
  left the slot refusing every later `beginLoad()` and the widget showing its
  shimmer placeholder with `hasError` false. Now bounded at 30 s, which lands
  the slot in `cooldown` — a state a remount retries.
- **The crash guard's slot recovery skipped rewarded-interstitial, MREC and
  native.** That pass is the *only* recovery for a slot stuck `showing`, since
  those formats deliberately have no show-watchdog; if the callback that would
  have advanced the slot was the thing that crashed, it stayed stuck.
- **Four `show*` catch blocks dropped the ad without disposing it**, leaking
  the native object. Reachable: `gma_bridge` awaits `setServerSideOptions()`
  before showing, and a platform call can throw.

### Fixed — consent (commit 2)

- **The consent-footgun guard was fail-open on AdMob.** It treated
  `disableAppLovinCmpFlow: false` as proof that a consent flow existed, but
  that flag is only ever read by `AppLovinAdapter.initialize`, so on AdMob it
  means nothing. The combination `provider: admob` +
  `autoRequestUmpConsent: false` + `disableAppLovinCmpFlow: false` — a config
  the SDK accepts silently — produced no warning and left `canRequestAds` at
  its default `true`: EEA/UK users served ads with no consent flow at all.
  AppLovin's CMP now only counts when AppLovin is the active provider.
- **AppLovin received its privacy flags after `AppLovinMAX.initialize`, not
  before.** On an ordinary cold start (host never called `setConsent`, so
  nothing was buffered) the post-init `applyToProviders` was the first time
  AppLovin heard about consent — MAX documents these as init-time settings.
  `AdProviderAdapter.initialize` now takes the consent state so each adapter
  can apply it in the order its own SDK requires.
- **`tagForUnderAgeOfConsent` never reached AdMob.**
  `AdConfig.umpTagForUnderAgeOfConsent` only fed UMP's consent form, so an app
  declaring an under-age audience got the right form and then sent every ad
  request out with no under-age signal. Now set on `RequestConfiguration` —
  only ever as `yes`; absent an explicit declaration it stays `unspecified`
  rather than asserting `no`.
- **A UMP re-run could silently wipe a CCPA opt-out or the COPPA flag.**
  `AdManager._consent` was a second source of truth that
  `ConsentManager.set()`/`reset()` never updated, so anything rebuilding an
  `AdConsent` from it (a UMP backstop retry, `showPrivacyOptions()`) wrote
  `doNotSell: false` back to disk, to AdMob's `rdp` extra and to AppLovin's
  `setDoNotSell`. The two are now kept in sync at the single point every
  consent change already flows through.
- **Withdrawing personalisation mid-session did not invalidate already-loaded
  ads.** `applyConsent` only affects future requests, so the personalised
  app-open/interstitial/rewarded ads already in the cache were still shown and
  banners kept refreshing; ad age was the only thing that could discard them.
  New `AdProviderAdapter.discardCachedFullscreenAds()` runs on a
  `true → false` transition, alongside an `initRevision` bump for inline ads.
  Never touches an ad that is on screen.
- **COPPA on AppLovin was a one-way door.** Setting `isAgeRestrictedUser: true`
  correctly hard-stops ad requests (MAX 4.x has no runtime API for it), but
  correcting the flag back to `false` left every AppLovin surface dead for the
  rest of the process with nothing in the log to say why. The adapter is now
  re-initialised when the flag changes in either direction.
- **`tcfConsentString` always returned `null` on real devices.** It read
  through the legacy `SharedPreferences` API, which on Android reads its own
  private file (UMP writes to the app's *default* store) and on iOS prefixes
  every key with `flutter.` (UMP writes none). Its unit test passed against
  `setMockInitialValues`, so the API looked wired for four audit rounds while
  answering `null` to every caller. Now reads the platform's own store —
  verified on Android hardware, returning a real TCF v2 string.
- **iOS: a failed ATT status read could trigger Apple's tracking prompt from
  inside `initialize()`.** An unreadable status fell through to "do not defer",
  which then called `AdvertisingId.id(true)` — and that `true` asks the plugin
  to raise the ATT prompt, outside the host's control. Unknown is now treated
  like `notDetermined`, as is a `notDetermined` that survives a timed-out
  `requestAtt()`. The status read itself is now bounded at 5 s, matching what
  the self-check already did to the same call.
- **The built-in consent dialog could ask an EEA user on UMP's behalf.** It is
  a two-button sheet, not a certified CMP, and produces no TCF string — yet a
  "yes" from it was written through to AppLovin. It is now skipped whenever UMP
  owns consent, including when UMP came back inconclusive (the path that made
  this reachable).
- **A one-time connectivity-watch failure disabled the fast path for the whole
  session.** `_startConnectivityWatch()` was called exactly once and is
  best-effort, so a plugin init that threw left `isConnected` pinned to its
  optimistic seed: every offline load just failed into backoff and
  refill-on-reconnect never happened. The poll tick now re-attempts it.
- The consent-footgun check no longer races the un-awaited auto-UMP flow, the
  first-install Keychain read is bounded at 5 s (failing safe: skip the grant),
  and `_attRequested` is reset by `destroy()` like the other guard flags.

### Added

- `AdManager.usPrivacyOptedOut` and `AdManager.gppConsentString` — the IAB US
  Privacy and GPP signals a CMP leaves in platform storage.
  `usPrivacyOptedOut` returns `null` when no string exists, deliberately
  distinct from `false`: `AdConsent.doNotSell` is host-set only, so
  `exportComplianceReport` reported `doNotSell: false` for a California user
  who had opted out through a CMP. GPP is exposed raw rather than decoded —
  mis-parsing a privacy signal is worse than not parsing one.
- `debugFormDismissTimeoutOverride` — lets an on-device harness cap the
  consent-form wait, since no harness can tap a native dialog and would
  otherwise sit out the full 180 s.

### Changed

- `AdProviderAdapter` gains `consent:` on `initialize` and a new
  `discardCachedFullscreenAds()`; `GmaBridge.updateRequestConfiguration` now
  takes the COPPA/TFUA tags (`RequestConfiguration` replaces rather than merges,
  so passing only test-device ids wiped them). Breaking only for a custom
  adapter or bridge implementation.
- Declares `shared_preferences_android` directly. It is already in every
  Android build as the implementation of `shared_preferences`; the direct
  dependency exists solely because `SharedPreferencesAsyncAndroidOptions` —
  the only way to point a read at the app's default preference file, where UMP
  writes — is not re-exported by `shared_preferences`.

## [2.3.1] - 2026-08-22

Consent-path hotfix. Every item below was found by the round-5 audit and the
first two were reproduced on real hardware (Pixel 7 Pro, `debugGeography:
debugGeographyEea`, real UMP forms) before and after the fix.

### Fixed

- **Audit round 5 — the consent form was re-shown on every launch to an
  EEA/UK user who had already answered it.** The flow gated on
  `isConsentFormAvailable()`, which reports whether a form *exists*, not
  whether consent is *required* — and a form stays available after consent,
  because that is what backs the Privacy Options entry point. Confirmed on a
  real device (Pixel 7 Pro, `debugGeography: debugGeographyEea`): a cold
  restart with consent already granted logged `status=obtained
  formShown=true` and put the form back on screen. Now uses Google's own
  `ConsentForm.loadAndShowConsentFormIfRequired` behind a
  `status == required` guard, so an already-answered user is never asked
  again and the common (non-EEA) case skips the platform call entirely.
- **Audit round 5 — the consent gate could stay shut for a whole session
  with no way to recover.** `_umpAttemptFailed` was `result.error != null`
  alone, but UMP returns `error == null` with `canRequestAds == false`
  whenever it resolves from cache without being able to serve a form — the
  ordinary "flaky network on first launch in the EEA" case. Both retry paths
  gate on that flag, so the gate stayed closed for the rest of the process:
  **zero ads, no self-heal short of an app restart**, even once the network
  came back. It now also covers an inconclusive result and a still-closed
  gate.
- **Audit round 5 — the consent form gave the user only 20 s to answer.**
  The dismiss timeout was shared with the network steps, so a person reading
  a real GDPR form (206 partners, an expandable "Learn more") had the flow
  abandoned out from under them, resolving the ad gate before they had
  chosen. Split out to 180 s for the human step; the no-network case is
  still bounded by the 20 s guard on `requestConsentInfoUpdate`, and a cap
  still exists so an unattended simulator cannot hang the flow forever.
- **Audit round 5 — the UMP retry paths could run several consent flows at
  once, and dropped `tagForUnderAgeOfConsent` when they did.** Concurrent
  callers now join the in-flight request instead of presenting a second
  form and racing each other's writes to the gate; retries replay the
  params of the original call, so a child-directed app no longer collects
  consent through the wrong form (which would not have been valid for an
  under-age audience) and an EEA-debug run stays reproducible.
- **Audit round 5 — the periodic UMP backstop was unbounded.** With the
  widened failure flag above, an EEA user who legitimately chose "reject"
  also reads as "gate closed", so the backstop would have re-run the consent
  flow every 5 minutes for the rest of the session. It is now capped, and
  never re-runs for a user UMP already got an answer from.

### Added

- `example`: `--dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>`
  drives the real EEA consent path on a test device. Without it a tester
  outside the EEA can never reach UMP's `required` branch, so every EEA-only
  code path stays unexercised — that blind spot is what let the two consent
  bugs above ship. `UMP_TEST_ID` is the hashed device id UMP prints to the
  log on first run.

## [2.3.0] - 2026-08-21

### Added

- `AdMobConfig.effectiveTestDeviceIds` / `kQaTestDeviceHashes` — this team's
  own QA device fleet's AdMob test-device hashes are now always merged into
  `RequestConfiguration.testDeviceIds` on every `initialize()`/consent
  re-apply, regardless of what a host app configures in `testDeviceIds`.
  Keeps manual QA on real hardware from ever counting as real
  impressions/clicks (and the invalid-activity rate-limit risk that comes
  with it), without the host app having to know or maintain the list.

### Fixed

- **Audit fix — `initialize()`'s `autoRequestUmpConsent` branch could fail
  open on a real consent-fetch error, not just an unwired UMP channel.**
  Any exception used to fail the gate open; now only `MissingPluginException`
  (channel genuinely not wired) fails open — every other exception (a real
  UMP fetch failure) fails closed, so a network hiccup can no longer
  silently ship ads with no verified consent decision.
- **Audit fix — `destroy()`/`_resetGuardState()` left the previous session's
  device GAID behind.** A stale GAID surviving past teardown into the next
  `initialize()` is a privacy leak; it's now cleared as part of guard-state
  reset.
- **Audit fix — reopening the `canRequestAdsListenable` gate mid-session
  never triggered a frame in `BannerAdWidget`/`MrecAdWidget`/
  `NativeAdWidget`.** `_onCanRequestAdsChanged()`'s reload path relied on
  `addPostFrameCallback`, which does not itself schedule a frame — the
  reload silently no-opped until some unrelated frame happened to fire.
  Fixed by calling `WidgetsBinding.instance.scheduleFrame()` alongside it.
- **Audit fix — `MonetizationArbitrator`'s with-estimator branch could veto
  ads at zero eCPM.** The no-estimator branch already guarded on
  `ecpm > 0`; the with-estimator branch was missing the same guard, so a
  session with no revenue events yet (`ecpm == 0`) could still have ads
  vetoed whenever the host's likelihood estimator reported > 0.5. Both
  branches now require `ecpm > 0` before vetoing.

## [2.2.0] - 2026-08-20

### Added

- `AdManager().currentDeviceGaid` and `AdManager().adMobTestDeviceHashHint()` —
  the latter returns instructions (device's current GAID included, clearly
  labeled) for finding this device's AdMob test-device hash via logcat tag
  `Ads`, since Google has no public API/formula for that hash. Intended for
  a host app's own debug UI; distinct from the GAID, which is not valid for
  AdMob's `RequestConfiguration.setTestDeviceIds()`.

## [2.1.0] - 2026-08-19

### Fixed

- **2026-08-19 audit: App Open (and interstitial/rewarded/rewarded-interstitial)
  could be shown stale past their expiry window.** The 4h/1h `isAdFresh`
  check was only ever consulted when *loading* (reuse-if-fresh) — `show*()`
  never checked it, so a ready ad that sat unused past expiry (app
  backgrounded a long time, then resumed) could still be shown. For App
  Open specifically this violates Google's documented policy of discarding
  and reloading rather than showing a stale ad. Fixed for all 4 AdMob
  fullscreen types: a stale ready slot is now discarded (native ad
  disposed, slot marked failed → cooldown, eligible for reload) instead of
  shown.
- **2026-08-19 audit: `showAppOpenAdOnResume()` bypassed the daily/session
  safety cap outside the one case (splash) this SDK's own contract
  allows.** It always called `showAppOpenAd(bypassSafety: true, ...)`, so a
  resume-triggered App Open skipped the daily/hourly/session cap and
  CTR-fraud pause entirely while still counting toward the cap via
  `recordFullscreenAdShown()` — an asymmetric bypass. Fixed to
  `bypassSafety: false`; the resume-specific timing gates
  (`canShowAppOpenOnResume`) are unchanged and still apply.
- **2026-08-19 audit: AppLovin banner/MREC widgets leaked their native
  `MaxAdView` on normal disposal.** `disposeBannerInstance`/
  `disposeMrecInstance` released only the Dart-side `AdSlot`/
  `BannerListenables`/`ValueNotifier` — they never called
  `destroyWidgetAdView`, so every `BannerAdWidget`/`MrecAdWidget` that
  permanently unmounts leaked the native ad view. AdMob's equivalent path
  was already correct. Fixed to release the native `AdViewId` on dispose.
- **2026-08-19 audit: `requestAtt()`-before-UMP ordering had no
  release-build footgun.** Forgetting to call `requestAtt()` before
  `initialize()`/`requestUmpConsent()` on iOS was only ever a
  `SafeLogger.w` inside `requestUmpConsent()` itself — easy to miss.
  Added `attOrderFootgunWarning`, wired into `initialize()` alongside the
  existing consent footgun check (loud in every build, not release-gated
  to a hard block since this is a revenue/attribution risk, not a
  legal-compliance one like the consent footgun).

- **Fork-review of the 2026-08-16 audit fixes (2026-08-17): stale load-watchdog
  timer race in `AdSlot.armLoadWatchdog()`.** The watchdog `Timer` created by
  the previous fix kept no handle, so re-arming it (the adapter's own
  internal reload-after-show-failure path does this) left the earlier
  timer alive. If a fast reload started well inside the first timer's
  window, the stale timer could still fire and call `markFailed()` against
  the *new* loading attempt, cutting its real timeout short. `AdSlot` now
  cancels any previously-armed watchdog before arming a new one, and
  `dispose()` cancels a still-pending watchdog too (it previously could fire
  `markFailed()` — a `state.value` write — against an already-disposed
  `ValueNotifier`). 2 new tests in `test/ad_slot_test.dart`. Also tightened
  2 existing tests from the same audit round that didn't actually regress
  if their fix were reverted (`test/vip_revocation_test.dart`'s CRL→AVP1
  relabeling test — documented why that direction is inherently protected
  by Ed25519 rather than by the fix; `test/connectivity_refill_test.dart`'s
  overlapping-call race test — strengthened to assert on the log line the
  discard branch emits, since `_connectivityReady` alone reads identically
  with or without the fix in this unit-test environment).

- **P2 audit cleanup (2026-08-16), two minor findings.**
  - `destroy()` only cleared the banner load-cooldown map, missing
    mrec/native (all 3 added together at T65) — a `destroy()` + fresh
    `initialize()` within the cooldown window (without unmounting the
    widget) left MREC/Native inconsistently "still on cooldown" vs Banner.
    1 new test in `test/ad_manager_test.dart`.
  - Re-entering `initialize()` a second time without an intervening
    `destroy()` (the "auto-disposing previous" branch) didn't remove the
    consent listener before re-adding it — since `ConsentManager` is itself
    a persistent static singleton (survives this branch same as the
    adapter is torn down and recreated), N such re-inits left N copies of
    the listener stacked on it, each firing `applyConsent` redundantly per
    consent change. Fixed by removing it first, mirroring `destroy()`'s own
    cleanup. Not independently unit-tested: reaching the listener
    registration requires a real native adapter `initialize()` call to
    succeed first, which isn't reachable in this repo's plain
    `flutter test` environment (native plugin channels are unavailable) —
    verified correct by code inspection (exact mirror of `destroy()`'s
    already-tested `removeListener` call) rather than by a new test.
- **`_startConnectivityWatch` could leak a `StreamSubscription` across two
  overlapping `initialize()` calls — caught by internal audit, 2026-08-16.**
  It's called `unawaited` from `initialize()`, which can itself finish (and
  reset its own re-entry guard) well before this method's up-to-20s
  connectivity-plugin-init await resolves. A second `initialize()` call
  starting before the first's watch resolved could overlap two invocations
  of this method; whichever resolved last silently overwrote
  `_connectivitySub`, leaking the other's subscription forever. Added a
  generation token (same pattern as `enableFillRateBaselineMonitor`'s fix
  above) so a call that loses the race bails out before ever subscribing,
  instead of clobbering (or being clobbered by) a newer one;
  `_stopConnectivityWatch` also bumps it so a still-pending start can't
  resurrect state after a stop. 2 new tests in
  `test/connectivity_refill_test.dart`.
- **Rewarded Interstitial (T89) was missing from the 5-minute connectivity
  backstop refill entirely — caught by internal audit, 2026-08-16.**
  `_retryRefillAds` only checked `appOpenSlot`/`interstitialSlot`/
  `rewardedSlot` — if a rewardedInterstitial's first load ever failed
  (no network / no-fill) and it was never shown, nothing would ever refill
  it again. Added the same idle/cooldown check for
  `rewardedInterstitialSlot`. 1 new assertion in
  `test/connectivity_refill_test.dart`. (Also updated 4 test fake adapters
  — `banner`/`mrec`/`native_ad_widget_test.dart`,
  `connectivity_resilience_test.dart` — to implement
  `rewardedInterstitialSlot`/`loadRewardedInterstitial` for real instead of
  relying on `noSuchMethod`, since this change made them reachable for the
  first time.)
- **`NativeAdWidget` on AppLovin leaked a live `BannerListenables` bundle
  per scrolled-past native ad in a `ListView` — caught by internal audit,
  2026-08-16.** `MaxNativeAdView`'s listener callbacks re-resolve
  `adapter.native(instanceKey)` on EVERY invocation (unlike
  `BannerAdWidget`/`MrecAdWidget`, which capture their listenables ONCE at
  load start), so a callback that arrived after `disposeNativeInstance(key)`
  already removed the map entry would silently `putIfAbsent` a brand new,
  never-disposed bundle for that permanently-gone (per-widget-instance) key
  — unbounded, one leak per native ad scrolled past (T73's in-feed use
  case). `AdMobAdapter` was unaffected (captures its listenables/slot
  locals once, doesn't re-resolve per callback). Fixed by tracking disposed
  keys in `AppLovinAdapter` and returning the shared already-disposed
  placeholder for any of them instead of auto-vivifying a fresh one. 1 new
  test in `test/applovin_adapter_test.dart`.
- **AppLovin's internal reload-after-show-failure could leave a slot stuck
  `loading` forever — caught by internal audit, 2026-08-16.** After a show
  fails/dismisses, `AppLovinAdapter` reloads by calling the native bridge
  DIRECTLY (`_bridge.loadAppOpenAd`/`loadInterstitial`/`loadRewardedAd`),
  bypassing `AdManager.loadX()` entirely — which is the only place a load
  watchdog otherwise gets armed (`_armLoadWatchdog`/T76). If AppLovin's
  native SDK never calls back for one of these specific reloads (the exact
  callback flakiness T76's watchdog exists to guard against), the slot had
  no recovery path and stayed `loading` forever — every later load call is
  a no-op while already loading. `AdMobAdapter` was unaffected (its load
  path only has one call site, always AdManager-orchestrated). Fixed by
  adding `AdSlot.armLoadWatchdog(label, timeout)` (the same logic
  `AdManager._armLoadWatchdog` already had, now shared) and arming it
  directly at all 6 adapter-internal reload sites (2 per ad type — one from
  `onAdDisplayFailedCallback`, one from `onAdHiddenCallback`). 3 new tests
  in `test/applovin_adapter_test.dart`.
- **`canShowInterstitial`/`canShowRewardedAd`/`canShowRewardedInterstitialAd`
  could permanently escalate a CTR-anomaly lockout just from being polled —
  caught by internal audit, 2026-08-16.** All 3 are read-only "should I
  enable my ad button" queries, but internally called
  `AdSafetyConfig.canShowFullscreenAd()` — the SAME function the actual show
  flow uses, which has a side effect: on a CTR anomaly it re-arms an
  escalating suspicious-pause window. Since a blocked ad never adds an
  impression, CTR can never recover on its own, so every poll after each
  pause window naturally expired re-triggered and escalated the exact same
  violation forever, from nothing but a UI-enable-state check (e.g. a
  "Watch Ad" button rebuilding on a timer) — zero new clicks required. Fixed
  by adding `AdSafetyConfig.canShowFullscreenAdPeek()` (identical checks,
  zero side effects — mirrors `dailyCapReached()`'s existing "safe to poll"
  contract) and switching all 3 query methods to use it;
  `AdManager`'s actual `showInterstitial`/`showRewardedAd`/
  `showRewardedInterstitialAd` show flows are unchanged (still use the
  side-effecting variant, correctly, since those represent a genuine show
  attempt). 2 new tests in `test/ad_safety_config_test.dart`.
- **[Security] VIP-key revocation list (CRL, T95) missing domain separation
  from VIP keys — caught by internal audit, 2026-08-16.** `verifySignedCrl`
  and `verifySignedVipKey` both verified an Ed25519 signature over the raw
  payload bytes with no format tag mixed in. A CRL's payload shape
  (`<issuedAtEpoch>|<kids>`) is identical to an AVP1 VIP key's shape
  (`<seconds>|<kid>`) — since a CRL is *designed* to be broadcast publicly
  (no secrecy requirement), anyone who observed a real signed CRL could
  relabel its prefix from `CRL1` to `AVP1` and redeem it as a real VIP key
  valid for however many "seconds" the CRL's `issuedAt` epoch happened to
  equal (tens of years). Fixed by signing/verifying `"CRL1|" + payload`
  instead of the payload alone for CRLs specifically — AVP1/AVP2 signing is
  deliberately left untouched (changing it would break every VIP key a host
  app has already minted and distributed; CRL had not shipped yet, so no
  migration is needed for it either). `tool/vip_crl_mint.dart` updated to
  match, and now also sanitizes `|` out of `--kids` like `vip_mint.dart`
  already does for `--kid`. 2 new regression tests in
  `test/vip_revocation_test.dart` lock in both directions (CRL→AVP1 and
  AVP1→CRL1 relabeling both now rejected).
- **`AdManager.enableFillRateBaselineMonitor` race leaked the loser of two
  overlapping calls — caught by internal audit, 2026-08-16.** The method
  awaits `AdPreferences.getInstance()` before constructing its monitor;
  calling it twice without awaiting the first left whichever call resolved
  first's instance orphaned (its `AdManager().events` subscription never
  cancelled, silently persisting to `SharedPreferences` forever) once the
  second call's assignment overwrote the field. Fixed with a generation
  token so only the call that resolves *last* wins, and any loser disposes
  its own instance instead of leaking it; `disableFillRateBaselineMonitor`
  and `destroy()` also bump the token so an in-flight `enable` call can't
  resurrect a monitor after either wins. 3 new tests in the new
  `test/ad_manager_fill_rate_baseline_test.dart`.
- **`AdManager`'s ATT doctor check (T98) had no upper bound on a hung
  platform channel — caught by internal audit, 2026-08-16.** `_selfCheckAtt`
  now wraps the read in `.timeout(const Duration(seconds: 5))` — every
  `runIntegrationSelfCheck` item is awaited sequentially, so a channel that
  never completes would otherwise hang the entire doctor run indefinitely
  instead of failing just this one item.

### Added

- **`NativeAdWidget` gate-recheck behavior locked in by regression tests
  (T100).** Verified: a consent revoke or later rebuild after the gate has
  already passed (but before the native ad finishes loading) does not
  retroactively cancel an in-flight load — consistent with
  `BannerAdWidget`/`MrecAdWidget`, which gate `canRequestAds` only at
  request time too, never reactively in `build()`. No code change; closed
  as "current behavior consistent + acceptable" with 2 new tests
  documenting it, per the ticket's own escape hatch.
- **`monetization_arbitrator_test.dart` gains `showRewardedInterstitialAd`
  veto coverage (T99).** The `onLowValueAdVetoed`-style hook the ticket asked
  for already existed (`ArbitratorNudgeEvent` on `AdManager().events`, wired
  at all 3 fullscreen show call sites since T89 added the rewarded-
  interstitial slot) — this closes the one real gap, a missing test for the
  rewarded-interstitial veto path, and documents `showRewardedInterstitialAd`
  explicitly in the README's arbitrator section.
- **Runtime integration doctor — `AdManager.runIntegrationSelfCheck` extended
  (T98).** Flagship: 3 new read-only checks — "Navigator key wired" (fails if
  `setNavigatorKey` was never called), "Route observer wired" (real evidence
  via `AdScreenRouteLogger`'s new navigation-event counter, not just "was it
  constructed"), and "ATT status readable (iOS)" (catches a broken
  `app_tracking_transparency` native embed without ever showing the real
  system prompt). Results now render directly in the built-in
  `DebugAdOverlay` via a manual "🩺 Run integration doctor" tap (not
  auto-run — the existing per-ad-type checks attempt real ad loads).
  Deliberately does NOT add SKAdNetwork/`Info.plist`/`AndroidManifest.xml`/
  pod-graph checks — those need new native platform-channel code (or, for
  the pod graph, aren't a runtime concept at all); see README for the exact
  reasoning.
- **`FillRateBaselineMonitor` — 7-day on-device fill-rate/eCPM regression
  detector (T97).** Flagship: `AdManager().enableFillRateBaselineMonitor(...)`
  compares THIS SESSION's fill rate and average revenue-per-ad
  (`AdRevenueEvent.valueMicros`) against a rolling 7-calendar-day baseline
  persisted locally — fully on-device, no backend, no shadow ad requests.
  Fires an alert once per slot the first time it regresses by at least
  `regressionThreshold` (default 20%) below the device's own baseline, needs
  `minSamples` on both sides before trusting a comparison, and excludes
  today's own in-progress day from its own baseline. Wired into
  `AdDiagnostics.fillRateRegressionBySlot` and rendered directly in the
  built-in `DebugAdOverlay`.
- **Cryptographically-signed compliance report export — `AdManager.exportSignedComplianceReport` (T96).**
  Flagship: wraps the existing `exportComplianceReport` bundle with an
  on-device Ed25519 signature (key minted once per install, persisted via
  `flutter_secure_storage`) so an edit made to the exported JSON AFTER export
  is detectable — tamper-evidence for an ad-network dispute appeal. Verify
  with `verifySignedComplianceReportJson` or the new standalone
  `tool/verify_compliance_report.dart` CLI. See README's "Cryptographically-
  signed compliance report export" for the precise (deliberately limited)
  threat model this does and doesn't cover.
- **VIP key revocation list (CRL) — `VipManager.refreshRevocationList` (T95).**
  Flagship: an offline-signed revocation list closing the SDK's known
  leaked-key gap (a redeemable-forever `kid` once shared) without a backend.
  Mint with `tool/vip_crl_mint.dart` using the SAME Ed25519 private key as
  `tool/vip_mint.dart` — no new key material. Host fetches the raw signed CRL
  via a new `VipRevocationProvider` interface (mirrors `RemoteAdSafetyProvider`'s
  shape) and calls `refreshRevocationList` periodically (once/day suggested);
  verified CRLs are cached to disk and re-verified on every read, and a
  revoked `kid` is rejected by `redeemSignedKey` going forward. Fails open on
  every error (no provider, fetch throw, `null`, bad signature, replayed/older
  CRL) — never blocks a legitimate redemption. Does not claw back a grant
  already made before the revocation landed. See README's "Revoking a leaked
  key (CRL)".
- **`AdReadinessSplashController` (T94).** Officializes the splash-screen
  orchestration boilerplate the README documented by hand — subscribe-
  before-init, the hard-cap timer, `markSplashActive`/`incrementSplashCount`/
  `markSplashInactive`, the re-entrant-splash guard, the buffered App Open
  ad with `bypassSafety: true`. One `start()`/`onReady` call; your splash
  screen still renders 100% its own UI. `dispose()` also clears the SDK's
  splash-active state if the widget is torn down before `onReady` ever fires.
  Also fixes two stale spots in the README found while writing this: a
  broken code fence that had been splitting the `_SplashScreenState` example
  in two (the "Per-platform ad-unit ids" section was accidentally inserted
  mid-class, leaving the rest unfenced), and outdated wording claiming
  `SimpleEventBus` never replays events to late subscribers — it does now
  (see the "F1" comment in `event_bus.dart`).
- **`AdSafetyParams.maxPerPlacementAdsPerDay` (T92).** Optional additional
  daily cap keyed by `AdPlacement`, checked alongside (never instead of) the
  existing global daily cap at show time. `null` by default — fully
  backward-compatible. Emits an `AdSkipEvent` with `reason: 'placement_cap'`
  when it blocks. Note: can't be set via a `const AdSafetyParams(...)` call
  (`AdPlacement`'s custom `==` isn't const-map-key-safe) — use a regular
  constructor call or `.copyWith(...)`.
- **`BannerAdWidget` collapse/expand animation (T91).** New
  `collapseAnimationDuration` param (default 250ms) wraps the banner in
  `AnimatedSize`, so no-fill/cooldown/VIP collapsing (and a real ad becoming
  ready) animates the height change instead of an abrupt
  `SizedBox.shrink()` layout jump. Pass `Duration.zero` for the old
  instant-jump behavior.
- **`AdManager().pickProviderCohort()` (T90).** Deterministic 50/50 AdMob vs
  AppLovin MAX A/B split, built on `experimentBucket`. Pick before building
  `AdConfig` (provider is fixed for the session). No new compliance-report
  plumbing for comparing cohorts — every event already carries `providerTag`.
- **`AdManager().experimentBucket(key, buckets: n)` (T93).** Deterministic,
  local-only A/B bucket assignment — hashes GAID (or a lazily-generated
  pseudonymous install id when GAID is empty/all-zeros) with `key`. No
  network, no new dependency; lighter-weight than `RemoteAdSafetyProvider`
  for hosts that just want to compare two local `AdSafetyParams`/arbitrator
  configs.
- **Rewarded Interstitial ad type — AdMob only (T89).**
  `AdMobConfig(rewardedInterstitialId: ...)` +
  `AdManager().loadRewardedInterstitialAd()` /
  `showRewardedInterstitialAd(onDone: (shown, earned) => ...)` /
  `canShowRewardedInterstitialAd()`. Google's format shown at a natural
  transition point rather than behind an explicit "watch ad" tap. AppLovin
  MAX has no equivalent ad unit type — that adapter's implementation is a
  documented no-op. No VIP-bypass-to-extend-VIP flow and no SSV params for
  this ad type, unlike `showRewardedAd` (see the doc comments for why).
- **`RemoteAdSafetyProvider` (T88).** Optional `AdManager().initialize(...,
  remoteSafetyProvider: ...)` hook so a host can adjust `AdSafetyParams`
  (daily/hourly caps, throttle, CTR threshold, ...) from a backend (Firebase
  Remote Config, a self-hosted API, ...) without an app store release.
  Provider-agnostic — no new dependency added. A slow (>5s), throwing, or
  `null`-returning provider falls back to the local `config.safety`
  unchanged; each override key is independently validated. Ad-unit-ID
  remote override was considered but is out of scope for this first pass —
  see the ticket for why.

### Removed

- `Backoff` (from `src/state/backoff.dart`) is no longer exported from the
  package barrel (T78). It was always an internal detail of
  `AdSlot.beginLoad()`'s default cooldown parameter — not referenced by
  any documented public API. If you constructed one directly, import
  `package:applovin_admob_sdk/src/state/backoff.dart` instead.

## [2.0.4] - 2026-08-09

Docs-only. No code changes. Prompted by an independent multi-agent audit
(Claude/Codex/Gemini, `doc/audit/audit_*.md`) flagging that the pubspec
description overclaimed "Offline VIP redeem".

### Changed

- pubspec `description` — "Offline VIP redeem" → "Offline-verified VIP
  codes". The Ed25519 signature check is fully offline, but
  `redeemSignedKey` has rejected the redeem *attempt* while offline since
  2.0.1 (deliberate anti-abuse gate) — the old wording implied the whole
  flow works offline, which it hasn't since that release.
- README — added a "Known limitation — redeem attempt requires
  connectivity" callout next to the signed-VIP-keys section, spelling out
  the same distinction.

## [2.0.3] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — a Quickstart section with the minimal
  `setNavigatorKey`/`navigatorObservers`/`requestUmpConsent`/`initialize`/
  `buildBanner` snippet, so the pub.dev "Example" tab is self-contained
  instead of only linking out to the package README.

## [2.0.2] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — an index of the 16 demo pages in `example/lib/main.dart`
  (one row per page: what it demonstrates), so the pub.dev "Example" tab has
  something to navigate besides a 2,500+ line raw file.

## [2.0.1] - 2026-08-09

Non-breaking bug fixes, cross-checked by three independent agents (Codex,
agy, a second Claude instance) with every finding verified against the
source. 698/698 tests pass; manually verified on a real Android device.

### Fixed

- **`AdManager.initialize()` bounded auto-retry.** A failed adapter init
  (bad ad unit ids, missing native config, transient SDK error) now retries
  up to 3 times with backoff (5s/15s/30s) before giving up for the session,
  instead of leaving the host permanently uninitialized until the next app
  launch or an explicit re-`initialize()` call.
- **`onComplete` now fires exactly once per host-initiated `initialize()`
  call.** Previously it could fire on every failed attempt in addition to
  the terminal outcome (up to 4 times across the retry budget), violating
  the 1.x callback contract of firing once with the final result.
- **Stale internal-retry flag could leak into a later legitimate call.** A
  retry timer firing while another `initialize()` call already held the
  busy guard left `_isInternalInitRetryCall` stuck `true`, causing the next
  real host-initiated call to be misclassified as an internal retry.
- **`VipManager` clock-rollback guard applied consistently.** The
  clock-rollback-resistant "now" getter (`_effectiveNow`, clamped against a
  persisted high-water mark) was already used for expiry/stacking
  calculations but was missed in `_refreshGraceNudge` and
  `_scheduleNextExpiry`, which still read the raw device clock — a backward
  clock jump could desync the grace-nudge and next-expiry timers from the
  rest of the VIP state.

### Changed

- **`VipManager.redeemSignedKey` now rejects redemption attempts while the
  device is offline**, returning `VipRedeemStatus.invalid` with a
  "no network connection" message, before running Ed25519 signature
  verification. Deliberate anti-abuse tightening — a host at 2.0.0 that
  allowed a signed key to be redeemed while offline will see those attempts
  rejected at 2.0.1. Ed25519 verification itself is still fully offline
  (no server call, no shared secret); only the redemption *attempt* now
  requires connectivity.

### Known limitations (unchanged, not new in this release)

- `VipManager.redeemVip`'s separate host-supplied-validator path is not
  gated by the offline check above — only `redeemSignedKey` is. Consumers
  using `redeemVip` with their own validator should apply their own
  connectivity check if desired.
- `AdManager.isConnected` optimistically returns `true` if read before the
  connectivity watcher is ready, or if the platform check throws — a small
  fail-open window on cold start.

## [2.0.0] - 2026-08-02

Breaking. Comes out of a full audit against seven production requirements
(`doc/audit/audit_claude_20260802.md`), cross-checked by three independent
agents, with every finding verified against the source.

### Breaking

- **`autoRequestUmpConsent` now defaults to `true`.** With the old defaults
  (`false`, plus `disableAppLovinCmpFlow: true` and
  `autoShowConsentDialog: true`) a host that changed nothing tripped the
  consent-coverage footgun, which hard-blocks every ad request in a release
  build — and the built-in dialog could not clear the block, because it applies
  consent directly to the providers and never routes through `setConsent()`.
  The result was a release that requested **zero ads, silently**: the `assert`
  next to the block is stripped in release, leaving one log line. Hosts that
  already call `requestUmpConsent()` themselves are detected and the automatic
  call skips, so UMP still runs exactly once.
- **`maxVipStackDuration` now defaults to 90 days** instead of `null`
  (uncapped). Pass `null` explicitly for the old behaviour, knowing the only
  remaining ceiling is the ~100-year sanity bound in the key parser.
- **Signed VIP keys default to a new `AVP2` format** carrying an expiry and an
  app binding inside the signed payload. `AVP1` keys already issued still
  verify; `tool/vip_mint.dart` mints AVP2 unless `--v1` is passed.
- New dependency: `package_info_plus`, used to read the bundle id that AVP2
  keys are checked against.

### Fixed

- **Interstitial and rewarded ads could stack on each other.**
  `showAppOpenAdOnResume` checked the other two fullscreen slots and the dialog
  stack, but `showInterstitial` and `showRewarded` each checked only
  themselves, so a call while another fullscreen ad was showing put one ad on
  top of another — an AdMob and AppLovin policy violation.
  `AdSafetyConfig.canShowFullscreenAd()` does not cover this: it is a
  time-based frequency gate, not a state mutex. All three paths now share one
  predicate.
- **Banner/MREC/native loads ignored the consent, VIP, cap and connectivity
  gate — in both adapters.** None of the ten load entry points consulted
  `canReload`, so a resume after a banner error (or any other caller) could
  fire an ad request while `canRequestAds` was false, while the user was VIP,
  or past the daily cap. Requesting an ad with `canRequestAds == false` is a
  UMP policy violation, and it was invisible from the UI because the widget
  layer hides banners for VIP users anyway. The `canReload` seam existed on
  `AdMobAdapter` but was dead code — only AppLovin ever called it.
- **A failed UMP attempt was never retried.** On reconnect the SDK refilled ad
  slots but not consent, so an EEA user whose first launch had no network never
  saw a consent form for the rest of the process. Now retried on the
  offline→online transition, and only when the previous attempt actually
  failed, so a user who already answered is not asked again.
- **A UMP status of `unknown` silently downgraded a stored consent.** `unknown`
  means UMP could not determine anything, not that the user refused, but it
  mapped to `hasUserConsent: false` and overwrote a choice the user had already
  made — visible in the logs as `load → consent=true` followed by
  `set → consent=false`. Inconclusive results now leave the persisted value
  alone. `required` still maps to `false`: there the form is genuinely needed
  and was not completed.
- **The consent SDK could abort `initialize()`.**
  `requestConsentInfoUpdate` is a callback API returning `void`; when the UMP
  channel is not registered it throws from a future nobody awaits, so the error
  escaped as an unhandled zone error that a `try`/`catch` around the call could
  not catch. Unreachable while the default was `false`; now contained.

### Documentation

- `maxVipStackDuration`'s docstring claimed the non-stacking path was never
  clamped. It was wrong — `VipManager.addVip` has clamped both paths since the
  single-entry cap was added. (The year-2099 legacy-GAID migration grant really
  is exempt, but because it constructs its `VipEntry` directly.)
- README now states plainly that VIP anti-bypass is Keychain-durable on iOS and
  weak on Android, where clearing app data resets both the trial and key reuse,
  and that offline keys cannot be revoked.
- The example's demo keypair is now marked as public knowledge and unsafe to
  ship.


## [1.2.4] - 2026-08-01

Metadata only — no code, API or behaviour change from 1.2.3.

### Changed
- Shortened the package `description` and all three `screenshots:`
  descriptions to under 160 characters. pub.dev enforces two different limits
  and neither is reported by `pub publish --dry-run`: the upload API rejects
  anything over 200 characters, while pana's scoring wants under 160 or it
  drops 10 points from "Provide a valid pubspec.yaml" and another 10 from
  "Package has an example and has no issues with screenshots". 1.2.3 uploaded
  fine at 187-197 characters but scored 130/160 for that reason.

## [1.2.3] - 2026-08-01

### Fixed
- `autoRequestUmpConsent` was never honoured during `initialize()` — a host
  that opted into automatic UMP now actually gets the consent request before
  ad requests start (R10-A).
- A COPPA flag set mid-session now hard-stops AppLovin ad requests instead of
  only applying to the next SDK init (R10-B).
- `_retryRefillAds()` returns immediately while the device is offline, instead
  of burning retry budget on requests that cannot succeed (R10-C).
- `ConnectionNotifierTools.initialize()` is bounded by a 20s timeout, so a
  hung connectivity plugin can no longer stall SDK init indefinitely (R10-D).
- `_footgunBlocked` leaked across re-init: one release-mode `initialize()`
  could permanently block ads for every later init in the same process. The
  same bug class then recurred for `_umpRequested` / `_consentExplicitlySet`,
  so `destroy()` and the re-init branch now share one `_resetGuardState()`
  instead of two hand-maintained reset lists.
- `applyDryRunReleaseGuard()`'s `isRelease` is threaded into the last two call
  sites (the `ad_manager.dart` consent-footgun guard and the `VipManager`
  constructor) that still fell back to raw `kReleaseMode` under `flutter test`.

### Changed
- Example app now mirrors the host's Android Auto Backup configuration, so the
  VIP-reinstall-replay path behaves the same in the example as in production.
- `SafeLogger`: `critical()` and `e(bypassLevel: true)` consolidated onto one
  internal `_e()`; `_shouldLog`'s `bypassLevel` branches merged.
- `VipManager`'s `isRelease` parameter is no longer `@visibleForTesting`
  (mirrors `ad_safety_config.dart` — the safety comes from
  `isActuallyRelease()`, not from a compile-time restriction).
- Added `repository` / `homepage` / `issue_tracker` / `topics` and an explicit
  `platforms: android, ios` to the pubspec; whole package reformatted with
  `dart format`. No API or runtime change.

### Documentation
- Explained why interstitial and rewarded ads intentionally have no watchdog,
  unlike App Open (R10-E).

## [1.2.2] - 2026-07-20

### Changed
- `SafeLogger`'s default log level is now `kDebugMode`-based (verbose in
  debug, warning-and-above in release) instead of always-verbose — a host
  that never calls `AdManager.setLogLevel()` no longer leaks raw GAID and
  other diagnostic detail into release logs by default.
- The consent-coverage footgun (AppLovin CMP disabled + `autoRequestUmpConsent`
  false + `requestUmpConsent()` never called before `initialize()`) now hard-
  blocks ad requests in release builds (`kReleaseMode`), not just a dev-time
  `assert()` (which strips in release and was previously log-only in
  production). The block clears automatically the moment `setConsent()` is
  called — directly by a host's own consent UI or internally by
  `requestUmpConsent()` — and triggers a refill of any ad slots held back
  while it was active.

### Fixed
- `NativeAdWidget`'s `MaxNativeAdView` listener callbacks now check
  `adapter.isInitialised` before writing to its `ValueNotifier`s or firing a
  click event, closing the same disposed-adapter race already guarded on the
  AppLovin banner/mrec views.

## [1.2.1] - 2026-07-19

### Added
- `VipManager.firstInstallGrantDueListenable` — fires once when the
  first-install VIP grace window is granted (previously silent/log-only),
  paired with `lastFirstInstallGrantDuration` and
  `acknowledgeFirstInstallGrant()`. Mirrors the existing
  `graceNudgeDueListenable` pattern. `AdManager.initialize()` now calls
  `notifyFirstInstallGrant()` right after granting the window.

## [1.2.0] - 2026-07-19

### Added
- `RevenuePanel` gained an optional `debugModeOverride` constructor param
  (test-only seam, `@visibleForTesting`) so the widget's `kDebugMode` gate
  can be exercised from `flutter test`.

### Changed
- `SimpleEventBus` now replays the last-fired event to a listener that
  subscribes *after* the event already fired, closing a gap where late
  subscribers silently missed init-completion signals. `clearAll()` (called
  from `AdManager.destroy()`) resets the replay buffer.
- `RevenuePanel` now fully gates on `kDebugMode` (or the override above): no
  event subscription and `SizedBox.shrink()` render in release builds,
  instead of only skipping the visual chrome.

### Fixed
- `ad_manager.dart` escalates the existing silent log warning for a
  misconfigured consent flow (AppLovin CMP disabled, `autoRequestUmpConsent`
  false, `requestUmpConsent()` never called before `initialize()`) to a
  dev-time `assert()` — asserts strip in release, so production behavior is
  unchanged, but dev/test builds now fail loudly instead of silently
  shipping with no consent flow.
- `requestUmpConsent()` now logs a warning if called before `requestAtt()`
  on iOS (ATT must run first per platform policy) — log-only, non-blocking.

### Docs
- Clarified in the README: the AdMob-per-request-tag vs. AppLovin-full-abort
  COPPA asymmetry is intentional (each provider's native API surface
  differs), not an inconsistency; `enableFillRateMonitor`/`enableArbitrator`
  are production-safe opt-in tools with no `kDebugMode` distinction; UMP→
  AppLovin consent sync is boolean-only by design since AppLovin MAX SDK
  12.0.0+ auto-reads the IAB TC-String directly; pointers to the existing
  CCPA `CupertinoSwitch` pattern and `consent_dialog.dart`'s binary-only
  rationale for hosts that need more UI; noted the Android VIP-key
  reinstall-replay limitation.
- `example/ios/Runner/Info.plist` synced from 50 → 152 `SKAdNetworkItems`
  entries to match the host app.

## [1.1.1] - 2026-07-18

### Changed
- Bumped `confetti` `^0.7.0` → `^0.8.0` and `connection_notifier` `^2.0.1` →
  `^4.1.0` (dependency freshness, closes Pub Points "up-to-date dependencies"
  gap). No API surface used by this package (`ConnectionNotifierTools
  .initialize()`/`.isConnected`/`.onStatusChange`) changed across
  `connection_notifier`'s 3.x/4.x majors — those breaking changes only
  affected its widget/UI layer, which this SDK doesn't use.

## [1.1.0] - 2026-07-18

### Added — Native Ad format v1 (`buildNative()`)
- New `AdSlotType.native` + `AdScreen.buildNative()`. AdMob renders via
  Google's `NativeAd`/`NativeTemplateStyle(templateType: TemplateType.medium)`
  (same preload-then-`AdWidget` pattern as banner/MREC; the template
  self-draws its own "Ad"/AdChoices label). AppLovin renders via a
  self-contained `MaxNativeAdView` with a custom Dart child layout
  (`MaxNativeAdIconView`/`TitleView`/`MediaView`/`BodyView`/
  `CallToActionView`), for which the package self-draws its own "Ad"
  compliance badge (mirrors MREC's `_MrecContainer` badge). v1 ships one
  fixed layout — not a customizable editor. See README § "Native Ad (v1)".

### Added — MREC ad format (`buildMrec()`)
- Medium-rectangle banner variant (`AdSlotType.mrec`), same lifecycle shell
  as banner (RouteAware pause/resume, VIP suppression, offline collapse,
  auto-refresh gate).

### Added — Smart Monetization Arbitrator + fill-rate monitor
- `monetization_arbitrator.dart`: opt-in per-slot provider arbitration with a
  guardrail against flapping between providers. `fill_rate_monitor.dart`:
  tracks per-slot fill rate over a rolling window for arbitration decisions
  and diagnostics.

### Added — Mediation waterfall reporting
- Adapters now surface mediation waterfall/network response data through the
  existing `AdEvent` stream for host-app-side analytics.

### Added — Consent-country analytics
- Consent events now carry the resolved consent country (GDPR/CCPA scope) so
  host apps can break down consent-rate metrics by region.

### Added — Config validation preflight
- `ad_diagnostics.dart` / `integration_self_check.dart` gained checks that
  catch common misconfiguration (missing ad unit IDs, mismatched provider
  config) before the SDK starts requesting ads.

### Fixed — [High] `AppLovinAdapter.preloadMrec()` crashed the host app when MREC wasn't configured
- `AdManager.initialize()` (and the VIP-loss handler) unconditionally
  preload the MREC slot alongside banner, regardless of whether the host
  app actually uses `buildMrec()`. For AppLovin, an unconfigured MREC
  resolves `AppLovinConfig.mrecId` to its default empty string, and
  AppLovin's native `MaxAdViewImpl.loadAd()` throws
  `IllegalArgumentException: No Ad Unit ID specified` synchronously inside
  an Android `Handler` callback — outside Dart's platform-channel
  try/catch, so it crashed the whole process instead of surfacing as a
  catchable Dart error. Any AppLovin-provider host app that doesn't
  configure MREC (i.e. virtually all apps, since MREC only shipped this
  release) would crash on every SDK init. `preloadMrec()` now skips the
  native preload entirely when `cfg.mrecId` is empty.

### Fixed — [High] `AppOpenTrigger.splashOnly`/`resumeOnly` only gated the SHOW path, not LOAD
- `showAppOpenAd`/`showAppOpenAdOnResume` respected `appOpenTrigger`, but
  `loadAppOpenAd()` (init/VIP-change/retry-refill) never checked it — under
  `splashOnly`/`resumeOnly` the App Open slot kept getting refilled and could
  sit `ready` indefinitely (AppLovin has no AdMob-style 4h TTL), wasting
  network requests/fill quota. Default `both` was unaffected (both gates are
  no-ops there). Now gated behind the same `appOpenTrigger` check as the show
  path.

### Fixed — `redeemVip()` demo mode (`validator == null`) no longer accepts any key in release builds
- Legacy `redeemVip()` accepts any key when `AdConfig.vipKeyValidator` is
  `null`, intended as a zero-config demo mode. A host app that forgot to wire
  a validator would ship this silently — any user typing any string got free
  VIP. `_runValidator` now refuses (`return false`) when `validator == null`
  and `kReleaseMode` is true; debug/profile builds keep the original
  demo-mode passthrough so wiring the integration still works without a
  validator during development. Does not affect `redeemSignedKey()`
  (Ed25519-verified, the path production code actually uses).

## [1.0.24] - 2026-07-16

> Published in two commits the same version: 2026-07-10 (consent-on-init +
> ATT/UMP timeout fixes below) then 2026-07-16 (privacy-options timeout +
> CCPA toggle + SKAdNetwork expansion + doc fixes). Both are live on pub.dev
> under `1.0.24` — the split below is historical, not two releases.

### Fixed — `requestPrivacyOptionsFlow()` could hang forever on a served-but-never-dismissed form (T44)
- The native "Privacy Options" form's dismiss callback only fires after
  `ConsentForm.showPrivacyOptionsForm()`'s own platform call resolves; awaiting
  that call directly (as the code did) meant a stuck/never-dismissed form hung
  the whole call with no way out — bypassing an already-added completer
  timeout that could never be reached. Fixed by not awaiting
  `showPrivacyOptionsForm()` directly (matching the existing fire-and-forget
  shape already used for `requestUmpConsentFlow()`'s form show/dismiss) and
  applying the 20s timeout to the dismiss `Completer` that its callback feeds.
  Test: `test/ump_consent_test.dart`.

### Added — CCPA "Do Not Sell or Share My Info" toggle on `VipRedeemScreen`
- New optional `doNotSellValue`/`onDoNotSellChanged` params render a switch in
  the privacy footer (next to Privacy Policy/Privacy Options), letting a host
  app wire it straight to `AdManager().setConsent(AdConsent(doNotSell: ...))`.
  Opt-in only — omitting `onDoNotSellChanged` (the default) renders the same
  footer as before.

### Docs
- Added a "Known limitations — read before adopting" section to the README
  (ad-policy risk sits with AppLovin/Google, not this package; the real
  ad show/dismiss lifecycle is only partially automatable — 3/15
  integration_test scenarios are manual-only; limited real-world production
  history beyond this repo's own host app; single maintainer, no SLA).
  Written for anyone evaluating this SDK for a new app/partner before a
  wholesale integration.

### Fixed — auto-reload paths bypassed VIP/consent/cap/connectivity gates
- App-Open, Interstitial, and Rewarded adapters (`applovin_adapter.dart`) all
  refill ads directly from their own `onAdHidden`/`onAdDisplayFailed` native
  callbacks, bypassing `AdManager.loadX()` and therefore its gates entirely.
  A user who just redeemed VIP, went offline, or revoked consent could still
  trigger an outbound ad request from a stale in-flight callback. Fixed by
  adding a `canReload()` check (`AdManager` wires it to
  `!_isVipMember && !AdSafetyConfig.dailyCapReached() && _canRequestAds && isConnected`)
  immediately before every such reload call site.

### Fixed — consent silently overwritten by stale data on every `initialize()`
- `AdManager.setConsent()` called before `initialize()` (the real app startup
  order: `requestUmpConsent()` → `initialize()`) used to only mutate an
  in-memory field and return early, because `ConsentManager` wasn't bootstrapped
  yet. `initialize()`'s subsequent `ConsentManager.bootstrap()` then
  unconditionally reloaded the previous session's **stale** persisted consent
  and overwrote it — silently discarding the fresh UMP result on every app
  launch. Fixed by buffering the pending `ConsentSettings` in a new
  `_pendingConsentSettings` field and re-applying it right after bootstrap, so
  it wins over the just-loaded stale data; the buffer is cleared on
  `destroy()` so it never leaks into an unrelated future `initialize()`. Test:
  `test/consent_persistence_on_init_test.dart`.

### Fixed — ATT/UMP consent native awaits could hang `initialize()` forever (T43)
- `requestAttIfNeeded()` and `requestUmpConsentFlow()` each awaited a native
  modal-dismiss (or network) callback with **no timeout**. If the OS/native
  side never resolved it (ATT prompt throttled by rapid repeated launches;
  a UMP form served but never tapped through; a dead network on
  `requestConsentInfoUpdate`), the whole `initialize()` chain never ran —
  the ad SDK stayed silently uninitialized for that app session. All three
  awaits are now wrapped in `Future.timeout(Duration(seconds: 20), onTimeout:
  () => <safe fallback>)`, mirroring the existing App-Open watchdog pattern.
  `requestPrivacyOptionsFlow()`'s dismiss await is deliberately not part of
  this fix — it's a user-initiated re-consent action outside the app-boot
  gating chain. Tests: `test/att_consent_test.dart`, `test/ump_consent_test.dart`
  (`fakeAsync` + never-completing `Completer`, mocking the real
  `google_mobile_ads` UMP method channel with its custom
  `StandardMethodCodec(UserMessagingCodec())`).

### Added — `ssvUserId`/`ssvCustomData` on `AdScreenState.showRewardedAd()`
- `AdManager.showRewardedAd()` already accepted `ssvUserId`/`ssvCustomData` for
  server-side reward verification, but the `AdScreenState.showRewardedAd()`
  convenience wrapper (`lib/src/core/ad_screen.dart`) that most host screens
  actually call did not expose or forward them — any caller passing those
  named args failed to compile. Added both as optional parameters, forwarded
  as-is to the underlying `AdManager` call; no change to the wrapper's
  existing safety-check/disclosure-dialog behaviour.

### Added — durable redeemed-key ledger for signed VIP keys on iOS
- New `RedeemedKeyLedger` (`lib/src/vip/_redeemed_key_ledger.dart`) backs
  `VipManager.redeemSignedKey`'s one-time-use check with an iOS Keychain
  entry, alongside the existing `AdPreferences` (SharedPreferences) check.
  `AdPreferences` alone is wiped on uninstall, so a user could
  uninstall/reinstall to redeem the same signed key repeatedly; the Keychain
  entry survives that. Android intentionally has no durable backstop here,
  same reasoning as the existing `FirstInstallGuard` (no local primitive
  survives uninstall without an install-referrer plugin for a narrow
  benefit) — `AdPreferences` remains the sole check there. Fails open: any
  Keychain read/write error is swallowed and treated as "not redeemed" so a
  storage hiccup never locks out a legitimate key. Test:
  `test/redeemed_key_ledger_test.dart`.

### Added — VIP grace-period expiry nudge
- `VipManager` exposes `graceNudgeThreshold` (default 24h),
  `graceNudgeDueListenable`, and `acknowledgeGraceNudge()`. Once a VIP
  entry's `expiresAt` comes within the threshold, the nudge notifier flips
  true so the host UI can prompt the user to redeem/extend before ads
  resume; acknowledging persists the current `expiresAt` so the same expiry
  doesn't re-nudge, but stacking a new expiry (redeem/watch-ad-to-extend)
  makes it due again. Inactive/no-VIP state is never due. Test:
  `test/vip_manager_grace_nudge_test.dart`.

### Added — VIP entries integrity checksum
- `AdPreferences.getVipEntriesRaw()`/`setVipEntriesRaw()` now store an
  FNV-1a checksum alongside the VIP entries JSON, as a single combined
  `SharedPreferences` value (`'<checksum>|<json>'` written via one
  `setString` call). A mismatched checksum is logged and treated as absent
  data, deterring casual on-device editing of the plaintext VIP entries to
  self-grant free ad-free time — this is a tamper *deterrent*, not
  root/jailbreak-proof protection (a rooted device can still recompute the
  checksum). Pre-upgrade data with no checksum is trusted once and
  backfilled into the new format. FNV-1a was chosen over `String.hashCode`
  (not stable across Dart/Flutter versions) and over the existing async
  `cryptography`-package HMAC (would force every VIP-entries caller async).
  Note: an earlier two-separate-keys design was replaced with the single
  combined key above after it surfaced a real race — a concurrent
  fire-and-forget `VipManager._save()` write could be observed mid-flight
  with one key updated and the other still stale, causing a false
  "tampered" read. Test: `test/ad_preferences_test.dart`.

### Changed — native ad SDK dependency pins retested, still blocked upstream
- Retested bumping `applovin_max`/`gma_mediation_applovin` to the latest
  upstream versions (`4.6.4`/`2.6.1`) to see whether the CocoaPods
  version-pin conflict documented in the host `pubspec.yaml`
  `dependency_overrides` had been resolved. It has not: `2.6.1` now
  requires `meta ^1.17.0`, while `flutter_test` from the CI-pinned Flutter
  SDK (3.35.1) forces `meta 1.16.0` — a Dart-level version-solve conflict,
  never even reaching the CocoaPods layer. No SDK code change; the pins
  stay at `applovin_max 4.6.0` / `google_mobile_ads 6.0.0` /
  `gma_mediation_applovin 2.5.1` in the host app. See
  `doc/audit/audit_partner_lead_20260710.md` findings #2/#3.

### Added — Privacy Options footer button on VipRedeemScreen (T28)
- `VipRedeemScreen` gained `onPrivacyOptionsTap` (`VoidCallback?`) and
  `VipRedeemStrings.privacyOptions`, mirroring the existing
  `onPrivacyPolicyTap`/`privacyPolicy` pair. The footer now renders whichever
  of the two buttons has a non-null callback (previously only the privacy
  policy button existed). Closes the gap where `AdManager().showPrivacyOptions()`
  (T06) had no host call site — GDPR requires a durable re-consent entry
  point, not just a one-time policy link. Test: `test/vip_redeem_screen_test.dart`
  (footer hidden/shown/tap cases for `onPrivacyOptionsTap`).

### Added — rewarded disclosure hook on `AdScreenState.showRewardedAd` (T22)
- `showRewardedAd` gained optional `disclosureTitle`/`disclosureSubtitle`/
  `disclosureButtonLabel`/`disclosureCancelLabel` params. When
  `disclosureTitle` is set, a confirm dialog naming the reward is shown right
  before the ad plays; declining calls `onEarnedReward(false)` and never
  reaches the ad. Omitted (default): behaviour is unchanged — return type
  changed `void` → `Future<void>`, non-breaking via Dart's void-return
  covariance. Test: `test/ad_screen_test.dart` (`rewarded disclosure hook`
  group — confirm/cancel paths).

### Added — load-time daily safety cap gate (T21)
- `AdSafetyConfig.dailyCapReached()` is a new pure read-only check (no
  CTR-anomaly side effects, unlike `canShowFullscreenAd()`). `loadAppOpenAd`/
  `loadInterstitial`/`loadRewardedAd` and the periodic `_retryRefillAds` scan
  now skip preloading once the daily fullscreen-ad cap is hit — previously
  the cap was only enforced at *show* time, so a capped-out user kept
  burning ad-network load requests that could never convert. VIP members are
  unaffected (the existing VIP guard already returns before this check runs
  in every call site). Test: `test/daily_cap_load_gate_test.dart`,
  `test/ad_safety_config_test.dart` (`dailyCapReached` group).

### Fixed — trial hardening: anti clock-rollback + grace-disabled footgun (T17)
- `VipEntry.isActive`/`remaining` now also check `now.isBefore(grantedAt)` —
  previously only `now.isBefore(expiresAt)` was checked, so rolling the
  device clock backwards past a grant's `expiresAt` made an
  already-expired-by-real-time entry "come back to life". A rolled-back
  clock is now treated as the entry having already been consumed
  (fail-safe), not as extra time granted. `VipManager`'s purge/active/
  stacking logic needed no change — everything already routes through
  `VipEntry.isActive`. Test: `test/vip_entry_test.dart` (`anti
  clock-rollback (T17)` group).
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment) when
  `AdConfig.firstInstallVipGrace` is `.disabled` — previously a partner
  could silently ship with no ad-free first-install trial. Test:
  `test/ad_manager_core_test.dart` (`firstInstallVipGrace` cases in the
  `releaseFootgunWarnings` group).

### Added — ad-unit-id validation in release footguns (T16)
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment as the existing dryRun/
  Google-test-id guards) when: any resolved `bannerId`/`interstitialId`/
  `appOpenId`/`rewardedId` is empty, or (AdMob provider only) an id doesn't
  match AdMob's `ca-app-pub-<16 digits>/<ad-unit id>` format — the classic
  "pasted an AppLovin id into the AdMob config" mistake. Test:
  `test/ad_manager_core_test.dart` (`releaseFootgunWarnings` group).

### Added — per-platform ad-unit ids (T15)
- `AdMobConfig`/`AppLovinConfig` gained optional `android*Id`/`ios*Id`
  overrides for `bannerId`/`interstitialId`/`appOpenId`/`rewardedId` (e.g.
  `androidBannerId`, `iosBannerId`). Resolved via `Platform.isAndroid`/
  `Platform.isIOS` at read time, falling back to the existing single id when
  no override is set — fully backward compatible. Test:
  `test/ad_config_platform_test.dart`.

### Added — Privacy Options entry point + re-consent (T06)
- `AdManager().isPrivacyOptionsRequired()` and `AdManager().showPrivacyOptions()`
  (wrapping `ConsentInformation.getPrivacyOptionsRequirementStatus` +
  `ConsentForm.showPrivacyOptionsForm`) are now documented in the README as the
  **required durable re-consent entry point** Google's UMP policy mandates
  (a permanent "Privacy Settings" button). `showPrivacyOptions()` safely no-ops
  (no native UI) when Google doesn't require it for the current user, and
  re-applies the resulting consent to the active ad provider (npa/RDP) when it
  does. Test: `test/privacy_options_test.dart` — required→opens form,
  notRequired→no-op, re-consent re-applies to the active adapter.

### Added — shared `VipRedeemScreen` widget
- Extracted the full VIP redeem screen (hero status, key input, watch-ad-extend,
  active-entries list, buy placeholder, confetti) into the SDK as a reusable
  `VipRedeemScreen` + `VipRedeemStrings` (localizable, mirrors the
  `ConsentDialogStrings` pattern). The host and the SDK example now render the
  **identical** screen — host injects Vietnamese strings, the example uses the
  English defaults. Privacy-policy opening is a callback (`onPrivacyPolicyTap`)
  so the SDK needs no `url_launcher` dependency; `confetti` is added.
- Widget tests: renders inactive state + privacy-footer visibility. Verified on
  a Samsung S24 Ultra.

### Fixed — code-review follow-ups
- VIP: `redeemSignedKey` now claims the key id **atomically** (synchronous
  check + in-flight set) so a concurrent double-tap of the same signed key can't
  slip past the one-time-use check and grant twice. Enforced in the SDK, not
  just the host UI. Test: concurrent double-redeem grants exactly once.
- Consent: `initialize()` logs a **loud runtime warning** when AppLovin's CMP is
  disabled AND `autoRequestUmpConsent` is false AND `requestUmpConsent()` was
  never called before init — the "no consent form anywhere" footgun. Runtime,
  not config-static, so it never false-alarms hosts that gather consent in
  their splash.

### Improved — offline/network UX (T09 + T10)
- T09: verified the banner **collapses** to a zero-size box when offline (no
  shimmer / battery drain) and **reloads automatically on reconnect** (via the
  T08 connectivity watch bumping `initRevision`). Added a widget test.
- T10: `isConnected` now falls back to the **last-known** connectivity state
  (from the T08 watch) with a warning log instead of a silent `true` when the
  detector is unavailable. Kept optimistic on purpose — a broken detector must
  not permanently block ads; genuine offline loads just fail and back off, and
  the watch refills on reconnect (network-error fast-retry is subsumed by T08).

### Hardened — lifecycle & memory (T11 + T12 + T13)
- T13: `AdLoadingDialog.resetState()` (called by `AdManager.destroy()`) now pops
  a still-showing dialog before clearing its flags, so a mid-dialog destroy /
  re-init can't strand a non-dismissable loading dialog on the navigator.
  (`_eventStream` is intentionally left open — it's a process-lifetime singleton
  broadcast exposed publicly; closing it would break host subscribers and it is
  bounded to one instance, so it is not a leak.)
- T11: added regression tests proving the fullscreen single-use guard — a
  second show while one is showing is rejected by the slot state machine
  (`isReady` + atomic `beginShow` + null-on-dismiss), a disposed ad is never
  re-shown, and dispose happens exactly once. (No code change needed; the guard
  already existed — the tests lock it down.)
- T12: `BannerAdWidget` now guards against stacking multiple post-frame
  `_initBanner` callbacks (`_initScheduled`) when `build` runs repeatedly, so a
  banner loads exactly once across rebuilds. (`loadBannerIfNeeded` already
  bailed on a cached ad; this removes the wasteful callback pile-up.)
  (dispose-before-recreate was already handled by that early-return.)

### Added — consent gate + UMP as single CMP (T01 + T03)
- **`AdManager.canRequestAds`** consent gate: every load path (app-open,
  interstitial, rewarded, banner) AND every show path now skips when consent
  hasn't been granted, mirroring Google UMP's `ConsentInformation
  .canRequestAds()`. `requestUmpConsent` stores the result and, when the gate
  opens (blocked→allowed), refills the held slots. Google policy: never request
  or show an ad while `canRequestAds` is false. Defaults `true` so non-UMP /
  non-EEA hosts are unaffected.
- **`AdConfig.autoRequestUmpConsent`** (default false): when true,
  `initialize()` runs UMP before the first ad request and gates on the result —
  the SDK owns the whole consent flow. `umpTagForUnderAgeOfConsent` forwards the
  under-age flag.
- **`AdConfig.disableAppLovinCmpFlow`** (default true): the AppLovin adapter
  disables AppLovin's own Terms & Privacy (CMP) flow so UMP is the single
  consent prompt — no double prompt. UMP's result is still forwarded to AppLovin
  via `setHasUserConsent`.
- **T03**: the splash App Open ad (even `bypassSafety: true`) no longer shows an
  impression before consent is resolved; the show gate also prevents a
  previously-loaded ad from showing after consent is revoked.

### Added — offline signed VIP keys (T18)
- New `verifySignedVipKey` + `VipManager.redeemSignedKey` verify Ed25519-signed
  keys **offline** against an embedded public key. Only the public key ships, so
  a decompiler cannot forge new keys (the old local base64 map could be extracted
  and reused infinitely). VIP duration is encoded in the key.
- Per-device one-time-use: a redeemed key id can't be redeemed again on the same
  device (`AdPreferences` redeemed-id store). Global one-time-use still needs a
  server — documented as a known offline limitation.
- New deps: `cryptography` (pure-Dart Ed25519). Tooling: `tool/vip_keygen.dart`
  (generate a key pair) and `tool/vip_mint.dart` (mint signed keys with the
  private key — never shipped). See README → "Signed VIP keys".
- Host `vip_keys.dart` now holds only the public key + demo keys; `vip_screen`
  redeems via `redeemSignedKey`.

### Added — connectivity auto-refill on reconnect (T08)
- The SDK now initialises `ConnectionNotifierTools` (nobody did before, so
  `isConnected` silently always returned `true` and the offline guards never
  fired) and subscribes to `onStatusChange`.
- On an offline→online transition the SDK refills idle/cooldown ad slots,
  nudges the banner preload, and bumps `initRevision` so banner widgets re-init
  — within ~1s (debounced) instead of waiting up to 5 min for the poll timer.
  Suppressed for VIP members and while uninitialised. Subscription cancelled on
  `destroy`. Test seams: `debugConnectivityChanged`, `debugReconnectDebounce`.

### Fixed — AdMob non-personalized ads (`npa`) now actually applied (T02)
- Previously `applyConsentToProviders` only set AdMob's global
  `RequestConfiguration` (COPPA/age tags) and never attached the per-request
  non-personalized flag, so a user who declined consent could still be served
  **personalized** AdMob ads. The doc comment claimed an `npa` extra was
  forwarded, but no code did so.
- `AdProviderAdapter` gains `applyConsent(AdConsent)`. `AdMobAdapter` maps
  `!hasUserConsent` → `AdRequest(nonPersonalizedAds: true)` on **every** load
  (banner, interstitial, rewarded, app open); it defaults to non-personalized
  until consent is applied and resets to that on `dispose`. `AppLovinAdapter`'s
  implementation is a no-op (it forwards consent via static `AppLovinMAX` APIs).
- `AdManager` calls `applyConsent` on the adapter at init, from `setConsent`,
  and on any `ConsentManager` change (auto dialog / set / reset / privacy
  screen), so personalization tracks consent across every path.
- Tests: adapter-level npa propagation + AdManager wiring (integration) +
  UI-driven consent (widget). Example app shows a live "personalized vs
  non-personalized" indicator on the Consent page.

## [1.0.23] - 2026-06-15

### Changed — App Open ad never stacks on top of a modal
- `AdScreenRouteLogger` now tracks how many `PopupRoute`s (dialogs, bottom
  sheets, Cupertino popups) are on the navigation stack and exposes
  `AdScreenRouteLogger.isDialogOnTop`. `showAppOpenAdOnResume` consults it (plus
  `AdLoadingDialog.isShowing`) and **skips the App Open ad while any dialog is
  presented** — e.g. the consent dialog or a VIP redeem confirmation. Showing a
  fullscreen ad over a modal is bad UX and an AdMob policy risk. The counter is
  reset by `AdManager.destroy()` so a mid-dialog teardown can't wedge it.

### Fixed — retry-refill scan bails early for VIP members
- `_retryRefillAds` now returns immediately when the user is a VIP member.
  Each `load*()` already guarded on VIP, so behaviour is unchanged, but this is
  a defense-in-depth backstop and avoids a pointless periodic scan/log.

## [1.0.22] - 2026-06-15

### Added — VIP time stacking + rewarded-while-VIP
- `VipManager.addVip` and `redeemVip` gained a `stack` flag (default `false`,
  fully backward compatible). With `stack: true`, the grant **accumulates onto
  the latest expiry across ALL active entries** (global stacking) — so VIP time
  from every source (redeem code, watch-ad) adds to one growing window (e.g. ~6
  active days + a 30-day code ⇒ ~36 days). The granted key's entry becomes the
  new latest (created if new, updated if it existed) and `grantedAt` resets to
  now. Without `stack`, the default latest-expiry-wins replacement is unchanged.
- `AdManager.showRewardedAd` gained a `bypassVipGuard` flag (default `false`).
  When `true`, a VIP member can voluntarily watch a **real** rewarded ad (e.g. to
  extend their own VIP window). Since the rewarded slot is not preloaded while
  VIP, the SDK loads it on demand and waits before showing. No auto-grant — the
  reward is still only earned by completing the ad. Policy-compliant (a real ad
  is shown).
  - On-demand load observes the slot's **public** `AdSlot.state` notifier (not
    the internal `pendingCallback`), with a caller-tunable `onDemandLoadTimeout`
    (default 15 s) param on `showRewardedAd`.
  - A blocking `AdLoadingDialog` covers the on-demand wait (new
    `AdLoadingDialog.show()` / `dismiss()` non-timed pair).
  - `showRewardedAd` is now **re-entrancy-safe**: a second call while a first is
    mid load/show is rejected (`onEarnedReward(false)`), independent of any
    caller-side lock.
- `AdConfig.maxVipStackDuration` (default `null` = uncapped) — optional cap on
  the **total** window produced by stacking. When set, a stacked grant is clamped
  to `now + maxVipStackDuration`. Plumbed to `VipManager` at init.

### Tests
- +24 tests (222 total). `vip_manager_stacking_test.dart` (13 — global stacking
  incl. cross-key + order-independence, cap clamp, persistence, notifier,
  watch-ad fixed-key); `rewarded VIP-bypass` group in `ad_manager_core_test.dart`
  (6 — default vs. bypass, on-demand success/failure, non-VIP, re-entrancy guard);
  `rewarded_ondemand_dialog_test.dart` (2 widget — cold-VIP loading dialog during
  async on-demand load + timeout dismissal).

## [1.0.21] - 2026-06-15

### Changed — dependency refresh
- `google_mobile_ads` `^6.0.0` → `^7.0.0`, `flutter_secure_storage` `^9.2.4` →
  `^10.0.0`, `applovin_max` `^4.6.3` → `^4.6.4`. No public-API change; all 132
  tests pass. (Bumping `google_mobile_ads` to 8/9 requires Dart ≥3.10 / a newer
  Flutter, so 7.x is the current ceiling; `connection_notifier` is kept at
  `^2.0.1` because `^4` pulls `connectivity_plus 7`, which conflicts with hosts
  on `connectivity_plus 6`.)
- Dropped the deprecated `encryptedSharedPreferences` AndroidOptions flag
  (flutter_secure_storage 10 auto-migrates).

### Example
- Interstitial demo now passes `placement: AdPlacement.levelComplete` to show
  per-placement revenue tagging; VIP demo documents the `AdConfig.vipDeviceGaids`
  allow-list + `isVIPMember()`.

## [1.0.20] - 2026-06-14

### Example only
- The bundled example (`example/lib/main.dart`) now demonstrates the recommended
  consent ordering in its splash: `AdManager().requestAtt()` →
  `AdManager().requestUmpConsent()` → `AdManager().initialize()`. No library /
  public-API change vs 1.0.19 — upgrading requires nothing.

## [1.0.19] - 2026-06-14

### Added — iOS App Tracking Transparency
- **`AdManager().requestAtt()`** / **`requestAttIfNeeded()`** — show the iOS ATT
  prompt when needed and return a structured `AttResult { status, idfa,
  allowsTracking }` (`AttStatus` enum). No-op on Android; never throws (degrades
  to `denied`). Call it in the splash **before** `requestUmpConsent`. Requires
  `NSUserTrackingUsageDescription` in `Info.plist`. Decoupled from the GDPR
  consent flag — the native SDKs read ATT directly for IDFA.

### Fixed
- **iOS App Open watchdog false-positive** — the lifecycle-aware show timeout no
  longer force-dismisses on iOS, where the ad shows while the app stays
  `resumed`. The "foreground = hung" heuristic is now Android-only; iOS relies on
  the native hidden/displayFailed callbacks plus the 90 s hard cap.
- **AppLovin reload-after-display-fail** — a slot is no longer stranded by the
  backoff window after a *show* failure; it refills immediately via the new
  `AdSlot.beginReload()` (genuine load failures still back off).
- **AdMob parity** — App Open now has a 90 s show watchdog; interstitial/rewarded
  honour a 1 h freshness expiry; the banner slot transitions to `loading` before
  the native `BannerAd` is created (fixes a synchronous-fill race).

### Internal
- Both adapters now load through an injectable bridge (`AppLovinBridge` /
  `GmaBridge`) for full behavioural unit-test coverage. No public-API change.

### Compliance / docs
- Removed the rewarded→interstitial reward fallback (rewarded-policy compliance);
  removed the interstitial on "Start" actions in the example host.

Upgrading from 1.0.18 requires no code changes for existing integrations. To use
ATT, add `NSUserTrackingUsageDescription` and call `AdManager().requestAtt()`.

## [1.0.18] - 2026-04-27

### No code changes
- Version bump only. Runtime behaviour, public API surface, and bundled
  assets are identical to 1.0.17. Upgrading from 1.0.17 to 1.0.18
  requires no code changes — only a `pubspec.yaml` version bump and
  `flutter pub get`.

## [1.0.17] - 2026-04-27

### Added — Anti-uninstall-bypass for first-install VIP grace (iOS-side)
- **`FirstInstallGuard`** (internal, `lib/src/vip/_first_install_guard.dart`) —
  protects the `firstInstallVipGrace` feature against the trivial bypass
  of "uninstall + reinstall to claim a fresh 24-hour grace window."
  Wired automatically inside `AdManager.initialize`; host apps need no
  code changes.
- **iOS defence** — writes a single boolean flag to the iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no
  `kSecAttrAccessGroup`). Keychain entries persist across app uninstall
  by default on iOS, so a reinstall on the same device finds the flag
  and the guard skips re-granting. Deliberately uses a constant flag
  rather than `identifierForVendor` (IDFV) — Apple resets IDFV when the
  user deletes all of a vendor's apps and reinstalls, which would let
  a standalone-app reinstall silently bypass the guard.
- **Android defence (host-app responsibility)** — there is no reliable
  local-only Play Install Referrer signal that distinguishes a fresh
  install from a reinstall (per Google's docs, referrer info is reset
  when the application is reinstalled). Real Android anti-bypass relies
  on the host app's **Auto Backup** configuration restoring
  `FlutterSharedPreferences.xml` (which contains the
  `prefs.isFirstInstallGraceApplied()` flag) on Play Store reinstall,
  short-circuiting the outer grace block before the guard runs. The
  guard itself returns `false` (allow grace) on Android — anti-bypass
  is performed entirely by the host's `AndroidManifest.xml` /
  `<data-extraction-rules>` + Google Cloud Backup.
- **Call-order guarantee (iOS)** — `AdManager` writes the Keychain
  anti-bypass flag *before* the `prefs.markFirstInstallGraceApplied()`
  flag, so a process kill between the two writes leaves the persistent
  marker set and the next install on the same device is still blocked.
- **Debug bypass** — `kDebugMode` builds skip both `hasAlreadyGranted`
  and `markGranted`, so QA can iterate on `flutter run` without the
  Keychain signal locking them out of the grace UX. Anti-bypass
  validation must happen on signed release builds (TestFlight / Play
  Store internal track).
- **Fail-open philosophy** — every storage error is caught and logged;
  the guard returns `false` (allow grace) so a transient Keychain
  hiccup never denies grace to a legitimate first-time user.
- **15 new unit tests** covering debug bypass, Keychain present/absent/
  tampered/error, Android always-grant behaviour, `markGranted`
  no-op on Android, idempotency, and fail-open error swallowing.

### Changed
- New required dependency for the iOS guard:
  - `flutter_secure_storage: ^9.2.4` — iOS Keychain wrapper.
- Approximate binary size delta: +400 KB (Keychain wrapper native code).

### Host-app integration notes
- **Android (required for anti-bypass)** — add Auto Backup configuration
  to `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <application
      android:allowBackup="true"
      android:dataExtractionRules="@xml/data_extraction_rules"
      android:fullBackupContent="@xml/full_backup_content">
  ```
  Create `android/app/src/main/res/xml/data_extraction_rules.xml`
  (Android 12+) and `full_backup_content.xml` (Android 6-11) including
  `FlutterSharedPreferences.xml` so Google Auto Backup restores the
  grace flag on Play Store reinstall.
  Without these, **Android anti-bypass does not work** — uninstall +
  reinstall always re-grants the grace window. (Acceptable for many
  apps; configure Auto Backup only if you want to block this bypass.)
- **iOS** — no host-side configuration required.

### Removed
- **`play_install_referrer` dependency** — initially included for an
  Android conservative-skip path, removed after research confirmed
  Install Referrer cannot detect Play Store reinstall (timestamps
  reset per Google's documented behaviour). Real Android anti-bypass
  comes from Auto Backup, not Install Referrer.

### Limitations (documented, not fixed)
- **iOS factory reset** ("Erase All Content and Settings") wipes
  Keychain → bypass succeeds. Acceptable; factory resets are rare.
- **Android Play Store reinstall without Auto Backup or within Auto
  Backup's ~24 h cache window** still bypasses the guard. This is a
  fundamental local-only limitation — closing it requires a backend
  (Firebase Anonymous Auth + Firestore, or a custom server).
- **iOS encrypted backup restore to a new device** could carry the
  Keychain flag onto the new device, denying that device's first
  install grace. Edge case; acceptable trade-off vs. weakening
  anti-bypass on the primary device.

## [1.0.16] - 2026-04-26

### Documentation
- **Full English rewrite of `README.md`** — restructured into 13 sections
  with table of contents. Quick start expanded into 6 copy-paste steps
  any Flutter developer can follow without prior AdMob/AppLovin knowledge.
  Added complete public API reference, FAQ, and dedicated Pitfalls section
  covering the `android:taskAffinity=""` issue (the most common cause of
  perceived crashes during background → foreground ad cycles).
- **Full English rewrite of `MIGRATION.md`** — clear 1.0.14 → 1.0.15
  upgrade path (no breaking changes), plus legacy 1.x → 2.x path with
  auto-migration details. Added Common issues and FAQ sections.
- **Full English rewrite of `doc/architecture.md`** — deep-dive for
  contributors and advanced integrators. Added detailed sections on the
  Smart App-Open timeout, Slot-state dismiss watcher, Consent flow
  sequence, Memory management contract, and Manifest pitfalls.

### No code changes
- This is a documentation-only release. The runtime behaviour, public
  API surface, and bundled assets are identical to 1.0.15. Upgrading
  from 1.0.15 to 1.0.16 requires no code changes — only a `pubspec.yaml`
  version bump and `flutter pub get`.

## [1.0.15] - 2026-04-26

### Fixed
- **AppLovin App-Open timeout false-positive** — old fixed 10 s timeout fired
  while user was still interacting with the ad (click → browser → return),
  marking dismiss with `false` and arming the resume guard prematurely.
  Replaced with lifecycle-aware polling: re-arms every 5 s while app is
  paused (= ad still showing), force-dismisses only when app is foreground
  for 2 consecutive ticks without `onAdHiddenCallback` (hard cap 90 s).
- **Banner paid-event not wired** — `BannerAd` extends `AdWithView` which
  has no `onPaidEvent` setter; previous dynamic dispatch silently failed.
  Banner revenue is now correctly emitted via `BannerAdListener.onPaidEvent`
  constructor parameter.
- **App-open shown immediately after rewarded dismiss** — `_lastFullscreenDismissAt`
  was recorded inside the rewarded `onDone` callback which fires on
  reward-earned (mid-video), not on actual dismiss. Replaced with slot-state
  watchers that fire on `showing → !showing` transition for all 3 fullscreen
  slots — authoritative dismiss timestamp regardless of adapter quirks.
- **VIP grace not auto-expiring mid-session** — added `Timer` in `VipManager`
  scheduled for the soonest `expiresAt`. Fires `_purgeExpired` + `_refreshActive`
  when an entry expires, so the SDK reflects VIP loss without requiring a
  full re-init. Especially relevant for short debug grace windows.
- **Inter/rewarded/app-open not preloaded after VIP expires mid-session** —
  added listener on `VipManager.activeListenable`; on `true → false` flip,
  triggers `loadAppOpenAd + loadInterstitial + loadRewardedAd + preloadBanner`
  so the user doesn't see "ad not ready" on first show after losing VIP.
- **`canShowFullscreenAd` / `canShowAppOpenOnResume` reported "wait 0s"** —
  sub-second waits truncated to 0. New `_fmtWait(ms)` helper renders ms when
  < 1 s ("wait 645ms") and 1 decimal seconds otherwise ("wait 1.5s").
- **Splash budget warning fired while splash app-open ad still showing** —
  `_armSplashBudget` now detects `appOpenSlot.isShowing` on first elapse
  and re-arms a 30 s hard cap instead of force-firing `markSplashInactive`.
- **`canShowAppOpenOnResume` returned `bool`** — refactored to return
  `AdSafetyResult` (canShow + reason), aligning with `canShowFullscreenAd`.
  Callers can log the specific block reason + remaining wait time.

### Added — Consent flow
- **`ConsentManager`** — standalone helper class owning the Cupertino consent
  dialog UI, persistence (`SharedPreferences`), and provider apply pipeline.
  Accessible via `AdManager().consentManager` or `ConsentManager.instance`.
- `ConsentSettings` — persistent user-choice record with `hasBeenAsked`,
  `askedAt`, JSON serialisation.
- `ConsentDialogStrings` — localisation, includes `ConsentDialogStrings.vi`
  for Vietnamese.
- Custom binary Cupertino dialog (Allow / Reject) with hero icon, gradient
  Allow button, accent colours, scale-in animation, haptic feedback.
- `AdConfig.autoShowConsentDialog` (default `true`) — SDK auto-presents the
  dialog ~1 s **after** `markSplashInactive` (post-splash, on home), not
  during splash flow. Skipped for VIP users.
- `AdConfig.consentDialogPostSplashDelay` (default 1 s) — tunable.
- `AdConfig.consentBarrierDismissible` (default `false`).

### Added — UMP (User Messaging Platform) wrapper
- `requestUmpConsentFlow(testMode, debugGeography, testIdentifiers, …)` —
  wraps Google's built-in `ConsentInformation` + `ConsentForm` (no extra
  dependency, available since `google_mobile_ads` 6.x).
- `AdManager().requestUmpConsent(…)` — auto-applies UMP result to providers.
- Re-exports `ConsentStatus` and `DebugGeography` from `google_mobile_ads`
  so callers don't need a direct import.

### Added — First-install VIP grace
- `AdConfig.firstInstallVipGrace: FirstInstallVipGrace` (default `auto` =
  30 s in debug, 24 h in release) — auto-grants a one-time VIP entry on the
  very first SDK init for this install. Improves D1 retention by giving
  the freshly-installed user an ad-free first session.
- `FirstInstallVipGrace` class with `auto` / `disabled` / `day` /
  `debugShort` presets and custom `Duration` constructor.
- `AdConfig.firstInstallVipKey` (default `__FIRST_INSTALL__`) — VIP entry
  key for analytics discrimination.
- `AdPreferences` — new keys `_keyFirstInstallApplied` (one-shot guard)
  and `_keyFirstInstallAt` (epoch-ms install timestamp for analytics).

### Added — Diagnostic logging
- `🚀 AdManager singleton CREATED` marker fires once per process on cold
  start. Two markers in the same logcat session = Android killed and
  restarted the process.
- `🚨 lifecycle DETACHED` warning when Flutter engine tears down.
- Lifecycle observer logs full state (prev → current, slot states, VIP
  flag, splash flag, backgrounded duration) — wrapped in `_safeLifecycleLog`
  so a closure-evaluation throw cannot abort the observer.
- All ad-load/show paths emit explicit `⏭️ skipped — <reason>` logs for
  every gate (adapter null, VIP, no network, slot showing, safety reason)
  instead of returning silently.
- AppLovin `onAdDisplayedCallback` extended with `network`, `creativeId`,
  `placement`, `latencyMillis` for revenue diagnosis.
- Memory-pressure log throttled to 60 s/event so fast bg/fg cycles
  don't flood the buffer; payload includes banner state and VIP flag.
- `DebugAdOverlay` — new `enabled` constructor flag plus static
  `globallyVisible` `ValueNotifier` for runtime toggle (e.g., from a
  shake-menu or dev console).

### Added — Misc
- `AdConfig.autoShowConsentDialog` skip path also covers the case where
  the user redeems a VIP key during the 1 s post-splash schedule window
  (re-checked at fire time).
- `AdManager.processStartedAtMs` getter.

### Changed
- `loadInterstitial` / `loadRewardedAd` / `loadAppOpenAd` / `showInterstitial`
  / `showRewardedAd` / `showAppOpenAd` skip-path logs now name the specific
  reason (adapter null vs VIP vs no network vs already showing vs safety).
- Banner preload during VIP active is now skipped at AdManager level —
  saves a network request and avoids inflating internal impression counter.

### Notes for integrators
- **Activity manifest**: do **not** set `android:taskAffinity=""` on your
  `MainActivity` when using AppLovin. With empty affinity, AppLovin's
  `AppLovinFullscreenActivity` lands in a different Android task; after
  user backgrounds + foregrounds and dismisses the ad, the task may be
  empty and the user is dropped to launcher. Default affinity (= package
  name, by simply omitting the attribute) is safe.

## [1.0.14]

### Bug Fixes
- **Fix #48** — `_assertInitialized` no longer throws; returns `bool` with warning log. All call sites now gracefully early-return when the SDK is not yet initialized.
- 47 prior numbered fixes (Fix #1 through Fix #47) — see git history for individual entries. Production-hardened single-file `AdManager` baseline with 12-layer safety.
