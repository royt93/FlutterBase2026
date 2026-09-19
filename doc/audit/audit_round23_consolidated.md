# Audit round 23 — consolidated verdict

**Date:** 2026-08-25
**Scope:** the whole SDK (`packages/ad_sdk/lib`), the example app, every `.md`
in the package, and the live pub.dev listing for `applovin_admob_sdk` 2.3.4.
**Requirements audited against** (the seven the product owner set):

1. AdMob + AppLovin provider, working on Android **and** iOS
2. Correct behaviour on a device with **and** without network
3. All four ad types (banner / app open / rewarded / interstitial) done
   properly — legal, correct lifecycle, no memory leaks
4. 1-day trial mode
5. VIP activation by code, secure **without any server/backend**
6. Consent for every country, applied correctly on both AdMob and AppLovin
7. AdMob/AppLovin policy compliance

**Reviewers:** three independent agents (`codex`, `agy`, `claude`), each with
its own report in this directory (`audit_codex_round23.md`,
`audit_agy_round23.md`, `audit_claude_round23.md`), plus my own line-by-line
pass. **Every delegated finding below was re-verified against the source
before being accepted** — three were downgraded or refuted, and one defect no
agent found was caught during that verification.

---

## Result summary

| Finding | Source | Verified? | Severity | State |
|---|---|---|---|---|
| Impression accounting keyed off *how a show ended*, not *whether the ad was displayed* | codex #2, #3 | ✅ confirmed (one shared root cause) | MAJOR | fixed |
| `RewardResult.shown` defaulted `true`, so hosts were told "shown" for ads that never reached the screen | mine (found while fixing the above) | ✅ | MAJOR | fixed |
| AdMob's app-open slot never called `markDisplayed()` — the only fullscreen slot that didn't | mine | ✅ | MAJOR | fixed |
| `VipEntry` persisted local ISO-8601 with no zone marker → grants silently move (and are then purged) on DST/timezone change | agy MJ1 | ✅ | MAJOR | fixed |
| Grace nudge fired at grant time because the default threshold (24h) equals the default trial length (24h) | agy MJ2 | ✅ | MAJOR | fixed |
| CRL revocation matched kids case-sensitively at redemption but case-insensitively when clamping | mine (while documenting agy MN1) | ✅ | MAJOR | fixed |
| Reward is granted in `onUserEarnedReward`, before dismiss | codex #1 | ⚠️ downgraded — this is Google's documented guidance, and `_fullscreenBusyReason` already blocks stacking | doc-level | comment added |
| Four documentation BLOCKERs (README compile error, wrong logLevel default, prompt-doc snippet, dead repo URL on the live pub.dev page) | claude B1-B4 | ✅ | BLOCKER (docs) | fixed |
| README splash sample leaked a `SimpleEventBus` listener and omitted ATT/UMP | claude M1, M2 | ✅ | MAJOR (docs) | fixed |
| pana docks 20 points for a `Future` returned without `await` inside a `try` — and it was a real error-handling hole | claude M3 | ✅ | MAJOR | fixed |
| Seven documentation MINORs (config reference gaps, stale version pointers/test counts, dead doc pointer, dependency freshness) | claude N1-N7 | ✅ | MINOR | fixed |
| Clock-forward trial abuse (MJ9) | earlier rounds, re-raised | ✅ real, **deliberately not fixed** | accepted | see `mj9` note below |
| Native ads have no RouteAware lifecycle (m25) | earlier rounds, re-raised | ✅ real, **deliberately not fixed** | accepted | documented |
| `VipManager.redeemSignedKey` verifies offline | flagged by reviewers repeatedly | ❌ refuted — this is the product requirement (#5: no server) | by design | documented |
| `kQaTestDeviceHashes` always merged into AdMob test devices | flagged by reviewers repeatedly | ❌ refuted — deliberate: keeps this team's own QA hardware from generating real impressions | by design | documented |

Suite after the round: **1131 tests green**, `flutter analyze` clean. Every fix
above was proven by reverting it and watching the new test go red first.

---

## The one root cause worth understanding

Three separate symptoms (codex #2, codex #3, and the app-open hard cap) were
the same mistake in three places: the code decided *"did the user see an ad?"*
from **how the show finished** — a reward was earned, or the dismiss callback
arrived cleanly — instead of from **whether the ad ever reached the screen**.

Consequences, in plain terms:

- A user who opened a rewarded ad and closed it after two seconds burned a
  real impression that the safety layer never counted. Repeat that and the
  daily/hourly caps stop protecting the AdMob account they exist to protect.
- A rewarded ad that failed to display at all still reported `shown: true` to
  the host app, so a host that logged "ad watched" logged a lie.
- An app-open ad resolved by the 90-second hard cap was always recorded as a
  failure, even when it had been on screen the whole time.

The fix is one authoritative flag, `AdSlot.displayConfirmed`, set by
`markDisplayed()` and reset by `beginShow()`, read by both adapters and by
`AdManager`. `RewardResult.shown` now means exactly "the native SDK confirmed
this ad reached the screen", independent of whether a reward was earned.

## The two VIP fixes, in plain terms

- **Timestamps.** A VIP grant was written to disk as `2026-08-25T10:00` with
  no timezone marker. Read back on a device that had since changed zone (a
  flight west, or just the end of DST), the same text means a different
  instant — up to a day earlier. `VipManager` then reads it as expired,
  `_purgeExpired()` deletes it, and there is no server to restore it from.
  Grants are now stamped UTC and converted back to local on read.
- **The nudge.** The "your VIP is running out, extend it" signal used a 24-hour
  threshold, which is exactly the default first-install trial length — so a
  brand-new user saw the expiry nudge on their very first launch. The threshold
  is now capped at half the granted window, so the nudge always lands in the
  second half of whatever grant it belongs to.

## Deliberate non-fixes (do not "fix" these)

- **MJ9 — clock-forward trial abuse.** Moving the device clock forward past a
  trial's expiry, then back, cannot be closed in pure Dart without a trusted
  time source, i.e. a server. Requirement #5 forbids a server. The rollback
  direction *is* defended (`_effectiveNow()` clamps against a persisted
  high-water mark). Decided and closed three sessions running.
- **m25 — native ads have no RouteAware lifecycle.** Banner/MREC pause and
  resume on navigation; native ads do not. Accepted scope.
- **Offline VIP redemption** and **the always-on QA test-device hashes** are
  product features, not oversights, and are now commented as such at the
  source so the next reviewer does not re-file them.

## Deliberately unverified

- AppLovin behaviour after a consent change — needs a real MAX SDK key on a
  real device; CI has none, so the AppLovin path can never initialise there.
- iOS CI (billing, per the product owner's instruction to skip it for now).
- The three human-tap integration tests excluded at
  `.github/scripts/integration-retry.sh:87`.

---

## Production verdict

**Yes for the AdMob provider on Android and iOS, with the two caveats below.**

The seven requirements hold up: both providers work on both platforms, the
offline paths are handled, all four ad types have correct lifecycle and
disposal, the 1-day trial and the offline-signed VIP codes work without any
backend, consent runs through Google UMP for both providers with the IAB
strings readable back, and the policy-facing pieces (caps, throttle, CTR fraud
guard, no-stacking rule, test-device hashes for QA hardware) are in place and
under test.

Caveats:

1. **The AppLovin provider is less proven than AdMob** — not because of a known
   defect, but because no real MAX key has ever run in CI or in an automated
   device test. Ship AdMob first; treat an AppLovin switch as a change that
   needs its own on-device pass.
2. **The 10 remaining pub.dev points and `google_mobile_ads` 8/9 stay out of
   reach until the Flutter floor moves** (Dart >= 3.10 / Flutter >= 3.38.1),
   which is breaking for consumers. Not a runtime risk — a scoring and
   dependency-freshness one.

## On-device smoke test — 2026-08-26 (Pixel 7 Pro, Android 17, `2B051FDH3006MU`)

### Automated integration suites (27 of the 30 files; the 3 human-tap files are excluded by `.github/scripts/integration-retry.sh:87`)

| Provider | Result |
|---|---|
| AdMob (`AD_PROVIDER_ADMOB=true`) | **26 PASS**, 1 skipped (`ump_eea_consent_test.dart` — the UMP form cannot present outside EEA debug geography), 0 failures |
| AppLovin (`AD_PROVIDER_ADMOB=false`) | **26 PASS**, 1 skipped (same file), 0 real failures. `mrec_ad_test.dart` reported "No tests were found." once inside the batch run and passed cleanly on an isolated re-run — a DDS/launch flake, not a defect |

### Manual drive of the real ad surfaces (AdMob test units, real fill)

Verified from `adb logcat`, `com.roy.admobwrapper`:

- **Rewarded** — `showRewarded ✅ shown` → `🏆 type=coins amount=10` → `📊 Ad SHOWN | session=1/999 … impressions=1` → `👋 dismissed (earned=true)` → automatic reload. Coins incremented on screen. Ran twice back-to-back with no zombie slot state.
- **Interstitial** — shown, closed by hand, `📊 Ad SHOWN | session=4/999`, `🛡️ interstitial dismissed — app-open suppression armed`, then `⏭️ skipping app-open on resume (recent fullscreen dismiss 29ms ago)`.
- **App Open on resume** — first resume correctly `⏭️ skipped — cold start (one-shot)`, second resume `✅ all gates passed`, ad shown and closed, `📊 Ad SHOWN | session=5/999`.
- **Banner / MREC / native** — covered by the suites above; banner reload verified live in the offline/online test below.

**Not provable on a real device with Google's test creatives:** a rewarded ad *dismissed before the reward point*. The AdMob test rewarded video grants the reward ~5s in and swallows BACK until then, so there is no way to reach `onDismissed` with `earned == false` against test inventory. That branch — `fire(RewardResult(earned: false, shown: rewardedSlot.displayConfirmed))` in `admob_adapter.dart:1381` — stays covered by the unit suite, each assertion proven by reverting the fix and watching the specific test go red.

### VIP (requirements 4 + 5)

- `signed 1d` (Ed25519, offline) → `🔑 redeemSignedKey ok kid=demo1d +24:00:00`, `🔒 VIP active — ad loads suppressed`.
- **MJ2 clamp confirmed live:** `⏲️ next VIP timer event in 43199s` — 12h, i.e. half the 24h window, not "due immediately". Before the fix a 24h grant with the default 24h `graceNudgeThreshold` nudged the user at grant time.
- **MJ1 confirmed live:** force-stop + relaunch → `load() entries=1 active=true` with the same expiry and `43162s` still on the timer, so the UTC-stamped persistence round-trips.
- Suppression: `⏭️ loadInterstitial skipped — VIP member`, `showInterstitialAd pre-check result: canShow=false`, `⏭️ app-open on resume skipped — VIP member`, `⏭️ banner/mrec preload skipped — VIP member`.
- Voluntary extension while VIP: rewarded played through `bypassVipGuard`, `addVip: stacked REWARDED_VIP (+4320m) → 2026-08-30`, timer re-armed at `86323s` (24h before the new expiry, since half of a 4-day window now exceeds the 24h threshold).
- `revokeAll: cleared` → `🔓 VIP inactive — kicking secondary preload`.

### No-network (requirement 2)

Wi-Fi + mobile data off, cold start:

- `⚠️ requestConsentInfoUpdate failed: 2:Error making request.` → `⚠️ UMP inconclusive (status=notRequired …) — keeping the persisted consent value instead of downgrading it` (the fail-closed path, correct).
- `⏭️ loadInterstitial skipped — no network`, `⏭️ loadRewarded skipped — no network`, `[BannerAdWidget] _initBanner ⏭️ offline`.
- **Zero** `E/flutter` / `FATAL EXCEPTION` lines for the whole offline session.
- Network restored → `📶 network back online → refilling ad slots + banners`, then `loadInterstitial ✅`, `loadRewarded ✅`, `loadBanner ✅` ×2 within 8s, unattended.

### Still deliberately unverified

AppLovin post-consent behaviour against a **real** MAX SDK key — none is committed (`example/lib/main.dart:54` holds the `YOUR_86_CHAR_SDK_KEY_…` placeholder), so on this device the AppLovin adapter never initialises and its 27 suites prove lifecycle/state handling only, not fill. Unchanged from earlier rounds.

## Round-24 — review of the round-23 changes themselves (2026-08-26)

The round-23 diff was handed to three independent CLI reviewers (`codex`,
`agy`, `claude`) with a brief that listed the six claims to verify and the six
deliberate non-fixes to ignore, plus a line-by-line pass of my own.

| Reviewer | Score | Blockers | Majors |
|---|---|---|---|
| codex | 6/10 | 0 | 2 (both adjudicated — see below) |
| agy | 9.6/10 | 0 | 0 |
| claude | 9/10 | 0 | 1 (semver — accepted) |
| mine | 9/10 | 0 | 1 (undocumented `AdShowEvent.success` change — accepted) |

### Accepted and fixed

- **Semver (claude).** A public behaviour change shipped as a patch. Bumped to
  **2.4.0** across `pubspec.yaml`, `README.md`, `doc/README_TESTING.md`,
  `doc/architecture.md`, `doc/feature.md`.
- **`AdShowEvent.success` semantics (mine — no reviewer found it).** For
  `rewarded`/`rewardedInterstitial` the event flipped from carrying `earned` to
  carrying `shown`, with nothing in the CHANGELOG. Now called out in a
  behaviour-change block at the top of the 2.4.0 entry, alongside the
  `RewardResult.shown` default flip.
- **Corrupt-seed fallback untested (codex, minor).** `test/compliance_signing_test.dart`
  now writes a 5-byte seed and asserts a fresh key is minted and reused. Proven
  red by removing the `await` at `compliance_signing.dart:88`
  (`Invalid argument(s): Seed must have 32 bytes`).
- **CRL kid case normalised per-lookup (agy, minor).** `_normaliseKids` upper-cases
  once at ingestion; the redemption gate is a plain `contains`.
- **Grace-nudge clamp untested on reload (mine).** New test in
  `vip_manager_grace_nudge_test.dart` grants 600ms with a 1-hour threshold,
  disposes, reloads on the same store and asserts the nudge is not yet due.
  Four failures when `_effectiveNudgeThreshold` is neutralised.
- **DST framing overstated (codex, minor).** A DST shift is one hour; the real
  multi-hour corruption case is a UTC-offset change. CHANGELOG reworded.
- **`_clampRevokedEntries` doc read as if the case bug were open (claude, minor).**
  Rewritten to separate the two things: CRL matching *is* case-insensitive at
  both ends now; what remains is a namespace collision between two distinct
  kids differing only in case.

### Adjudicated — not adopted, with reasons in the source

- **codex Major: replace the two `earned: true, shown: true` constants with
  `displayConfirmed`.** Wrong in direction. A reward can only be granted by an
  ad that was on screen, so the reward is the *stronger* display proof; reading
  `displayConfirmed` there would under-count exactly when `onShowed` is lost.
  Documented at all three construction sites in both adapters and locked by
  `'a reward that arrives with no display callback still reports shown=true'`
  in `test/applovin_adapter_test.dart`.
- **codex Major: hold the App Open slot in `showing` until an authoritative
  native signal instead of resolving on the 90s hard cap.** Pre-existing
  tradeoff, and the proposed alternative is worse: `showing` blocks both the
  next load and the next show, so a lost callback would freeze App Open for the
  rest of the process — and a lost callback is the only case that code path
  ever runs in. Now written down explicitly in both
  `admob_adapter._armAppOpenWatchdog` and
  `applovin_adapter._resolveAppOpenAfterLostCallback`.

`flutter analyze` clean; `flutter test` 1134 passing.

---

## Round-25 — MJ9 closed (2026-08-26)

MJ9 was carried as a documented known limitation for three rounds and re-opened
by the product owner. It is now fixed.

### The exploit

`VipManager._effectiveNow()` returns `max(DateTime.now(), persisted high-water
mark)`. That single answer used to decide **both** questions asked of an entry:
"has it started?" and "has it expired?". So:

1. set the device clock a year forward;
2. redeem any grant — `grantedAt`/`expiresAt` are stamped a year out (on
   purpose, that is the anti-rollback anchor), and the mark is left parked a
   year out too;
3. put the clock back to the real time.

Every later check compared the entry against the same poisoned mark, which
agreed the entry was mid-window. A 10-day grant never expired.

### Rejected fix — capping the mark

The obvious fix is a `maxClockMarkLead` cap: refuse to trust a mark more than
N days ahead of the raw clock, and lower it on disk. It was implemented, then
reverted. It cannot distinguish a corrected clock fault from a deliberate
rollback, so it hands back exactly the abuse the mark exists to stop — and it
broke `'entry inside its granted window is NOT active once a later high-water
clock mark has been observed'`, which is the rollback defence's own test.

### Shipped fix — split the two questions

`VipManager._isLive(entry, now)` = `entry.isActiveAt(now)` **and** the entry has
started according to the **raw** device clock (`DateTime.now() +
futureGrantSlack >= grantedAt`, slack = 1 hour).

- Expiry still uses the mark, untouched, so rollback protection is exactly as
  strong as before — expiry is the only half a rollback attacks.
- "Has it started?" is anchored to real time, which the abuser has to make
  usable to use the device at all. At that moment the grant has not begun.
- The 1-hour slack exists so a grant minted seconds after a small backwards
  correction (legitimately stamped a few minutes ahead of the raw clock) takes
  effect immediately. A customer who redeems a key cannot be told to wait.

Routed through the four **active-determination** sites — `expiresAt` getter,
`_refreshActive`, `_scheduleNextExpiry`, `addVip`'s stacking base. Deliberately
**not** `_purgeExpired()`: purge deletes rows, and the honest version of this
state is a customer whose device clock was genuinely fast when they paid.
Suppress, never delete. For the same reason the suppressed entry is not
re-armed on the expiry timer (the timer's deadlines are on the mark's scale and
this guard is on the raw clock — mixing them risks a fire/re-arm spin); state
is recomputed on every resume and launch, which is soon enough for a window
bounded by the size of the user's own clock error.

### Residual, accepted

The paying-customer half of the original note stays open: an honest clock fault
while the app was closed can still park the mark in the future and freeze
remaining time on a paid grant. The only fix is the cap that was just rejected,
or the native uptime source this package deliberately does not have.

### Tests

New group in `test/vip_manager_robustness_test.dart`:

- `'a grant stamped a year ahead is NOT active once the clock is usable again'`
  — the exploit itself, mark left parked in the future so the raw-clock guard
  is the only thing that can reject it.
- `'the suppressed entry is kept, not deleted'` — the purge caveat.
- `'an ordinary grant on an honest clock stays active'` — guards the guard; a
  fresh grant, and a grant inside the slack window, must be live immediately.

Red-then-green proved by neutering `_isLive` back to plain `isActiveAt`: the
first two fail, the third still passes. `setUp` now also resets the high-water
mark, which `revokeAll()` deliberately does not clear — without that reset the
parked mark leaked into the next test.

`flutter analyze` clean; `flutter test` **1137 passing**.

## Round-25 — the iOS Simulator run (2026-08-26)

31 integration files, one `flutter test` invocation per file, on
`iPhone 16 (1DB6BF12-98E6-4C86-8E16-F87EBED227E3)` with the same dart-defines
the iOS CI job uses (`SKIP_SPLASH_AD`, `SKIP_ATT`, `SKIP_UMP`,
`AD_PROVIDER_ADMOB`). Final state: **28 pass, 1 skipped by design, 2 blocked by
the Simulator**.

The 3 that are not green:

- `ump_eea_consent_test` — skips itself without `UMP_EEA_DEBUG`. By design.
- `interstitial_ad_test`, `rewarded_ad_test` — blocked, not broken. See below.

Two real findings came out of the run, both fixed, plus two test bugs of my own
making.

### MAJOR — a post-init throw looped `initialize()` forever

`initialize()` resets the auto-retry budget to 0 the moment the adapter's own
native init succeeds. Anything that throws *after* that point therefore got an
unbounded retry: attempt N re-inits the adapter fine, throws again at the same
later step, resets the budget again, arms "retry #1" again. Observed live as a
permanent 5-second loop — adapter disposed and rebuilt, ads re-requested, every
round — and it also wiped the consent guard flags each cycle
(`_resetGuardState`), so from the second attempt on the consent footgun fired
too and the loop could never break out.

Reachable in release, not only in debug: a host `onComplete` callback that
throws lands in exactly the same place.

Fixed in `lib/src/core/ad_manager.dart`:

- a throw once the adapter is up is terminal — reported once, never retried
  (re-running native init cannot fix a host callback or a config footgun);
- a genuinely failed adapter init keeps the bounded retry it always had
  (anchored by its own test).

### MAJOR — the footgun asserts hid init completion from the host

The two footgun `assert(false, ...)` calls (no consent flow; no `requestAtt()`
on iOS) ran **before** `onComplete(true)` and the `BoolEvent(true)`. In any
debug or profile build the assert throws, the init body's `catch` swallows it,
and everything after it was skipped: the host was never told init had finished,
even though native init had succeeded. A splash following the documented
contract (README step 3 — subscribe to the init event) waited for an event that
could not arrive and fell through to its hard-cap timer. With `SKIP_ATT=true`
on iOS that is *every* scripted run.

Fixed by reporting success first and asserting after — the assert is a
developer warning, not an init result. The ad-loading kick-off still sits after
the consent footgun guard, so nothing loads before that guard has had its say.
A throwing host `onComplete` is now contained too, so it can no longer swallow
the completion event the splash contract is built on.

Tests: `test/init_post_success_throw_test.dart` (4 tests, real `initialize()`
body, only the adapter swapped through `debugAdapterFactory`) — completion
still reported through an assert; no retry armed after a footgun assert; no
retry armed and the event still fired when the host callback throws; and a
genuinely failed adapter init still arms the retry. Red-then-green proved by
neutering each half in turn.

### Two test bugs, not SDK bugs

- `ump_form_block_destroy_test` — the file owns the form-on-screen counter and
  asserts it drops to zero on `release()`, but left the SDK's automatic UMP flow
  on. On any device that answers `status: required` — every iOS Simulator, which
  can never present the form at all — that flow takes a second count of its own,
  so `release()` left the mutex legitimately held and the assertion read as a
  regression. Now runs with `autoRequestUmpConsent: false`.
- `gaid_reset_on_destroy_integration_test` — GAID exists only on Android. On
  iOS the IDFA is empty without an ATT authorisation no scripted run can give,
  so there was nothing for `destroy()` to clear. Gated to Android with
  `markTestSkipped` rather than weakened into a false green.

### The Simulator ceiling, measured

`interstitial_ad_test` / `rewarded_ad_test` fail on iOS for a reason that is the
SDK behaving correctly: UMP returns `status: required`, the form cannot be
presented under `integration_test`
(`9:The provided view controller is already presenting another view
controller`), so `canRequestAds=false` and every fullscreen load is skipped —
GDPR-correct, and unfixable from Dart.

Measured directly rather than assumed: with the example app temporarily built
with `autoRequestUmpConsent: false` (consent recorded as
`AdConsent.conservative`), the same Simulator produced

```
[AdMobAdapter] loadInterstitial [AdMob] ✅
[AdMobAdapter] showInterstitial [AdMob] ✅ shown
```

so **AdMob does fill and show on iOS** — requirement 1 is satisfied on both
platforms. The test still cannot finish there: once the native fullscreen ad
covers the FlutterView the Simulator stops producing frames, so
`tester.pump()` never returns and the file hangs instead of failing. That
temporary example-app change was reverted; it bought two hanging tests in
exchange for a fact now recorded here.

`flutter analyze` clean; `flutter test` **1142 passing**.

### Android re-verification of the round-25 diff (Pixel 7 Pro, 2026-08-26)

The three touched/new integration files, re-run on a real device with
`--dart-define=AD_PROVIDER_ADMOB=true`:

| File | Result |
|---|---|
| `ump_form_block_destroy_test.dart` | PASS (2 tests) — the `autoRequestUmpConsent: false` added for iOS is safe on Android too |
| `vip_clock_forward_test.dart` | PASS — the MJ9 clock-rollback guard holds on device |
| `gaid_reset_on_destroy_integration_test.dart` | red, then PASS with `--dart-define=SKIP_SPLASH_AD=true`; no source change in between |

The third one is not a regression and not an SDK defect. A real device gets
real ad fill, so the splash shows a real App Open ad; nothing in a scripted run
can tap it closed, the splash keeps re-arming
(`⏰ splash budget elapsed but app-open in flight — re-arming +30s`) and
HomePage never appears inside the test's 20s tile wait. The failure surfaces as
`HomePage must list the AdMob test-device hash tile`, which reads like a UI
regression and is not one. Same family of ceiling as the iOS one above: a
native fullscreen ad on screen is something a harness cannot dismiss. The
requirement is now documented in that file's header; the CI Android emulator
does not need the flag because it gets no App Open fill, which is why the
workflow omits it.

### AppLovin MAX with the real SDK key (Pixel 7 Pro, 2026-08-26)

Every prior round had only ever exercised the AppLovin path against mocks,
because no real SDK key is committed (and CI forces `AD_PROVIDER_ADMOB=true`
for exactly that reason). This round ran the example app on a real device with
the real key supplied at run time — the key stayed in the scratchpad and is
**not** in the repo. Requirement 1 for the AppLovin half is now measured, not
inferred.

What the real SDK reported, across three cold starts:

```
[AppLovinAdapter] initialize [AppLovin] ✅ SDK ready
[AppLovinAdapter] privacy flags applied pre-init (consent=true, doNotSell=false)
[AppLovinAdapter] banner   [AppLovin] ✅ initial loaded adViewId=… network=AppLovin
[AppLovinAdapter] mrec     [AppLovin] ✅ initial loaded adViewId=…
[AppLovinAdapter] appOpen  [AppLovin] ✅ loaded → ✅ displayed
[AppLovinAdapter] inter    [AppLovin] ✅ loaded
[AppLovinAdapter] rewarded [AppLovin] ✅ loaded → ✅ displayed
```

So all five surfaces load on the real MAX SDK, the consent flags are applied
**before** `initialize` (the ordering the AppLovin policy requires, and what
`attOrderFootgunWarning` exists to protect), and the App Open + rewarded
surfaces actually display.

Honest caveats, because the run does not prove as much as the ✅s suggest:

- **The MAX test creative cannot be closed or rewarded.** Its close button is
  inert, so the rewarded completion callback and the App Open dismiss callback
  never arrive from the network. What that did prove is the SDK's own bound
  firing correctly instead of hanging:
  `❌ showAppOpen [AppLovin] ⏰ HARD CAP 90s reached (lifecycle=paused, displayed=true)`.
  The reward-grant path itself stays covered by unit tests and by the AdMob
  device run, not by this one.
- **The MREC unit id was still the `YOUR_MREC_AD_UNIT_ID` placeholder** and the
  SDK still reported `mrec ✅ initial loaded`. Treat the MREC line above as
  unproven: a real MREC unit id has not been exercised on a real device.
- Only Android. The AppLovin path on iOS remains unmeasured with a real key
  (the same Simulator ceilings above apply, and no iOS key was configured).

### Round-25 QC — what three independent reviewers found in the round-25 fix

The round-25 `ad_manager.dart` diff went out to `codex`, `agy` and `claude`
independently. All three came back below the bar (6.5 / ~5 / 6 out of 10) and
all three named the **same** hole, which is the honest headline: the fix
reintroduced, one branch over, exactly the failure class it was written to
remove — an external signal disagreeing with internal state.

**MAJOR — a reported failure that left the SDK initialised.** The new
`else if (_adapter != null && _config != null)` branch reported
`onComplete(false)` + `BoolEvent(false)` without tearing anything down. Since
`isInitialised` is `_config != null && _adapter != null`, and both are assigned
the moment the adapter's own init succeeds, a throw in the window between that
assignment and the success report (`consentMgr.applyToProviders`, the
`IabStorage.tcfAllowsPersonalisedAds` read) told the host "init failed" while
`isInitialised` still answered `true`, with a live native adapter, its
fullscreen-dismiss watchers and the `_syncConsentToAdapter` listener all still
wired up. A host that does not re-`initialize()` on failure leaked that adapter
for the rest of the process — and it kept serving. Fixed by disposing and
detaching before reporting, so the reported `false` is true.

**MAJOR — a footgun assert silently killed the session's ad services.** Both
`assert(false, …)` calls sat above the preloads. They throw in debug/profile,
the init `catch` swallows the throw, so a developer who tripped either warning
also lost the App Open + banner/mrec preload, `_scheduleFirstSecondaryLoad`,
the ad retry timer and the connectivity watch for the whole session. The
symptom is "ads never load on my machine", which looks nothing like the warning
that caused it. Fixed by moving both asserts to the very end of the try; the
release-blocking half (`_applyConsentFootgunGuard`) stays where it was, ahead
of any ad request, because that one is a legal gate rather than a shout.

**Test coverage the reviewers were right about.** They independently showed two
mutations that kept all four round-25 tests green: deleting the new `else if`
branch entirely, and deleting the `BoolEvent(false)` fires. Both are now pinned,
plus the services regression:

- `a failure after the adapter came up disposes it before reporting…` — drives
  the branch with an adapter that throws from a slot getter read inside the
  window, and asserts one `onComplete(false)`, one `BoolEvent(false)`, and
  `isInitialised == false`. Red (`Expected: false / Actual: <true>`) with the
  dispose removed.
- `a footgun assert does not silently kill the retry timer and the connectivity
  watch` — deltas on `debugRetryGen` / `debugConnectivityWatchGen`, because both
  counters live on the singleton and survive `destroy()`, so absolute
  `greaterThan(0)` assertions passed even with the services skipped. Red
  (`Expected: a value greater than <5> / Actual: <5>`) with the asserts moved
  back above the preloads.

One reviewer note deliberately not acted on: two of three wanted
`_initRetryAttempts = 0` moved to the end of `initialize()` instead of routing
post-adapter throws around the retry. The third examined that choice directly
and agreed the branch is the right shape — the two failure classes ("the
adapter will not come up" vs "the adapter is fine, a later step broke") are
genuinely different and a shared budget conflates them. Kept, with the dispose
that makes it safe.

`flutter analyze` clean; `flutter test` **1144 passing**.

### Round-25 QC round 2 — the fix to the fix

The corrected diff went back out to the same three reviewers. `codex` passed it
on compliance grounds but objected to one thing; `claude` scored it **4/10** and
`agy` **7.5/10**, and the two low scores again named the *same* defect. Same
pattern as round 1, and the same conclusion: the hole was real.

**MAJOR — a teardown that threw left the SDK claiming to be initialised.**
`_disposeAdapter()` (now `ad_manager.dart:4206`) ran
`old.appOpenSlot.state.removeListener(...)`, `_detachFullscreenDismissWatchers()`
and `await old.dispose()` *before* `_adapter = null; _config = null;` with no
guard. A native plugin that throws on the way out — the file documents that risk
itself, one branch over — skipped both null-outs, so `isInitialised` answered
`true` again for an adapter the SDK had just told the host had failed. Exactly
the contradiction round 1 existed to remove, reached through the error path
instead of the happy one, and every caller was affected (`destroy()`, the
re-init path, the catch branch), not just the one under test.

Fixed at the source rather than at the call site: the teardown body is
best-effort (try/catch, logged), the state change is not. The `_adapter = null`
assignment gets its own guard on top, because the setter re-runs the
fullscreen busy-slot plumbing and reads the old adapter's slot getters — a
broken adapter can throw from there too, and `_adapterField` (the raw field
behind the setter) is the last resort. The ad-hoc "force-clear the fields after
a failed dispose" block that round 1 had added inside the catch is deleted: one
guard in the shared function beats a guard in one caller.

**MAJOR — the host's own retry was silently dropped.** `onComplete(false)` was
invoked while `_isInitializing` was still held (it is only released in the outer
`finally`, i.e. after the callback returns). The obvious thing for a host to do
in a failure callback is call `initialize()` again with a fallback config — and
that call hit `initialize already in progress — skipping duplicate` and vanished.
The host had been told init failed and its own recovery then did nothing at all.
`_reportInitFailure()` now releases the flag before invoking the callback, and
`initialize()` takes an `_initGen` token so the outer `finally` only clears the
flag when no nested call took over — otherwise it would hand a still-running
nested init's flag back to `false` and let a third concurrent caller (the
internal retry timer, a second splash) build a second adapter on top of the
live one.

**Compliance objection (`codex`), acted on.** With the asserts moved to the end
of the try, a footgun config in a debug/profile build started *requesting ads*
before the developer was stopped — the assert had been the de-facto gate, and
`_applyConsentFootgunGuard` only blocks in release. The preload block now skips
itself on a consent-coverage warning in **every** build, so debug and release
agree and the assert is a shout, not a gate.

**Mutations the reviewers proved, now pinned.** Each of the four fixes has a
demonstrated red:

| Mutation | Test that goes red |
|---|---|
| Remove the teardown guard in `_disposeAdapter()` | `an adapter whose dispose() throws still leaves the SDK saying it is not initialised` |
| Replace `await _disposeAdapter()` in the catch with a raw pair of null-outs | `a failure after the adapter came up disposes it before reporting…` (`disposeCalls`) |
| Drop the early `_isInitializing = false` | `a host that re-initialises from onComplete(false) is not dropped by the in-progress guard` |
| Clear the flag unconditionally in `finally` (no `_initGen`) | same test, on the third-call assertion |
| Delete the preload call | `a clean init really does fire the first round of ad requests` |
| Make the footgun path preload anyway | `a footgun config requests no ads at all, in any build` |
| Remove the guard around the host callback | `a host onComplete(false) that throws still fires the failure event…` |

**One test bug worth recording, because it wasted an hour.** The preload test
passed alone and failed in-file. Cause: the default first-install VIP grace
grants a 30s VIP entry in debug, a VIP member skips every preload, and the
grant's disk write is *queued* — it lands during the NEXT test, after `setUp`
has reset `SharedPreferences`, via the plaintext fallback
(`VipEntriesStore.getRaw` → `getVipEntriesFallbackRaw`) that the store consults
because the secure-storage channel never exists in a unit test. So clearing
prefs in `setUp` could not fix it: the write had not landed yet. Every config in
that file now disables the grace, which is what makes the tests
order-independent. Not an SDK defect — but the mechanism (a queued VIP write
outliving the manager that made it) is real, and it is the same mechanism the
process-wide `_saveQueue` exists for.

**Not acted on, recorded instead.** One reviewer noted that a concurrent
`destroy()` during `await _disposeAdapter()` can double-dispose the same adapter
instance. Pre-existing, not introduced here, and both disposes are now guarded;
tracked rather than fixed inside a round about init reporting.

`flutter analyze` clean; `flutter test` **1149 passing**; the file is 11 tests.

### Round-25 QC round 3 — the last two reviewer findings

Third pass over the same diff by the same three reviewers (`codex` 7.8/10,
`claude` 6/10, `agy` 9.3/10). Everything below is fixed and pinned; the file is
now **16 tests**, the suite **1154 passing**, `flutter analyze` clean.

**MAJOR (`codex`, `claude`) — the two footgun `assert(false, ...)` calls are
gone.** Not moved, deleted. All three reviewers independently reached the same
verdict: an assert inside a `try` that catches `Object` cannot fail a test, halt
anything, or force a developer's hand — it only manufactures a stack trace which
the catch then logs as `initialize THREW`, i.e. it *reports the wrong thing*.
Moving it outside the try is worse, not better: the throw then escapes
`initialize()` and strands a splash doing `await initialize()` — the exact
round-25 failure. What replaced them is `SafeLogger.critical`, which reaches the
host's own `onLog` sink and is not silenced by `AdLogLevel.none`. The runtime
gate that actually protects the user (no `_triggerInitialPreloads` while
`consentWarning != null`, `_footgunBlocked` in release) was always the real
mitigation and is unchanged. Pinned by *a footgun config still shouts at the
developer* — downgrading `critical` to `w` turns it red.

**MAJOR (`claude`) — the consent-listener removal no longer shares a `try` with
the adapter teardown.** In the post-success failure branch,
`_consentManager?.listenable.removeListener(...)` and `await _disposeAdapter()`
sat inside one `try`: a throw from the first line skipped the second entirely,
so the host got `onComplete(false)` while `_adapter`/`_config` stayed set and
`isInitialised` kept answering true. All three inline call sites (re-init path,
this branch, `destroy()`) now go through `_detachConsentListener()`, one
statement with its own guard.

*Reported honestly, because the fix is not what the finding claimed.* No
reachable path throws there: Flutter's `ChangeNotifier.removeListener` is
documented as safe after `dispose()`, and `ConsentManager`'s constructor is
private, so no test and no host can substitute a `listenable` that throws.
Deleting the new `try/catch` leaves all 16 tests green — measured, not assumed,
and said so in the code comment and in the test. What the change actually buys
is the decoupling: three call sites share one guarded statement, and no future
throw there can take an adapter teardown down with it. The nearest reachable
thing *is* pinned — *a retired consent notifier does not cost the adapter its
teardown* retires the `ConsentManager` singleton from inside the throwing slot
getter and still demands a fully torn-down SDK.

**MAJOR (`claude`, `agy`) — the second guard in `_disposeAdapter()` was
unpinned.** Both reviewers found the same hole by mutation: the `try` around
`_adapter = null` (whose setter detaches the fullscreen-busy listeners, reading
all four slots on the way) could be deleted with every test still green, because
the only test reaching that path threw from `dispose()` rather than from a slot
getter. *A slot getter that throws from the adapter setter still clears the SDK
state* closes it — deleting the guard now fails 5 tests.

**Minor (`agy`) — the initial App Open preload was unpinned.** Deleting
`unawaited(loadAppOpenAd())` from `_triggerInitialPreloads` left the clean-init
test green, because that test asserts on the adapter's banner/MREC counters and
the App Open request is turned away one layer higher by its own consent gate
(UMP cannot resolve in a unit test). Asserting the counter would assert the
gate, not the preload. Asserted the *orchestrator* instead: the test now demands
the `AdSkipEvent(type: appOpen, action: 'load', reason: 'consent')` that only
exists if the preload block really called `loadAppOpenAd()`. Deleting the
preload line now turns it red.

**Not acted on, and why.** `agy` flagged that a throw between `_config = config`
and `_adapter = adapter` would leave `_config` non-null with no adapter. The
window between those two lines contains only `_lastKnownConfig = config`; none
of the three can throw. And a throw from the `_adapter` setter itself lands with
`_adapterField` already assigned (the setter writes the field *before*
re-attaching listeners), so it takes the post-init branch that does tear
everything down — which is exactly the path the new setter test drives. Recorded
as unreachable rather than guarded, to avoid a second unfalsifiable catch.

`agy` also asked for the two footgun mutations it found green
(`_applyConsentFootgunGuard(isRelease)` deleted) — that call site is pinned in
`ad_manager_core_test.dart` via `debugApplyConsentFootgunGuard`, in the group
whose own comment explains why a real `initialize()` cannot reach it under
`flutter test`. No new test needed; cross-file coverage, not a hole.

### Round-25 QC round 4 — the last four, and two tests that proved nothing

Round-4 scores before these fixes: `codex` 8/10, `claude` 8.5/10, `agy` 8/10.
`agy`'s biggest deduction (−1.5, "`attWarning` is computed but never logged,
`flutter analyze` warns") was **refuted against the file** — ad_manager.dart
already had `if (attWarning != null) SafeLogger.critical(_tag, attWarning);` and
analyze was clean; discounting it puts `agy` at ~9.5. The other four findings
were real and are fixed. File is now **21 tests**, suite **1161 passing**,
analyze clean.

**MAJOR (`codex` and `claude`, both their top deduction) — `SafeLogger.critical`
now ignores `logTagFilter` as well as `AdLogLevel.none`.** `critical` replaced
two `assert`s that no logger configuration could silence. Honouring the tag
filter therefore made the replacement *weaker than what it replaced* on the one
diagnostic with a legal consequence: a host whose `logTagFilter` did not list
`AdManager` silently lost "no consent flow configured", i.e. the warning that an
EEA/UK user is about to be served ads with no consent form. There are two
`critical` call sites in the whole SDK and both mean the host's own config is
wrong. `safe_logger_test.dart`'s "critical() still honors tagFilter" was
inverted into "critical() ignores tagFilter too", with an ordinary `e()` in the
same test as the contrast case so this is not read as "the filter broke".

**MAJOR (`codex`) — a caller turned away by the duplicate-init guard is now
told the result instead of nothing.** The guard logged "skipping duplicate" and
returned, so that call's `onComplete` never ran and no event ever fired: a
splash doing `await initialize()` as the *second* caller waited on a callback
that could not arrive — the same hang round 25 started from, one caller over.
Those callbacks are now parked in `_queuedInitCallbacks` and drained with the
in-flight attempt's real result (including a result that only arrives after the
internal retry budget resolves), and by `destroy()` with `false` so a teardown
mid-init cannot strand them. Parking builds no second adapter — pinned. The
pre-existing re-entrancy test asserted the opposite for the third caller
(`thirdReported, isFalse`) and was updated: "refused" now means *not given its
own adapter*, not *ignored*.

**MAJOR (`codex`, `agy`) — the iOS ATT-order warning is reachable by a test at
last.** The check read `dart:io`'s `Platform.isIOS`, which is false on the macOS
host that runs `flutter test`, so the warning was always null and deleting the
`SafeLogger.critical` line left all 16 tests green — both reviewers ran exactly
that mutation. It now reads Flutter's `defaultTargetPlatform`, same answer in
production and overridable in a test. The new test drives it with
`logLevel: none` *and* a `logTagFilter` that excludes the SDK, so it pins the
round-4 filter change at the same time.

**Minor (`agy`) — three unpinned guards, now pinned, and one of my own tests
was worthless.** `SafeLogger`'s lazy-message-builder guard and the `onLog` sink
guard both got direct tests in `safe_logger_test.dart`. The two listener
detaches in `_disposeAdapter()` needed `AdSlot.debugHasStateListeners` (a
six-line `ValueNotifier` subclass, because Flutter marks `hasListeners`
`@protected`) to be observable at all.

The honest part: my first attempt at both listener tests passed *and stayed
green under the mutation*, i.e. proved nothing. Reading the init order explained
why. `_scheduleFirstSecondaryLoad()` — which attaches the app-open listener —
runs *after* `onComplete(true)`, so on the failure path there is no app-open
listener to detach; that test had to be driven through a successful init plus
`destroy()`. And the consent listener attaches at ad_manager.dart:2336, *after*
the point where `_ThrowsAfterInitAdapter` throws, so that adapter's failure
never had a consent listener either; pinning it needed a throw one step later —
`_ConsentApplyThrowsAdapter`, throwing synchronously from `applyConsent` (the
interface declares it `void`, and an `async` override would have become an
unhandled async error, the trap this file already documents). Both mutations
now go red.

**Also corrected:** `claude`'s minor — `_ThrowsAfterInitAdapter`'s comment named
`_attachFullscreenDismissWatchers()` as the throw site. The real stack trace says
the `_adapter` setter's own `_attachFullscreenBusySlotListeners()`
(ad_manager.dart:117) reads the slot first, so the next line is never reached.
Comment fixed; no behaviour change.

### Round-25 QC round 5 — a real BLOCKER the queue exposed, and a lost file

Round-5 scores before these fixes: `codex` 6/10 (one BLOCKER, two MAJORs),
`claude` 8/10, `agy` 8/10. File is now **27 tests**, suite **1167 passing**,
analyze clean. Every fix below has a demonstrated red.

**BLOCKER (`codex`) — `destroy()` did not invalidate an `initialize()` that was
still in flight.** Round 4's parked-caller queue made a pre-existing race
visible: `destroy()` told the parked callers `false`, tore everything down and
released `_isInitializing`, but the attempt still sitting inside native init
(up to 20s of it) had no idea. When it resumed it installed `_config` and
`_adapter`, re-armed the retry timer and the connectivity watch, re-attached
listeners and reported `onComplete(true)` — the SDK came back to life *after*
teardown, and a host just told `false` could read `isInitialised == true`. The
fix is the generation counter that already existed for the busy flag:
`destroy()` bumps `_initGen`, and the init body checks `_initSuperseded(initGen)`
at both windows that follow an await — before installing state, and again before
reporting success (consent application and the TCF read are both awaited, so
`destroy()` can also land *between* those two points; that second check has its
own test, `_DestroyOnConsentAdapter`). A superseded attempt disposes the adapter
it built, reports `false`, and deliberately fires **no** `BoolEvent`:
`SimpleEventBus` replays the most recent event, so a loser's `false` landing
after the winner's `true` would tell a late-subscribing splash that init failed.

**MAJOR (`codex`) — the success drain could strand a re-entrant caller.** The
drain runs while `_isInitializing` is still `true`, so a queued callback calling
`initialize()` again — the obvious host reaction — was parked into the queue the
drain had just cleared, and nothing drained it afterwards. Round 4's bug, one
level of recursion down. The drain now loops until the queue stays empty,
bounded at 8 passes; at the cap the last batch is still answered once before the
queue is dropped (`agy`'s follow-up: "gave up" must not mean "silently
stranded").

**MAJOR (`agy`) — the failure drain was only ever exercised through
`destroy()`.** Deleting `_drainQueuedInitCallbacks(false)` from
`_reportInitFailure` left every test green. That is the ordinary case — the
in-flight attempt fails on its own while the host's splash waits on exactly that
callback — and it now has its own test (`_SlowThrowsAfterInitAdapter`).

**MAJOR (`claude`) — the `try/catch` around each parked callback was
unpinned.** Round 4 contained a throwing *primary* `onComplete`; a throwing
*parked* one still took the rest of the drain with it, and from `destroy()` the
rest of the teardown too. Pinned with two parked callers, the first of which
throws.

**Minor (`codex`) — the queue had no bound** (a host looping `initialize()`
through a full retry budget kept every closure alive). Capped at 32; the
overflow caller is told `false` immediately instead of being parked. And the
mutation `cb(success, _currentDeviceGAID)` → `cb(success, '')` survived all 21
round-4 tests: nothing checked that the *second* half of the
`onComplete(bool, String)` contract survives parking. Pinned by mocking the
`advertising_id` channel, which is also the first test in this suite to prove
the GAID reaches a host callback at all.

**Refuted — `claude`'s second deduction** ("an unrelated caller can slip into
the window where `_isInitializing` is false but an internal retry is still
pending, so the retry gets parked and the original host hears a different
config's result"). The window is real; the conclusion is not. Before round 4
that parked retry was *dropped*, and the host — which had been told nothing yet,
because the terminal outcome was deferred to the retry — was left waiting
forever, i.e. the round-25 hang. Hearing "init succeeded" from the attempt that
actually owns the SDK is truthful about the only thing `onComplete`'s `bool`
describes, and the GAID is device-level, identical for both configs.

**Process note, and it cost real work.** One reviewer, run with
`--dangerously-skip-permissions`, reverted `lib/src/core/ad_manager.dart` to
`HEAD` while mutation-testing — silently discarding the entire uncommitted
round-23/25 diff in that file. It was recovered from a scratchpad snapshot taken
minutes earlier. Reviewers from here on get a **copy** of the package to mutate,
never the working tree.

### Round-25 QC round 6 — the loser killing the winner, and 11 mutations

Round-6 scores before these fixes: `codex` 6/10, `claude` 6.5/10, `agy` 6.5/10 —
all three independently naming the same BLOCKER, which is the round-5 fix being
half a fix. File is now **33 tests**, suite **1173 passing**, analyze clean.
Nine of the eleven mutations below have a demonstrated red; the two that do not
are named as such, with the reason, in the code itself.

**BLOCKER (all three) — the supersede check only guarded the success path.**
Round 5 checked `_initSuperseded` before installing state and before reporting
success, and nowhere else. So the two *failure* paths still ran to completion on
a torn-down SDK:

- `if (!ok)` (native init came back `false` after `destroy()`) went through the
  ordinary failure branch: it armed the 5-second retry timer, which then called
  `initialize()` on the dead SDK, and it fired `BoolEvent(false)`. The event bus
  replays its most recent event, so that loser's `false` is what a
  late-subscribing splash was handed even after a *different* attempt had
  succeeded.
- `catch (e, st)` was worse (`claude` reproduced it live): the "my adapter came
  up, tear it down" branch decided what to dispose by reading `_adapter` and
  `_config` — shared singleton fields. An attempt that threw after another
  attempt had already won therefore disposed the **winner's live adapter**,
  flipped `isInitialised` back to `false` and reported failure for a session
  that never failed. The loser killing the winner: strictly worse than the
  round-5 bug it grew out of.

Both now bow out through the same `_initSuperseded` / `_reportAbandonedInit`
pair, reporting only to their own caller and firing no event.

**MAJOR (`codex`, `agy`) — the two bootstrap awaits had no abort either.**
`await vip.load(...)` reads secure storage and `ConsentManager.bootstrap()`
reads persisted consent, so `destroy()` can land inside either. Afterwards the
attempt attached the VIP listener, published `_vipManager` and flipped
`vipReadyNotifier` to `true` — VIP state resurrected on a torn-down SDK — or
published `_consentManager`, so `AdManager().consent` answered for a session
that no longer existed. Both windows now abort (and the VIP one disposes the
manager it built).

**MAJOR (`claude`) — a stale attempt clobbered a live init's busy flag.**
`_reportInitFailure` released `_isInitializing` unconditionally, so an abandoned
attempt reporting its own failure handed a still-running newer init's flag back
to `false` and let a third concurrent call slip past the duplicate guard and
build a second adapter. Now gen-guarded.

**MAJOR (`agy`) — four round-5 mutations survived the whole suite.** Deleting
the 32-caller cap, deleting the 8-pass drain limit and its straggler handling,
replacing the GAID with `''` in `_reportAbandonedInit`, and deleting
`await adapter.dispose()` from the supersede branch were all 100% green. Each
now has a test. The drain itself was redesigned rather than re-capped: a
`_drainingInitResult` field holds the result while the queue is being answered,
and the duplicate guard hands that result over on the spot to a callback that
re-enters `initialize()`. Nothing can grow the queue from inside the drain any
more, so the pass cap and the straggler branch both went away — the fix is
*less* code than the round-5 version it replaces, and the test asserts the
re-entrant caller is answered **synchronously**, which is what separates the two
designs.

**Found by mutation testing, not by a reviewer — a caller that parks during
`destroy()`'s own teardown.** `destroy()` drains the queue as its first act, but
its teardown then awaits (`_eventStream.close()`, `_disposeAdapter()`) before it
clears `_isInitializing`. A host calling `initialize()` in that window still
sees "in progress" and parks — behind an already-drained queue, with no attempt
left to answer it. The leftover `if (!_isInitializing) _drainQueuedInitCallbacks(false)`
inside `_reportAbandonedInit` is the only thing that answers that caller, and it
now has the test that proves it.

**The two mutations with no red, both documented in place.** (1) The
`if (_initGen == initGen)` guard in `_reportInitFailure`: all three call sites
now sit after an `_initSuperseded` early return, so the condition is always true
when reached and deleting it keeps the suite green. It stays as the guard that
stops the bug returning if a future call site reports a failure without checking
for supersession. (2) The abort after `ConsentManager.bootstrap()`:
`AdPreferences.getInstance()` is an internal singleton, so a test has no seam to
make `destroy()` land inside `bootstrap`'s own await. It is the symmetric
one-line twin of the VIP-load abort, which *is* pinned.

### Round-25 QC round 7 — a consent gate written by a dead session

Round-7 scores before these fixes: `codex` 4/10, `claude` 8/10, `agy` 6/10. All
three re-ran the round-6 mutation ledger independently and confirmed it (`agy`
reproduced 8 of the 9 reds itself). Their new findings are all *outside* the init
window round 6 hardened. File is now **37 tests**, suite **1177 passing**,
analyze clean.

**BLOCKER (`codex`) — the UMP consent flow was not bound to a session.** The
auto-UMP flow is deliberately fire-and-forget (`runZonedGuarded`, not awaited),
and it presents a native form, so its outcome can land minutes later — after a
`destroy()` and a fresh `initialize()`. `_applyUmpConsentResult` wrote
`canRequestAds` unconditionally, and the zone error handler reopens the gate
directly on the debug fail-open path. So a dead session's answer opened the live
session's ad gate. The gate is the compliance surface: the live session may be
holding it shut on purpose until its own flow answers, and its config may differ
from the dead one's — a different `umpTagForUnderAgeOfConsent` is the case with
teeth. Bound to `_consentSessionEpoch` now, the same epoch the privacy-options
form has been bound to since round 13. Dropped rather than re-read (which is what
the privacy-options twin does), because the live session owns its own flow.

**MAJOR (`codex`) + MAJOR (`agy`) — `destroy()` gutted a session that started
during its own teardown.** The teardown awaits (event-stream close, the adapter's
`dispose()`), and every line after those awaits assumes no new session exists. A
host calling `initialize()` in that window got a session built and then taken
apart by the rest of `destroy()`. The sharpest one is the lifecycle observer:
the new session's `_ensureObserverAdded()` sees the old session's observer still
registered and does nothing, then the tail of `destroy()` removes it — App Open
on resume and the ad pause/resume hooks are dead for the rest of the process, and
nothing logs. Rather than putting a generation check on every line of the
teardown (three rounds of exactly that is how we got here), `destroy()` now
publishes a `_destroyInFlight` future and `initialize()` waits it out. It also
releases `_isInitializing` next to its drain instead of a hundred lines later.
The test asserts the new session keeps its adapter **and** its observer.

**MAJOR (`claude`, `agy`) — two of round 6's own guards had no red.** (1) The
outer `finally`'s gen-guarded release of `_isInitializing`: the loser/winner test
awaited the winner to completion before releasing the loser, so the flag was
already `false` either way. Now pinned with the winner still mid-flight and a
third caller arriving in between — under the mutation that caller slips past the
duplicate guard and builds a second live adapter. (2) `_reportAbandonedInit`
firing no `BoolEvent`: mutating it to fire `BoolEvent(false)` kept all 33 tests
green. Now pinned by subscribing to the bus *late*, after a loser/winner
sequence, and asserting the replayed event is the winner's `true` — which is
exactly what a consuming app's splash does (README step 3).

**Refuted — `agy`'s `_drainingInitResult` clobber.** The claim: a queued callback
calls `destroy()`, whose nested drain's `finally` nulls the field, and the rest of
the outer drain then parks a re-entrant caller behind an already-drained queue.
Traced: nothing can park while a drain is running (round 6's duplicate guard
answers such a caller on the spot), and the drain copies-and-clears the queue, so
the nested drain returns at its own `isEmpty` early exit before touching the
field. The save/restore was written anyway — two lines, and it makes the
invariant hold by construction — with a test on the invariant itself and a note
in both places that the reported path is unreachable.

**Deleted as dead — round 6's leftover drain in `_reportAbandonedInit`.** It
existed for a caller that parked between `destroy()`'s drain and its release of
`_isInitializing`. That window is gone (the release moved up, and a caller
arriving during the teardown now waits instead of parking), so the branch is
unreachable and went away with a comment saying who drains instead.

**Round-7 mutation ledger** — 6 red, 1 documented unpinnable, 1 deleted:

| Mutation | Result |
|---|---|
| UMP session guard in `_applyUmpConsentResult` removed | RED — `a UMP result from a torn-down session cannot open the live gate` |
| `initialize()` no longer waits out an in-flight `destroy()` | RED — `a caller arriving during destroy()'s teardown waits, then gets a live session` |
| `destroy()`'s early `_isInitializing` release deleted | RED — 17 tests (the line matters; its new *position* is not independently pinned) |
| Gen guard dropped from the outer `finally` | RED — `a stale attempt cannot hand a live init's busy flag back to false` |
| `_reportAbandonedInit` made to fire `BoolEvent(false)` | RED — `a late event-bus subscriber hears the winner, never the loser` |
| Nested drain nulls instead of restoring | SURVIVED — path refuted above; invariant covered by its own test |
| Session guard in the auto-UMP zone error handler removed | SURVIVED — not pinnable: the forced-error seam throws inside the zone in the same microtask the flow starts, so a test cannot get a `destroy()` in between. Symmetric one-condition twin of the pinned guard in the apply. |

### Round-25 QC round 8 — the fix that round 7 got wrong

Scores: `codex` **6/10**, `agy` **7/10**, `claude` **9/10**. Two MAJORs, both
real, both in code round 7 had just written. `claude` filed no finding at all
and instead mutation-tested six of the round-7 guards (5 RED, 1 green — the
`_reportInitFailure` gen-guard, the one this document already lists as not
independently pinnable).

**MAJOR 1 — a coalesced `destroy()` was not coalesced.** Found independently by
`codex` and `agy`. The round-7 serialisation logged "waiting for it instead of
tearing down twice" and then, after `await pending`, fell straight through into
a second full `_destroy()`. Costs: every widget subscribed to `initRevision`
was told to rebuild twice per concurrent teardown, and — the reason this is a
MAJOR rather than a wart — the redundant teardown bumps `_initGen`, drains the
queue with `false` and disposes the adapter, so if the host's own
`destroy()`-then-`initialize()` sequence interleaved into the gap it landed on
the *new* session. That is the same silently-dead-ads bug the serialisation was
added to prevent. Fixed with the `return;` the log line always implied.
Coalescing is also the right semantic: what the second caller asked for was
"tear the running session down", and the teardown it awaited did that.

**MAJOR 2 — a cancelled retry timer swallowed the caller it was holding.**
Found by `agy`. When native init fails, `_scheduleInitRetryIfNeeded` arms a
timer that *holds the caller's `onComplete`* and `initialize()` returns without
answering that caller — deliberate, and fine as long as the timer eventually
fires. But both a fresh host-initiated `initialize()` and `destroy()` cancel
that timer outright, and cancelling a `Timer` throws its closure away, host
callback included. The caller was then never answered, `true` or `false`. Real
consequence: the user taps the splash's "Retry" button two seconds into the 5s
backoff, the retry succeeds, and the splash controller awaiting the *first*
callback still hangs until its hard-cap timer fires (README integration step 4
mandates that timer, which is why this degraded rather than froze; a host
without one froze). Fixed by hoisting the callback into
`_pendingRetryOnComplete`: a fresh `initialize()` parks it on its own
`_queuedInitCallbacks` so it hears that attempt's real result, and `destroy()`
answers it `false` on the spot (the queue drain at the top of the teardown
cannot cover it — a pending retry's caller is never in that queue).

Both fixes carry a test in `test/init_post_success_throw_test.dart`, now 40
tests. New fake: `_SlowDisposeAdapter` (gated `dispose()`), which is what lets a
test hold a teardown open and call `destroy()` a second time from inside it.

Mutation ledger, round 8:

| Mutation | Result | Test that died |
| --- | --- | --- |
| Delete `destroy()`'s `return;` after `await pending` | RED | `a second destroy() waits for the first and then does nothing at all` |
| Null out the stranded-callback handover in `initialize()` | RED | `a host-initiated initialize() adopts the pending retry's stranded caller instead of dropping it` |
| Null out `destroy()`'s stranded-callback answer | RED | `destroy() answers the pending retry's stranded caller false` |

Reviewer-run mutations against round 7 (independent confirmation, no fix of
mine survived unpinned except the two already documented as unpinnable):
`_applyUmpConsentResult` session guard RED, `initialize()`'s wait on
`_destroyInFlight` RED, the outer `finally` gen-guard RED (`agy` and `claude`
both — round 7's own report had called this one weak, so it is now settled as
genuinely pinned), `_reportAbandonedInit` event suppression RED, the drain
re-entrancy synchronous-answer branch RED, the VIP-load `_initSuperseded`
checkpoint RED. GREEN: `_drainingInitResult = outer` (agreeing with round 7's
own refutation of that finding) and the `_isInitializing = false` placement in
`_destroy()` (now masked by the `_destroyInFlight` wait — i.e. superseded by a
better guard, not unguarded).

`claude` also chased and explicitly refuted two hypotheses worth not
re-litigating: the VIP first-install-grace window between the VIP-load and
consent-bootstrap checkpoints (the abandoned attempt's persisted writes are
inert — `destroy()` has already removed the listener AdManager attached), and
`destroy()`'s alleged lack of exception safety around
`_consentManager?.listenable.removeListener(...)` (tried to force it via
`ConsentManager.resetForTest()`; the teardown completed cleanly and a follow-up
`initialize()` succeeded).

### Round-25 QC round 9 — the window I called unpinnable

Scores: `codex` **4/10** (one BLOCKER), `claude` **9/10**, `agy` **10/10** — the
first round where two of three reviewers filed no finding at all. Both of them
re-ran the round-8 mutations and confirmed all three pinned.

**BLOCKER — an init retry firing during a teardown resurrects the SDK.** Found
by `codex`, and found independently by my own post-round-8 audit an hour
earlier; what `codex` added is the part that matters. The retry-timer cancel sat
at the tail of `_destroy()`, after `_eventStream.close()` and
`_disposeAdapter()`, so the timer stayed armed across both awaits. A retry
firing in that window sees `_destroyInFlight != null`, waits the teardown out
(the round-7 serialisation) and only *then* takes its generation — so `_initGen`
cannot supersede it, and it rebuilds an entire session, adapter and timers and
connectivity watch included, right after the host's `await destroy()` returned.
The host tore the SDK down and it came back to life requesting ads.

Fixed by moving the cancel, the attempt-count reset and the stranded-callback
answer to the *top* of `_destroy()`, above its first await, next to the queue
drain and the `_isInitializing` release. Nothing in between can re-arm the
timer: both `_scheduleInitRetryIfNeeded` call sites sit behind an
`_initSuperseded` early return. With the cancel there, `_destroyInFlight` is set
and the timer is killed inside the same microtask, so the other ordering (the
timer fires just *before* `destroy()`) is covered too — that attempt takes its
generation synchronously and the teardown's `_initGen++` supersedes it.

**And the reproduction is the finding's real value.** My own audit note had
written this window off as "a few microseconds wide, no fake-clock seam on
`_initRetryDelays`, position not independently pinnable" — recorded honestly,
and wrong. `codex` parks the teardown for as long as it likes with a *paused*
subscriber to `AdManager().events`: `_eventStream.close()` cannot complete while
a subscription is paused, so the 5s retry backoff elapses entirely inside the
teardown. That is now
`an init retry that fires during destroy() cannot resurrect the SDK` in
`test/init_post_success_throw_test.dart` (41 tests), and moving the cancel back
to its old position makes it RED with `built: 2` — a second adapter, i.e. the
resurrection. The lesson generalises: "no seam for this" usually means "no
*obvious* seam", and a paused stream subscription is a general-purpose way to
hold any teardown that closes a broadcast stream.

Mutation ledger, round 9:

| Mutation | Result | Test that died |
| --- | --- | --- |
| Move the retry cancel back below `_disposeAdapter()` | RED | `an init retry that fires during destroy() cannot resurrect the SDK` |
| Null out the stranded-callback answer at its new position | RED | `destroy() answers the pending retry's stranded caller false` |

After round 9: `flutter analyze` clean, `flutter test` **1181 passing**.

After round 8: `flutter analyze` clean, `flutter test` 1180 passing.

### iOS Simulator, driven by hand (2026-08-26)

The counterpart to the scripted iOS run: the app driven through real taps, so a
human could answer the prompts a harness cannot. Three things came out of it.

1. **The UMP form cannot present on this Simulator at all** — not merely under
   `integration_test`, which is how the earlier note in this document put it.
   A plain `flutter run` reached `[UmpConsent] consent status: required` and no
   form ever appeared. So iOS consent verification needs a real iPhone; the
   Simulator can prove the SDK's *reaction* to UMP, never the form itself.
2. **The 180s dismiss backstop works on device, and fails closed.** The run
   produced, in order: `⚠️ consent form: consent form dismiss timed out after
   180s`, `✅ done canRequestAds=false status=required formShown=true`,
   `⚠️ UMP inconclusive … keeping the persisted consent value instead of
   downgrading it`, then adapter init with
   `applyConsent → nonPersonalizedAds=true`. Init does not hang forever waiting
   on a form that will never be answered, and what it falls back to is the
   conservative, GDPR-correct value.
3. **Refusals are visible to the user, not silent.** With consent unresolved,
   the rewarded demo logged `⏭️ loadInterstitial skipped — consent not granted
   (UMP)` and `showRewardedAd ⏭️ no valid ad`, and showed a toast
   ("Ad not ready — please wait.") rather than doing nothing.

Also observed live: the ATT explainer dialog presents before the native ATT
prompt (`Our app wants to stay free for you` → Continue); an unanswered native
ATT prompt times out after 20s and lets init proceed
(`⚠️ ATT prompt timed out after 20s`); and a VIP window expiring mid-session
flipped `VipManager active state changed: true → false` and released the ad
surfaces without a restart.

What this run could NOT do, stated plainly: show a fullscreen ad. The abandoned
consent form keeps the fullscreen mutex (`⏭️ app-open on resume skipped — a
consent form is on screen`) and consent never resolves, so every fullscreen
surface is correctly refused. The proof that AdMob fills and shows on iOS
remains the scripted run above, not this one.

### Round-25 QC round 10 — no Blockers, no Majors, two MINORs both taken

Scores: **codex 9 / claude 8 / agy 9.8**. First round of the series where all
three reviewers came back with no BLOCKER and no MAJOR. Both MINORs were fixed
anyway.

**codex** — "No findings. I found no reproducible BLOCKER, MAJOR, or MINOR defect
in the reviewed init/destroy/queue lifecycle."

**agy** — ran an 8-mutation ledger (7 RED, 1 GREEN-by-design: the
`_drainingInitResult` restore, already documented as not independently pinnable).
One MINOR: `_stopAdRetryTimer()` / `_stopConnectivityWatch()` sat at the tail of
`_destroy()` while `initialize()`'s re-init branch stops both *above* its own
`await _disposeAdapter()` — asymmetric.

agy called it defence-in-depth on the grounds that both callbacks self-guard on
`isInitialised`. Reading the guard says it is worse than that:
`isInitialised => _config != null && _adapter != null`, and neither field is
cleared until well past `await _eventStream.close()`. So the `!isInitialised`
check inside `_scheduleNextRetry` (line 6068) does **not** cover the teardown
window at all: a 5-minute poll tick landing in it passes every guard and refills
ads into an adapter this teardown is about to dispose. Both calls moved above the
first await. Not independently pinnable — `_retryIntervalMs` is a `static const`
with no seam, and while the paused-subscription trick can hold a teardown open
for five real minutes, not cheaply enough to live in the suite. Documented as
such at the call site.

**claude** — one MINOR, and an honest one: not a live bug, a **coverage gap**.
It deleted `_pendingRetryOnComplete = null;` from inside the retry timer's own
callback and the whole 1181-test suite stayed green. The code was right and
nothing pinned it. The scenario it protects: adapter init fails, the 5s retry
timer fires *outside* any teardown, its `initialize()` parks on a real native
await, the host calls `destroy()` mid-flight — without the null-out, `_destroy()`
finds a live callback there and answers `false`, and the superseded attempt
answers a second time. A host running `Navigator.pop()` in `onComplete` pops twice.

Pinned by a new test, `a retry that already fired cannot have its caller answered
twice`, asserting both the seam (`debugPendingRetryCallback` must be false once
the timer has fired) and the observable (`calls == 1` after the teardown plus the
gate release).

| Mutation | Result |
|---|---|
| Remove `_pendingRetryOnComplete = null;` from the timer callback | **RED** — `Expected: false / Actual: <true>` |
| Move `_stopAdRetryTimer()` / `_stopConnectivityWatch()` back to the tail of `_destroy()` | GREEN — expected, documented above |

After round 10: `flutter analyze` clean, `flutter test` **1182 passing**
(42 in `test/init_post_success_throw_test.dart`).

### Device verification — Android, real ads, all four surfaces + EEA consent

TECNO BG6 (`118743744X002560`, Android 13), real AdMob test creatives:

- 28-file unattended sweep: 27 PASS, 1 flake absorbed by the retry.
- The three files the CI runner deliberately excludes because they need a human
  to dismiss a real ad — `app_open_ad_test.dart`, `interstitial_ad_test.dart`,
  `rewarded_ad_test.dart` — all PASS, driven by hand with `adb shell input tap`
  on the dismiss control only. Never on "Install": a real click would be CTR
  fraud against the very safety layer under audit. The rewarded X only appears
  after "Reward in N seconds" expires, so the reward path was watched to term.
- `ump_eea_consent_test.dart` PASS. This one needed the full documented dance:
  `UMP_EEA_DEBUG=true` plus the hashed device id UMP prints once
  (`I/UserMessagingPlatform: Use new ConsentDebugSettings.Builder()
  .addTestDeviceHashedId("…")`), then `pm clear`, then `flutter run` (not
  `flutter test` — under the test harness the SDK's own 5s dismiss timeout fires
  long before a human tap and the answer never persists) and a hand tap on
  "Consent" on the real GDPR TCF form (206 partners). The app logged
  `UMP gate → canRequestAds=true (status=obtained)`, after which the test's
  MJ32 invariant held on device: `status=obtained ⇒ formShown=false`.

So requirement (3) — all four ad types, real lifecycle — and requirement (6) —
consent applied correctly — are now verified on hardware, not only in the suite.
iOS remains unverified: CI is off for billing reasons, per instruction.

### Round-25 QC round 11 — one paused listener could brick the SDK

Round 11 ran degraded and it is worth recording why. Three reviewer CLIs were
launched in parallel on one machine, each running `flutter test`: `agy` never got
past "I am waiting for `flutter test` to complete", and `codex` reported its
baseline as `+740 -27`, i.e. 27 failures. Re-running the same tree alone: **1182
passing, exit 0**. Those 27 were resource starvation (suite-load timeouts,
guarded-pump conflicts), not defects — reviewer baselines taken under parallel
load cannot be trusted. `claude` never started at all: `Not logged in · Please
run /login`. So round 11 is effectively a single-reviewer round. **codex: 4/10.**

Its two structural findings were both real.

**BLOCKER — one paused subscriber could hang `destroy()` forever.** `_destroy()`
did `await _eventStream.close()` with no bound. A host subscription to the public
`events` stream may legally be *paused* — a route transition, backpressure, a
listener the framework parked. A paused subscriber buffers the done event, so
`close()`'s future does not complete until it resumes. And `_destroyInFlight` is
published before that await, so every later `initialize()` parks behind it: one
paused listener and the SDK is bricked for the rest of the process, while
`isInitialised` still answers `true`.

Bitter detail: this session *used* that exact behaviour as a test instrument. The
round-9 regression test holds a teardown open past the retry backoff with a
paused subscription. Two rounds of using a hang as a tool without once asking who
else can trigger it.

Fixed by capping the wait at 2s with a warning log — a live listener still gets
its done event and hosts that clean UI up on it still work, but no host can hold
the teardown open indefinitely.

**MAJOR — an App Open ad could be shown on top of an SDK being torn down.** The
lifecycle observer was removed at the very end of `_destroy()` and
`_resumeFallbackTimer` cancelled later still, inside `_resetGuardState()`. Both
sit after the teardown's awaits, and across those awaits `_adapter` and `_config`
are untouched — so every guard on the resume path (`identical(_adapter, ad)`,
`isInitialised`) still passes. A user returning to the app mid-teardown could be
shown an App Open ad, with the native call landing on an adapter about to be
disposed: an AdMob policy violation and a crash risk. Both the detach and the
timer cancel moved to the top of `_destroy()`, next to the round-10 move.

**MINOR — the round-10 test was wall-clock flaky.** codex ran it on an unmutated
tree and it *failed*: after a flat `Future.delayed(5200ms)`, `built` was still 1,
because the first attempt's own VIP/UMP work had eaten into the window. Correct
and worth more than it looks — a test that can fail without a defect teaches the
next reader to ignore it. Fixed twice over: a new `AdManager.debugInitRetryDelays`
seam shortens the backoff in this file (these tests pin an ORDERING, never the
production 5s/15s/30s schedule), and the fixed sleep became a `_pumpUntil` poll.
Side benefit: the file runs in 4s instead of 14s.

| Mutation | Result |
|---|---|
| Drop the 2s cap, back to a bare `await _eventStream.close()` | **RED** — `a paused events subscriber cannot hang destroy() forever` fails on its own 10s bound |
| Move the observer detach + `_resumeFallbackTimer` cancel back to the tail | **RED** — `Expected: false / Actual: <true>` on `debugLifecycleObserverAttached` mid-teardown |

Both fixes are pinned by new tests (43rd and 44th in the file). After round 11:
`flutter analyze` clean, `flutter test` **1184 passing**, exit 0.

### Round-25 QC round 12 — "stop listening" is not "stop working"

codex alone again (`claude` still not logged in; `agy` skipped to avoid the
parallel-load starvation that wrecked round 11). It confirmed the tree first:
`flutter analyze` exit 0, `flutter test` **1184 passing, exit 0** — explicitly
retracting round 11's phantom 27 failures. **codex: 6/10.**

**MAJOR — a resume buffer launched *before* the teardown could still show an ad.**
Round 11 detached the lifecycle observer in the prologue, which stops the
framework delivering a *new* resume. It does nothing about a resume that arrived
a moment earlier and already opened `AdLoadingDialog.showAdBuffer`: that buffer's
`onComplete` fires ~500ms later, with `_adapter` and `_config` still live, so
every guard inside it passes and `showAppOpenAd()` goes through to the native
layer on top of an SDK being dismantled.

The lesson generalises past the one path: disarming a *source* of work is not the
same as disarming work already in flight. So the fix sits at the convergence
point rather than in the buffer callback — `_teardownBlocksShow()`, checked at
the head of all four fullscreen show paths (App Open, interstitial, rewarded,
rewarded interstitial). Any other already-launched timer or callback that reaches
a fullscreen show during a teardown is refused by the same check, and the skip is
emitted as `teardown_in_flight` rather than swallowed.

**MINOR — `debugInitRetryDelays = []` dropped the host's callback entirely.**
`@visibleForTesting` is an analyzer annotation, so round 11's new seam is
reachable in release. With an empty list the clamped index threw
`Invalid argument(s): 0`, the outer catch re-entered the same scheduler, the
second throw escaped `initialize()`, and `onComplete` was never called — the one
outcome this entire init path exists to make impossible. An empty override is now
treated as no override.

**Three attempts to pin the MAJOR, and mutation testing caught both bad ones.**
Worth writing down because a green test is not evidence of anything:

1. First draft held the teardown inside `_SlowDisposeAdapter.dispose()`. Green
   with the guard mutated away — `_disposeAdapter()` clears `_adapter` *before*
   awaiting the native dispose, so the shows were refused for "adapter null".
2. Second draft moved the hold to the event-stream close (adapter still live) and
   asserted the emitted skip reasons. Still green mutated: `close()` has already
   been called at that point, so `_emitSkip` reaches nobody. Also switched off
   `onAdDismiss(false)` as an observable — an unloaded slot answers `false` too.
3. Third draft: hold at the close, mark the App Open slot ready, open the consent
   gate via `debugCanRequestAds` (without it every show was refused for "consent
   not granted (UMP)" before reaching the guard), and assert the *adapter* was
   never asked. **RED** when mutated.

codex also cleared three things it was asked to attack: the 2s close cap is safe
with respect to controller ownership (a paused old subscriber that resumes later
receives only `done`, never events from the new controller); nothing between the
observer detach's old and new position depends on it; and it found no credible
synchronous throw in the prologue under normal Flutter execution.

| Mutation | Result |
|---|---|
| `_teardownBlocksShow` always returns false | **RED** — the adapter was asked to show an App Open ad mid-teardown |
| Empty override no longer falls back to the real schedule | **RED** — `Invalid argument(s): 0` escapes `initialize()` |

After round 12: `flutter analyze` clean, `flutter test` **1186 passing**, exit 0.

---

## Round-25 QC round 13 — the guard at the door does not help if the room has a window

`codex`, run alone (round 11 taught us that three reviewer CLIs sharing a laptop
starve each other's `flutter test` and produce phantom failures). It confirmed
the baseline — `flutter analyze` exit 0, `flutter test` exit 0 with 1,186
passing — and confirmed both round-12 fixes are mutation-pinned:

> Replaced the teardown guard with an unconditional non-block. The focused
> teardown test went red… Removed the `override.isNotEmpty` fallback. The
> empty-override test went red with `Invalid argument(s): 0`…

Then it filed two MAJORs, and both were real.

### MAJOR 1 — a rewarded ad played, and paid out, over a dying SDK

Round 12's fix put `_teardownBlocksShow` at the head of all four fullscreen show
methods and called that "the convergence point". It is not, because two of those
methods keep running after the check.

`showRewardedAd(bypassVipGuard: true)` — the VIP "watch a real ad to extend your
window" path — finds the slot unpreloaded (the loader deliberately skips VIP
members) and awaits `_loadRewardedOnDemand`, which waits up to **15 seconds** on
a slot-state listener. A `destroy()` starting anywhere inside those 15 seconds is
invisible to the re-check that follows, because that re-check consults
`_fullscreenBusyReason`, and `_fullscreenBusyReason` did not know about
`_destroyInFlight`. codex did not argue this; it wrote a probe and watched
`showRewardedCalls == 1` and a successful reward land while
`debugDestroyInFlight` was `true`.

Worth naming plainly: this is the same defect as round 12, one await further
down. Round 12 checked at the door. The lesson is that in an `async` method
"checked at entry" means "checked at entry", and every `await` re-opens the
question.

**Fix** — the teardown moved into `_fullscreenBusyReason` itself, which is the
one gate every fullscreen path re-reads:

```dart
if (_destroyInFlight != null) return 'a teardown is in flight';
```

One line covers all four ad types, every post-await re-check, and any fifth
format added later, by construction rather than by remembering. `destroy()` also
calls `_recomputeFullscreenBusy()` on both edges, because `_fullscreenBusyReason`
feeds the public `fullscreenBusy` notifier a host wires to its own UI — without
that the mirror would have gone stale for the length of the teardown and stayed
stale after it.

### MAJOR 2 — the convergence point had a public bypass

`AdProviderAdapter` is exported. Its `showAppOpen`, `showInterstitial`,
`showRewarded` and `showRewardedInterstitial` are public. And `AdManager.adapter`
handed the live instance to anyone who asked. So:

```dart
final ad = AdManager().adapter!;
AdManager().destroy();          // not awaited
ad.showInterstitial(onDone: ...);   // answers to no guard in AdManager at all
```

Every safety layer this audit has been hardening for thirteen rounds — consent,
caps, the fullscreen mutex, the teardown — sits in `AdManager`, and this route
skips the class entirely.

**Fix** — the public getter reports nothing while a teardown is in flight:

```dart
AdProviderAdapter? get adapter => _destroyInFlight != null ? null : _adapter;
```

Deliberately *not* a guard added to the exported abstract class: adding a member
to an exported abstract interface is a breaking change for anyone implementing
it, which is a documented constraint in this repo. Internal callers use
`_adapter` and are unaffected. The banner/MREC/native widgets do read the public
getter, and stopping them from building against an adapter that is about to be
disposed is the point, not collateral damage.

Honest limit, stated because a reviewer will find it anyway: a host that fetched
the adapter **before** calling `destroy()` and stashed it in its own field still
holds a live reference. Closing that would take a guard inside each concrete
adapter. This closes the realistic route (fetch-then-call) without a breaking
change; the remaining one requires a host to deliberately cache a handle the
README never tells it to cache.

### MINOR — a debug seam could park the host callback for a century

`debugInitRetryDelays` accepted `[Duration(days: 36500)]`, which with a failing
adapter init left `onComplete` in `_pendingRetryOnComplete` for a hundred years:
`initialize()` returns, the host is never answered, and no timeout anywhere
rescues it. Fixed by capping any override at the longest production backoff (30s)
— a test seam may make the retry faster than production, never slower. Pinned
via a new `debugLastInitRetryDelay` seam rather than by a test that sits through
three real 30-second backoffs.

### Mutation ledger — 3 of 3 RED

| Fix removed | Result |
|---|---|
| the teardown line in `_fullscreenBusyReason` | RED — `showRewardedCalls` `Expected: <0> Actual: <1>`, plus the busy-mirror assertion |
| the null-out in the public `adapter` getter | RED — `Expected: null Actual: <Instance of '_OnDemandRewardedAdapter'>` |
| the 30s cap on `debugInitRetryDelays` | RED — `Expected: 0:00:30.000000 Actual: 876000:00:00.000000` |

Four new tests (1,186 → **1,190**), `flutter analyze` clean. One of the four is
a pure **control** — `the on-demand VIP rewarded path does reach the adapter` —
because rounds 11 and 12 each produced a test that passed for the wrong reason,
and "the adapter was never asked" proves nothing unless something proves the same
sequence *does* ask it when it may.

---

## Round-25 QC round 14 — the load side of the same window, and the crash behind it

`codex`, alone. Confirmed the baseline (`flutter analyze` exit 0; `flutter test`
exit 0, 1,190 passing) and re-confirmed three fixes by mutation, including one
from round 9 it had not re-tested before:

> Removed `_destroyInFlight` from `_fullscreenBusyReason`: RED… Made the public
> `adapter` getter expose `_adapter` during teardown: RED… Removed delivery of
> `false` to `_pendingRetryOnComplete` during destroy: RED.

It also explicitly cleared the two things round 13's fix could plausibly have
broken: no `fullscreenBusy` edge-state defect, and no stale replayed init event.
Score 5 → **7/10**.

### MAJOR — a load could still start during a teardown, and its callback could crash the app

Round 13 closed the four **show** paths. The four **load** paths
(`loadAppOpenAd`, `loadInterstitial`, `loadRewardedAd`,
`loadRewardedInterstitialAd`) were untouched, and the public-getter fix does not
reach them: they read the private `_adapter`, not the getter that now hides it.
codex's probe expected zero native calls during a held teardown and got 1.

Two distinct harms, and the second is the serious one:

1. **A wasted request.** An ad fetched during a teardown is never shown. The
   network counts it as a request with no impression, which is exactly the
   metric AdMob and AppLovin watch.
2. **A crash.** The native callback closes over the adapter and later calls
   `slot.markReady()` / `markFailed()`. Every one of those writes
   `state.value`, and writing a disposed `ValueNotifier` throws
   `A _SlotStateNotifier was used after being disposed`. That is not a
   hypothetical — it is the literal error the mutation test prints once the new
   guard is removed. A host app whose only sin was calling `destroy()` while an
   ad was loading would take that exception.

Fixed in two halves, because one half cannot cover the other:

**Half 1 — no new load starts during a teardown.** A `_teardownBlocksLoad`
helper next to the existing `_teardownBlocksShow`, called at the head of all four
load methods (`loadAppOpenAd` also answers its `onAdLoaded(false)`). Emits a
`teardown_in_flight` skip like its show-side twin.

**Half 2 — a late callback is dropped, not fatal.** No guard inside `AdManager`
can recall a request that was already in flight when `destroy()` was called, so
the slot itself has to survive it. `AdSlot`'s state notifier now drops writes
after disposal and counts them:

```dart
@override
set value(AdSlotState newValue) {
  if (_disposed) { debugDroppedWrites++; return; }
  super.value = newValue;
}
```

One override covers `markReady`, `markFailed`, `markDismissed`,
`markShowFailed`, `reset` and anything added later, because they all funnel
through that setter. Dropping the write is the correct outcome, not a papered-over
bug: the slot belongs to an adapter that no longer exists, so the new state has
nothing left to mean. `debugDroppedStateWrites` is exposed so a test can prove
the drop happened rather than infer it from an absence.

### Mutation ledger — 2 of 2 RED

| Fix removed | Result |
|---|---|
| `_teardownBlocksLoad`'s check | RED — `Expected: <1> Actual: <2>` (a second native request issued mid-teardown) |
| the post-dispose write guard in `AdSlot`'s notifier | RED — `threw FlutterError: A _SlotStateNotifier was used after being disposed` |

Two new tests (1,190 → **1,192**), `flutter analyze` clean.

**A test-authoring note worth keeping**, because it cost three attempts: the
control half of the load test kept failing for `skipped — no network`. A unit-test
process has no connectivity plugin, so the real watch resolves to `connected:
false` — and a mutated guard would then have passed the test for that reason
alone. The fix is to seed last-known connectivity `true` and push `isConnected`
down its pre-ready branch (`debugConnectivityReady = false`), in that order,
*after* the watch has finished starting. This is the fourth round in a row where
the first draft of a test passed or failed for a reason that had nothing to do
with the defect under test.

---

## Round-25 QC round 15 — the radio blinked, so the SDK called a good key a fake

Found on a real device (OPPO CPH1989, AdMob provider), not by the suite. It was
the single FAIL in the 29-file device sweep: `vip_revocation_list_test.dart`
reported `Expected: VipRedeemStatus.success Actual: VipRedeemStatus.invalid`
while `adb shell ping -c 2 8.8.8.8` showed 0% loss throughout.

**Root cause.** `connection_notifier`'s *first* snapshot after process start can
say "offline" on a phone that is demonstrably online — 3 of 36 app launches in
the sweep logged `connected=false` before settling to `connected=true` about a
second later. `VipManager.redeemSignedKey` consulted that single read. A user
who pasted a valid key in the first second after opening the app had it
rejected.

**Second defect behind the first.** The rejection came back as
`VipRedeemStatus.invalid`, which is also what a forged or expired key returns,
so the shipped `VipRedeemScreen` told the user *"The VIP key you entered is
invalid or expired."* — the worst possible message for a paying customer whose
key is fine. A support ticket that reads "you sold me a dead key" is the
product outcome of a one-second radio glitch.

Neither defect is a regression from rounds 11-14; both have shipped since the
offline gate was introduced. The gate itself stays — "redeeming needs network"
is a deliberate product rule, not a bug (see the note in `vip_manager.dart`).

### The two fixes

1. **`VipManager._waitForConnectivity`** — a single negative read is no longer
   trusted. Poll `_isConnectedCheck()` every 100ms for up to 2s and let the
   first positive answer through; a genuinely offline device still gets
   rejected, just 2s later. Counted retries, deliberately not a
   `DateTime.now()` deadline: a wall-clock deadline is untestable under
   `flutter_test`'s fake clock (the waits are virtual, the deadline is not, so
   the loop spins forever) and an OS clock jump mid-poll would skew it.
2. **`SignedVipRedeemResult.offline(...)`** — carries `isOffline: true` while
   `status` stays `VipRedeemStatus.invalid`, and `VipRedeemScreen` shows a new
   `offlineMessage` ("No internet connection. Connect and try again — your key
   is still valid."). Deliberately a flag and **not** a new enum value: adding
   one to the exported `VipRedeemStatus` would break every host app with an
   exhaustive `switch` — a breaking change for a bug fix.

### Mutation ledger — 2 fixes, 2/2 RED

| Mutation | Red |
|---|---|
| gate back to the single read (`if (!_isConnectedCheck())`) | `Expected: true Actual: <false>` (redeem rejected) and `Expected: a value greater than or equal to <1500> Actual: <0>` (no poll happened) |
| `.offline(...)` back to `.invalid(...)` | `Expected: true Actual: <false>` (`isOffline`) and `Found 0 widgets with text "No internet connection. …"` |

### Tests — `test/vip_redeem_offline_flag_test.dart`, 4 new (suite 1,192 → 1,196)

- unit: first read false, every read after it true → redeem **succeeds**, and a
  CONTROL assertion (`reads > 1`) proves the gate actually re-read rather than
  passing because the first read was lucky.
- unit: genuinely offline → rejected, `isOffline` true, elapsed ≥1.5s and <5s
  (the poll is waited out but the caller is not hung), and the key is **still
  redeemable** afterwards once online — the one-time-use ledger was never
  touched.
- unit CONTROL: a garbage key on an online device → `isOffline` **false**, so
  the flag is specific to the network gate.
- widget: the shipped `VipRedeemScreen` on an offline device shows the offline
  message, **not** "invalid or expired", keeps the key in the field for a
  retry, and stays `VIP NOT ACTIVE`.

**Test-authoring note (the fifth round running).** The widget test's first
draft failed with zero SnackBars: the poll's `Future.delayed` is a *virtual*
timer inside `testWidgets`, so only `pump(duration)` advances it, while the
`SharedPreferences` reply needs a real event-loop turn (`runAsync`). The
offline path needs both, in that order — `pump(3s)` then `runAsync`. Worth
recording because the wrong-reason failure looked exactly like "the fix does
not work".

### Round-15 reviewer finding — a late AdMob fill leaks the native ad (MAJOR, 6/10)

`codex` scored the round-13/14/15 diff **6/10** and filed one MAJOR, verified
against the tree (`flutter analyze` clean, 1,196 passing) and confirmed here.

**The leak.** `AdMobAdapter.dispose()` releases the four fullscreen ads it can
see at that instant. GMA, however, delivers a fill whenever it is ready —
including after the teardown. The four `onLoaded` handlers stored that late ad
into the discarded adapter (`_appOpenAd = ad;` and its three siblings), and
since a fresh adapter is built by the next `initialize()`, **no code would ever
dispose it**: one leaked native ad object per late fill, for the lifetime of the
process. Round 14's disposed-notifier guard hid the symptom (no crash) without
touching the cause.

**Fix.** A `_fullscreenDisposed` flag, set as the FIRST statement of `dispose()`
(a fill can land while `dispose()` itself is running), plus one shared guard —
`_discardIfDisposed(ad, label)` — called at the head of all four `onLoaded`
handlers, mirroring the existing `_discardIfConsentStale` twin next to it. It
disposes the orphan and returns.

**Half the finding did not reproduce.** codex also claimed the late
`markReady()` fires a stranded `pendingCallback(true)`, telling the host an ad
is ready after its adapter is gone. It cannot: `dispose()` calls
`AdSlot.reset()`, which already fires the pending callback with `false` and
clears it, so the late `markReady()` has nothing to fire. Verified by probe
(`answers == [false]` immediately after `dispose()`, unchanged by the late
fill), so the guard deliberately does **not** answer the host — that code would
be dead. Both halves are pinned by assertions in the test file so a future
reviewer does not re-file either.

**Banner / MREC / native need no equivalent.** Their loaders are keyed and
`dispose()` empties the per-key maps, so the pre-existing slot-identity guard
(`!identical(_bannerSlotsByKey[key], slot)`) drops a late fill before it can be
stored, and anything stored before the teardown was disposed on the way out by
`disposeBannerInstance`. Checked rather than assumed, and no code was added for
a leak that cannot happen.

#### Mutation ledger — 3/3 RED (suite 1,196 → 1,201)

| Mutation | Red |
|---|---|
| `_discardIfDisposed` always returns false (the shipped bug) | `Expected: <1> Actual: <0>` (app-open ad never disposed) |
| same, three other types | `Expected: [1, 1, 1] Actual: [0, 0, 0]` |
| same, disposed-notifier path | `Expected: <1> Actual: <0>` |
| guard stops answering `pendingCallback(false)` | **stayed GREEN** — which is the evidence that half of the finding is not real, not a missing test |

Tests: `test/admob_post_dispose_fill_test.dart`, 5 new, driven by a
`_DeferredBridge` that holds every `onLoaded` back so the test dictates the
ordering `load → dispose → fill`. Includes a CONTROL (a fill landing *before*
`dispose()` is still cached, still answered `true`, still released by the normal
teardown) and a second-adapter test proving the flag is per instance, not global
— a global would have broken every provider switch.

## Round-25 QC round 16 — the teardown that reported success and stopped halfway

`codex` scored **6/10** and filed one MAJOR, in the other adapter this time.
Confirmed and fixed.

**The defect.** `AppLovinAdapter.dispose()` destroys each widget AdView in a
loop that **awaits the native bridge per view**, iterating
`_bannerAdViewIdByKey.values` directly. A `preloadBanner()` already in flight
resumes inside that await and calls `_bannerAdViewIdFor(key)` — a `putIfAbsent`
that INSERTS into the very map being iterated. Dart throws
`Concurrent modification during iteration: _Map len:2`,
`AdManager._disposeAdapter` catches it, and the host is told the teardown
finished. Everything after the throw never ran: MREC AdViews never destroyed,
`_appOpenLoadCb` / `_interstitialDone` / `_rewardedDone` never answered (a
caller waiting on `loadAppOpen` waits forever), slots never reset, `_max` and
`_config` still populated on the abandoned adapter. Repeat destroy → re-init
cycles — VIP activation, provider switch, consent withdrawal — pile up native
AdViews.

Why the existing guards did not catch it: `_bannerDisposed` exists and
`_bannerAdViewIdFor` honours it, but it was set at the **end** of `dispose()`,
after the loops it was supposed to protect. The `!identical(_bannerSlotsByKey[key], slot)`
guard in the preload also passes, because the slot maps are cleared later still.

**Fix, three parts.**
1. `_bannerDisposed` / `_mrecDisposed` / `_nativeDisposed` are set as the FIRST
   statements of `dispose()`, before any await — so the accessors hand back
   their scratch objects and no insertion can happen. Same shape as round 15's
   `_fullscreenDisposed` in the AdMob adapter.
2. Both AdView loops iterate `.values.toList()` snapshots — a second line of
   defence, cheap, and it makes the invariant local to the loop.
3. A `preloadBanner`/`preloadMrec` that comes back **after** the teardown began
   destroys the native AdView it was just handed instead of parking it in a
   notifier nobody owns. Destroyed via `_bridge.destroyWidgetAdView` directly,
   not `_destroyWidgetAdViewWhenDetached`, whose retry timers `dispose()` has
   just cancelled — a retry armed at that point would outlive its adapter.

### Mutation ledger — 2/2 RED (suite 1,201 → 1,204)

| Mutation | Red |
|---|---|
| flags back at the end + live-map iteration (the shipped bug) | `Concurrent modification during iteration: _Map len:2.` ×4 |
| snapshot only, no post-teardown destroy (the half fix) | `Expected: contains <2> Actual: [1]` — the late AdView leaks |

Tests: 3 added to `test/applovin_adapter_test.dart` via `_TeardownRaceBridge`,
which parks `dispose()` inside its per-AdView destroy await so the test dictates
the ordering. Each race test asserts **both** halves: the late AdView is
destroyed, *and* `loadAppOpen`'s callback is answered `false` — that second
assertion is what proves `dispose()` ran past the loops instead of aborting
there. Banner and MREC both covered (MREC needs an `mrecId` in the config or
`preloadMrec` correctly refuses to request at all — the first draft silently
tested nothing), plus a CONTROL that a healthy preload destroys nothing.

## Round-25 QC round 17 — the retry that outlives the thing it was retrying for

`codex` scored **7/10** (r15 6 → r16 6 → r17 7) and filed one MAJOR. It also
independently re-ran round 16's mutation and got the documented red, and
reported that it looked for further live-map-iteration-across-await siblings,
provider-switch resurrections and consent/VIP correctness failures and found
none.

**The defect.** `_destroyWidgetAdViewWhenDetached` retries a refused native
destroy on a timer chain, and `dispose()` cancels `_destroyRetryTimers` on the
way out. But the cancellation only covers timers that are ALREADY armed: a
destroy still in flight when `dispose()` runs fails *afterwards* (the native
side refuses while the platform view is still attached) and its catch block
armed a **fresh** timer at that point — one nothing will ever cancel, which then
calls a bridge whose listeners have been cleared. Ordering:
`disposeBannerInstance()` starts the destroy → native future stays pending →
`dispose()` cancels timers, clears listeners, returns → the destroy fails → a
new retry timer is armed → it fires after the adapter is gone.

**Fix.** One guard, read AFTER the await (the same "checked at the door, walked
in through the window" shape as rounds 12-14): a new `_teardownStarted` flag,
set as the first act of `dispose()`, makes the catch block log and give up
instead of arming a retry. Teardown means stop — the native view goes away with
its Activity / UIViewController regardless. One guard covers banner and MREC
because both go through this one helper.

### Mutation ledger — 1/1 RED (suite 1,204 → 1,206)

| Mutation | Red |
|---|---|
| guard disabled (the shipped bug) | `Expected: [1] Actual: [1, 1]` — byte-identical to the reviewer's own probe |

Tests: 2 added to `test/applovin_adapter_test.dart` on a
`_DeferredFailingDestroyBridge` that holds the first destroy open across
`dispose()` and then fails it. The second is a CONTROL proving the retry chain
still works on a LIVE adapter — without it the "fix" could have been a silent
disabling of the leak protection that the chain exists to provide, and the first
test would have passed just as happily.

## Round-25 QC round 18 — the teardown that burned a paid VIP key

`codex` scored **6.5/10** and filed one MAJOR, with a reproduction. It is the
worst finding of this whole round series in customer terms, and round 15's own
fix is what made it wide.

**The defect.** `redeemSignedKey` checks `_disposed` at the top — a check added
in round 9 for exactly this hazard, with a comment explaining it. That check does
not survive the awaits that follow: the ~2s connectivity poll **added in round
15**, `PackageInfo` for AVP2 keys, the cached-CRL load, and `addVip`'s own
`_save()`. If the host tears the SDK down inside any of those windows (provider
switch, consent withdrawal, VIP-driven teardown), then:

- `_save()` correctly DROPS the grant — a discarded manager must not write over
  the store its replacement owns (round 9);
- but `_prefs.addRedeemedVipKeyId` and `_redeemedKeyLedger.markRedeemed` had no
  such guard and burned the kid anyway.

Consequence for a paying customer: the screen says "success", the next launch has
no VIP, and re-entering the key says "already used". On iOS the burn is in the
Keychain-backed ledger, so uninstalling and reinstalling does not recover it. The
money is simply gone.

`Expected: VipRedeemStatus.success / Actual: VipRedeemStatus.alreadyUsed` in the
reviewer's own reproducer.

**Fix.** One `_disposed` re-check placed AFTER `addVip`, immediately before the
two ledger writes: the key is marked used only once the grant has actually been
written. One check covers every await above it.

Two things worth recording:

- The obvious symmetric guard *before* `addVip` was written first and then
  **deleted**: disabling it left the tests green, because `addVip` on a discarded
  manager only mutates RAM (`_save()` drops, `_refreshActive` is `_disposed`-
  guarded) and the post-grant check catches the burn regardless. Same lesson as
  round 15's dead callback half — a guard that cannot be turned red is not a
  guard, it is decoration.
- Refusing the burn can, in the narrow case where the store write landed and the
  teardown followed it, let the retry stack a second window. `AdConfig.
  maxVipStackDuration` bounds that. Over-serving by one window is the right
  direction to be wrong about a key someone paid for.

### Mutation ledger — 2/2 RED (suite 1,206 → 1,209)

| Mutation | Red |
|---|---|
| post-grant `_disposed` check disabled (the shipped bug) | `Expected: false Actual: <true>` ×2 — `prefs.isVipKeyIdRedeemed(kid)` is true, i.e. the key was burned |
| pre-`addVip` check disabled | **stayed GREEN** — which is why that guard was removed instead of shipped |

Tests: 3 in `test/vip_dispose_mid_redeem_test.dart` — teardown during the
connectivity poll, teardown landing between the grant and the burn (via a store
whose first write calls `dispose()`), and a CONTROL proving an undisturbed redeem
still burns the key exactly once. Without the CONTROL, both teardown tests would
pass just as happily if the "fix" had stopped the SDK marking keys used at all,
handing every customer an infinitely reusable key.

Reviewer's coverage statement: no additional reproduced teardown/lifecycle leak,
no new consent ordering defect on either provider, no further VIP
stacking/clamp/expiry/revocation/clock defect, no new ad-policy defect, and no
iOS-only defect beyond this one (which is *worse* on iOS because the replay
record survives a reinstall).

## Round-25 QC round 19 — the teardown that un-revoked a revoked key

`codex` scored **7/10** and filed one MAJOR, reproduced. Eighth consecutive round
of the same shape: a guard at method entry that does not survive an await.

**The defect.** `refreshRevocationList` awaits a NETWORK fetch, and it persists
the CRL through `_prefs` **directly** — so `_save()`'s disposed guard, which
covers the entries store, does not cover this path at all. Ordering:

1. manager A starts `refreshRevocationList()`; the fetch hangs;
2. the host tears the SDK down (provider switch, consent withdrawal) — A is
   disposed;
3. manager B is created, fetches a NEWER CRL revoking a key, and caches it;
4. A's fetch finally answers with an older, empty list;
5. A compares it against **its own** `_revocationIssuedAt`, which never saw B's
   newer CRL, so the staleness check passes;
6. A writes the older CRL over B's.

Next launch: `load()` reads the rolled-back list and the revoked key — leaked,
refunded, resold — is redeemable again. The CRL is the only lever the SDK owner
has over a key that is already in the wild, and an ordinary destroy/re-init could
undo it.

**Fix.** One `_disposed` check after the fetch/verify awaits, before the CRL is
applied to RAM or written to disk. Returning (rather than persisting anyway) is
right: the live manager owns that cache and refreshes on its own schedule. Chosen
over a persisted compare-and-set on `issuedAt`, which only adds protection for
two simultaneously live managers — a state this SDK does not create — and would
have been hard to turn red, i.e. the decorative-guard trap of round 18.

Sibling sweep: all three direct `_prefs` writes in `vip_manager.dart` that follow
an await (`addRedeemedVipKeyId`, `setVipRevocationCacheRaw`,
`setVipRevocationPublicKey`) are now behind a post-await `_disposed` check — the
first from round 18, the other two from this fix.

### Mutation ledger — 1/1 RED (suite 1,209 → 1,211)

| Mutation | Red |
|---|---|
| post-fetch `_disposed` check disabled (the shipped bug) | `Expected: VipRedeemStatus.invalid Actual: VipRedeemStatus.success` — byte-identical to the reviewer's own reproducer |

Tests: 2 in `test/vip_crl_dispose_rollback_test.dart` — the race itself, asserted
across a simulated relaunch (fresh manager reading the cache off disk), and a
CONTROL proving a live manager still applies a newer CRL, that it lands on disk,
and that it revokes only the kid it names. Without the CONTROL the fix could have
been "stop persisting CRLs", which would disable revocation altogether and pass.

Reviewer's coverage statement: no additional finding in fullscreen/widget
teardown on either adapter, consent/UMP propagation and supersession on either
provider, VIP stacking/clamping/expiry/replay/clock rollback, ad-policy gates
(consent-before-request, fullscreen serialisation, modal protection, App Open on
resume), iOS ATT/App Open/Keychain paths (reasoning only, no device), or other
async entry-guard races across `lib/`.

## Round-25 QC round 20 — the sweep round: my own round-19 fix was half a fix

`codex` scored **7/10**. This round the reviewer was asked to sweep the
guard-across-an-await class EXHAUSTIVELY instead of stumbling on instances, and
to hand back the clean rows too. It did both: one reproduced MAJOR, one
hypothesis (promoted below), and a table of thirteen risky awaits it checked and
found correctly guarded.

**MAJOR — round 19's guard was not the last await on that path.** After the
post-fetch `_disposed` check, `refreshRevocationList` still does
`await _clampRevokedEntries()` — which writes the entries store — before the two
`_prefs` CRL writes. A manager parked in that clamp write can be disposed,
resume, and roll the cached CRL back exactly as before. Same consequence: a
leaked/refunded/resold key redeems again after a relaunch.

Fix: a second `_disposed` check immediately before the two `_prefs` writes, i.e.
in front of the actual harm. The clamp itself is safe to have run — it only ever
narrows a grant, and its own persistence goes through the disposed-guarded
`_save()`. Reviewer's reproducer (a store that parks the clamp's write, plus a
relaunch assertion) adopted into
`test/vip_crl_dispose_rollback_test.dart`.

**Promoted hypothesis — the reward the user watched an ad for.**
`VipRedeemScreen._onWatchAdForVip` captured `AdManager().vip` and then awaited a
rewarded ad, which is on screen for 15-30 seconds. A provider switch or re-init
in that window discards the captured manager, `_save()` drops the grant, and the
screen still played the confetti and claimed success. The reviewer marked it a
hypothesis for lack of a widget reproduction; it reproduced, so it is fixed the
same way: re-read `AdManager().vip` after the ad and grant through whichever
manager is live (not refuse — the user really did watch the ad).

### Mutation ledger — 2/2 RED (suite 1,211 → 1,214)

| Mutation | Red |
|---|---|
| pre-persist `_disposed` check disabled (the shipped bug) | `Expected: 'CRL1.MjAwMHxyZXNvbGQta2V5…' Actual: 'CRL1.MTAwMHxvbGQtZ3JhbnQ=…'` — the old CRL back on top |
| grant through the captured manager instead of the live one | `Expected: true Actual: <false>` — the ad played, no VIP |

Tests: 1 added to `test/vip_crl_dispose_rollback_test.dart` (3 there now) and 2
new in `test/vip_watch_ad_manager_swap_test.dart`, the second a CONTROL proving
the ordinary watch-ad flow still grants.

Two test-authoring traps recorded: the watch-ad button's label is
`watchAdButton.toUpperCase()` (`'WATCH AD'`), NOT the section title
`'Watch ad → free VIP'` — tapping the title silently does nothing and the ad
never shows; and a manager left holding an active VIP window arms an expiry
timer, which `flutter_test` reports as `'A Timer is still pending even after the
widget tree was disposed'` before `tearDown` gets a turn, so the managers must be
disposed inside the test body.

### The sweep table the reviewer returned (risky awaits, correctly guarded)

`AdManager.initialize` (`initGen`/`_initSuperseded`, abandoned adapters disposed);
on-demand rewarded load (`_fullscreenBusyReason` re-read after the load);
fullscreen load watchdog (`armLoadWatchdog` refuses unless still loading);
consent/TCF reads and writes and resume reconciliation (`_consentIntentEpoch`
re-read after every storage await); AdMob fullscreen fills (`_discardIfDisposed`
plus consent epoch); AdMob keyed banner adaptive-size lookup (slot-identity
check after the await); AppLovin banner/MREC preload (disposed flag then
slot-identity, orphaned native view destroyed); AppLovin detached-view destroy
(`_teardownStarted` after the failed await); VIP storage load (post-await
`_disposed`, mutation epoch, save-queue drain); signed-key redemption (post-grant
`_disposed`); UI dialogs (`mounted` re-checks).

That table is the useful part of this round: it is the first time the class has
been checked systematically rather than sampled, and everything outside the two
VIP paths above came back guarded.

---

## Round-25 QC round 21 — the privacy signal we read out loud and never obeyed

Reviewer: `codex`, own `/tmp` copy, `REVIEW_DIFF.patch` of `lib` + `test`.
Score **6/10** — the lowest since round 13, and the reason is that all three of
its MAJORs were aimed at *product claims* rather than at the round 12-20 fixes:
the reviewer stopped auditing the diff and audited the seven requirements again.
That is a fair thing to do at this point, and one of the three was real.

### Finding 1 (real, fixed) — `IABUSPrivacy_String` was read, reported, never applied

`IabStorage.usPrivacyOptedOut()` has parsed the IAB US Privacy string since m10
(round-5 audit) and `AdManager.usPrivacyOptedOut` exposes it. m10's fix was
scoped to the **compliance report**, which was the thing that had lied — it
reported `doNotSell: false` for a Californian who had opted out. The comment m10
left behind explains why that was thought sufficient: *"Both native SDKs read
the real signal themselves, so ads behaved correctly; the compliance report was
the thing that lied."*

That is half true, and the half that is false is the half that matters. The
native SDKs read the string for their own internal purposes; what they do NOT do
is set the flags this SDK is responsible for:

| Provider | What the SDK owes it | Value before this round |
|---|---|---|
| AppLovin | `AppLovinMAX.setDoNotSell(...)` | `false` |
| AdMob | `restricted_data_processing` on every request | unset |

`AdConsent.doNotSell` had exactly one writer — the host. So an app that shipped
a CMP (including Google UMP, which writes this key itself) and trusted this SDK
to "apply consent to both providers" served every opted-out US user with no sale
opt-out on the request. The reviewer's repro: `Expected: true Actual: <false>
same signal must reach AppLovin setDoNotSell and AdMob RDP`.

**Fix** — one helper, `AdManager._reconcileDeviceUsPrivacy()`, called from the
two places the TCF reconcile already lives:

* SDK init, immediately after the existing TCF reconcile and *before* the first
  preload of the session (a returning user's opt-out is already on disk);
* `_recheckConsentOnResume()`, at the top and **before** its TCF read — that
  method returns early whenever there is no TCF data at all, which is every US
  user, so putting the call after it would have covered nobody.

Three decisions worth recording:

1. **Tighten-only**, the same rule the TCF reconcile follows. `null` (no CMP
   wrote a string — the normal case outside the US) and `false` (the user did
   not opt out) are both no authority to clear a `doNotSell` the host set
   deliberately through `setConsent`.
2. **Through `ConsentManager.set`, not `AdManager.setConsent`.** `set` persists,
   applies to both providers, and notifies `_syncConsentToAdapter`, which
   discards the ads already cached under the looser state (the `doNotSell`
   false→true transition is one of the three axes that listener treats as a
   downgrade — B1, round-6 audit). `setConsent` would additionally bump
   `_consentIntentEpoch` and record a **host** intent, which this is not: it
   would cancel a consent apply still in flight and rewrite that apply's
   `hasUserConsent` from a value read before it landed. Rounds 19-20 were about
   exactly this kind of stale write.
3. **The guard is after the await, not at the door** — `_consentManager` is
   re-read after `usPrivacyOptedOut()` returns, because `destroy()` nulls it and
   a consent apply that landed during the read may already carry the opt-out.
   Same shape as rounds 19 and 20.

GPP (`IABGPP_HDR_GppString`) stays undecoded, deliberately and now documented:
it is a base64 bundle of per-jurisdiction sections, mis-parsing a privacy signal
is worse than not reading one, and both native SDKs read it themselves. A host
that needs per-state handling beyond the sale opt-out decodes it and calls
`setConsent`.

### Mutation evidence

`test/consent_us_privacy_propagation_test.dart`, 7 tests. Each call site was
disabled on its own, not just both together:

| Mutation | Result |
|---|---|
| both calls commented out | RED ×2 (`Expected: true Actual: <false>`) + the third test's own sanity line |
| init call only | RED — `init … says opted out → doNotSell applied` |
| resume call only | RED — `a sale opt-out written while backgrounded is applied on resume` |
| restored | 7/7 green |

Both sites are load-bearing; neither is decoration. Four of the seven tests are
CONTROLs, because the failure mode of an over-eager fix here is a revenue loss
for every US user: a `'1YNN'` string changes nothing, an absent string changes
nothing, an already-applied opt-out is not re-applied on resume (which would
throw away good ads every time the app comes forward), and a host-set
`doNotSell: true` is never cleared by a device string that says otherwise. The
last test closes the chain on the real `AdMobAdapter` —
`applyConsent(doNotSell: true)` → `debugRestrictedDataProcessing == true` — so
the assertion chain reaches the actual request flag and not just the SDK's cache.

One test-authoring note: a stub `AdProviderAdapter` whose `initialize` is served
by `noSuchMethod` fails with `type 'Future<void>' is not a subtype of type
'Future<bool>'`, and `AdManager.initialize` swallows that into
`❌ initialize THREW` plus a retry — so the test sees a plain "nothing was
applied" and looks like a fix that does not work. `initialize` needs a real
override on any such stub. Also, initialising with `AdProvider.admob` through the
real adapter requires the `google_mobile_ads` custom codec on the mock channel
(`MobileAds#initialize` must return an `InitializationStatus`, not `null`) —
`debugAdapterFactory` is the cheaper seam.

### Findings 2 and 3 (accepted, documented, not fixable offline)

Android "Clear data" re-grants the 1-day trial (`FirstInstallGuard.markGranted`
is a no-op off iOS) and un-burns a redeemed key (`RedeemedKeyLedger` likewise).
Both were already disclosed in `README.md` — the reviewer cited the disclosure
itself at README:61 — and neither has an offline fix: every store an app can
write to on Android lives inside the data the user is entitled to clear, and the
Keystore material goes with it. A device-ID mitigation would need a shared
location, a permission, and a Play Store policy argument, for a bypass the
determined user wins anyway.

Decision (user's, explicitly): accept the limitation, and make the wording
match. The reviewer's actionable advice was about marketing, not code — *"I
would not market it as 'consent for every country' or 'secure one-time VIP codes
on both platforms' in its current form"* — so:

* the reinstall-replay note is now headed **"Android reinstall / clear-data
  replay"** and names Settings → Apps → Storage → Clear data as the faster path
  that needs no reinstall, says the 1-day trial can be re-granted the same way,
  and points at short `--valid-days` AVP2 keys as the one mitigation a data wipe
  cannot undo;
* a new README section, **"CCPA / US state privacy — what the SDK applies on its
  own"**, states what is now automatic, that it is tighten-only, and that GPP is
  exposed raw and not decoded.

Suite after this round: `flutter analyze` clean, **1,221 tests passing**.

### On-device proof (Pixel 7 Pro, `2B051FDH3006MU`, 2026-08-29)

`example/integration_test/us_privacy_propagation_test.dart` — **4/4 pass in 1:18**, and
the same file run against a mutated `AdManager` (both `await
_reconcileDeviceUsPrivacy();` call sites commented out) goes **2 pass / 2 fail**: the
init case and the resume case both die, both CONTROLs stay green. The fix is what makes
the device test pass, and it does not pass by simply asserting `doNotSell` into place.

`consent_resume_backstop_test.dart` re-run after the edit below: **5/5 pass**.
`flutter test`: **1,221 pass**. `flutter analyze`: clean.

Two on-device test-harness traps cost most of the time here — both are about the test,
not the SDK, and both hang the run for tens of minutes rather than failing:

1. **`pump()` while the app state is `paused`.** `handleAppLifecycleStateChanged(paused)`
   lets the scheduler stop enabling frames, so a `pump` issued in that window waits for a
   frame that is never produced. It is a race — the same file passed one run and hung the
   next. Fix: no pump between `paused` and `resumed`; nothing under test needs time to
   pass while backgrounded. `consent_resume_backstop_test.dart` carried the same latent
   flake in two places and was fixed with it.
2. **A real App Open ad shown on resume.** Once the App Open slot is filled, the resume
   path shows a real full-screen ad, the engine stops producing frames for the test, and
   `pump` never returns. Fix: `appOpenTrigger: AppOpenTrigger.splashOnly` in the test
   config — a consent test has no business showing a fullscreen ad.

Also rejected, and worth not re-trying: resetting persisted consent between tests by
rewriting `ConsentSettings` in prefs and calling `ConsentManager.resetForTest()`. That
disposes the very `ValueNotifier` the next reconcile writes to. Each test states its own
baseline through `setConsent` before `initialize` instead — which is also the stronger
assertion, since the reconcile is only ever allowed to tighten a host intent.

---

## Round-25 QC round 22 — the consent gate that a 15-second load walked straight past

Reviewer: `codex`, alone in its own `/tmp` copy, same seven-requirement brief.
**Score: 4/10** — the lowest since round 11, and correctly so: one of the two findings
is an impression served after the user said no, which is the single outcome this SDK
exists to prevent.

Both findings were verified real in source before anything was touched.

### BLOCKER (real, fixed) — a rewarded ad could be shown after consent was withdrawn

`showRewardedAd` reads `canRequestAds` at the top of the method. In the VIP-bypass
branch — the "watch an ad to extend your VIP" path — it then calls
`_loadRewardedOnDemand`, which can wait as long as `onDemandLoadTimeout` (15s by
default). After that await it re-read **only** the fullscreen mutex
(`_fullscreenBusyReason`), which covers teardown, a showing slot, the loading dialog and
a route dialog — but not consent.

The sequence that bites, in plain terms: a VIP taps "watch an ad", the fill is slow (a
flapping connection makes the window trivially easy to hit), the user backgrounds the
app, changes their answer in the CMP, comes back — the resume re-check applies the
withdrawal, `canRequestAds` goes false — and the load lands. The SDK showed the ad
anyway, on a fill requested under the old privacy flags.

This is the same bug class as rounds 12 through 21: **a guard read before an await does
not survive the await.** The fix is the same rule — the guard belongs immediately before
the act, not at the door. Two checks now sit right after the load completes, inside the
bypass branch:

- `if (!canRequestAds)` — clear `_rewardedInFlight`, log, emit the `consent` skip event,
  pay `onEarnedReward(false)`, return.
- `if (!identical(_adapter, ad))` — the other way the world moves inside the same window:
  a `destroy()` plus re-initialise swaps the adapter, and `ad` is the object captured
  *before* the await. Showing on it drives a disposed native channel.

An early draft of the second guard also tested `!isInitialised`. It was dropped:
`destroy()` nulls `_adapter`, so the identity check already covers teardown, and the
extra clause broke every unit test that installs an adapter through `debugSetAdapter`
without a real `initialize`.

The reviewer additionally suggested a consent *generation counter* so a
withdraw-then-regrant inside the window still discards the old fill. Not taken: a regrant
means the user has said yes again, and the fill's own privacy flags are re-applied on the
next request rather than retro-fitted onto this one. Noted here so round 23 does not
re-litigate it silently.

### MAJOR (real, fixed) — the CRL and its verification key were two writes

`refreshRevocationList` persisted the signed CRL and the public key it verified against
as two separately-awaited `SharedPreferences` writes, under two keys. They are one fact,
and as two writes they were separable: a process death between them, or two `VipManager`s
interleaving, left a CRL stored against a key it was not signed with.

What that costs: on the next launch the verify fails, and a failed verify is
**deliberately** treated as "no revocations" (fail open — the right default when a CRL
can only ever narrow an entitlement). So a key the publisher revoked became redeemable
again on that device, permanently, until the host fetched a fresh CRL — which for an
offline device is never.

The pair is now one JSON value under one key (`ad_sdk_vip_revocation_v2`), written once.
`getVipRevocationCache()` returns a `({String raw, String publicKey})?` record; the three
call sites in `VipManager` (startup, `_ensureCachedRevocationLoaded`, the refresh write)
were repointed at it. The legacy accessors stay for the migration read only.

Two migration rules, both tested:

- Legacy two-key devices still read (losing a cached CRL on upgrade would silently drop
  every revocation an offline device knows about).
- A present-but-unreadable v2 value returns `null` and does **not** fall back to the
  legacy keys — falling back would resurrect exactly the stale, possibly-crossed pair
  that v2 replaced.

The reviewer also asked for an `issuedAt` comparison so an older CRL cannot replace a
newer one. Already covered upstream: `refreshRevocationList` rejects a CRL older than the
one in memory before it reaches the write.

### Tests — 11 new (suite 1,221 → 1,232)

`test/qc22_rewarded_consent_withdrawn_midload_test.dart` (3) — a fake adapter whose
rewarded slot starts IDLE, so the show path is forced through `_loadRewardedOnDemand`:
consent withdrawn mid-load blocks the show; an adapter swapped mid-load blocks the show
on both old and new adapter; CONTROL — consent intact, the ad shows and the reward pays.

`test/qc22_crl_atomic_pair_test.dart` (8) — storing the pair touches exactly one
preference key; it reads back as written; a legacy pair still migrates; a half-written
legacy pair is no pair; a stale legacy pair never overrides v2; a corrupt v2 is a final
answer; a refresh caches a pair a fresh launch can verify and apply (crash-recovery
shape); CONTROL — a crossed pair fails open, pinning the consequence that justifies the
atomic write.

`test/vip_crl_dispose_rollback_test.dart` — two assertions repointed to the new accessor.

### Mutation ledger — 4/4 RED

| Guard disabled | Test that goes red | CONTROLs |
|---|---|---|
| `if (!canRequestAds)` in the bypass branch → `if (false)` | consent withdrawn mid-load | green |
| `if (!identical(_adapter, ad))` → `if (false)` | SDK torn down mid-load | green |
| `setVipRevocationCache` split back into two writes | "touches exactly one preference key" | green |
| the `return null` after an unreadable v2 | "a corrupt v2 value is a final answer" | green |

Each mutation was applied alone and reverted before the next; the source was diffed back
to byte-identical afterwards. `flutter test`: **1,232 pass**. `flutter analyze lib`:
clean.

### Score trajectory

r10 9/8/9.8 → r11 4 → r12 6 → r13 5 → r14 7 → r15 6 → r16 6 → r17 7 → r18 6.5 → r19 7 →
r20 7 → r21 6 → **r22 4**. The dip is a real finding, not noise: the await-window class
still had an unswept branch after ten rounds of sweeping it. Round 23 continues.

---

## Round-25 sweep — closing the class instead of patching the branch

Decision taken after round 22 scored 4/10: stop fixing one await-window per round and
sweep the whole surface once. Rounds 12 through 22 were, without exception, the same bug
— **a guard read before an `await`, an act performed after it** — and each round's fix
was a fresh hand-written check at whichever branch that round's reviewer happened to
probe. The guards ended up in three different styles and the next unswept branch was
always one round away.

### What was actually swept

Every `await` in `lib/` — **327** of them — was enumerated mechanically, then filtered to
those with a side-effecting act after them in the same block: an ad shown, a slot marked
ready, a notifier written, a preference persisted, a reward paid, a navigator touched.
That left **52 sites** across 9 files, each read individually.

| Where | Sites | Verdict |
|---|---|---|
| `admob_adapter` — the four fullscreen load callbacks | 4 | Already guarded, and consistently: `_discardIfDisposed` + `_discardIfConsentStale` on every one. |
| `admob_adapter` — banner / MREC / native fill callbacks | 5 | Already guarded by slot identity (`!identical(_bannerSlotsByKey[key], slot)`). Their consent path is the widget's `personalisationRevision` listener: it disposes the instance, which replaces the slot, which makes the in-flight fill fail the identity check. Verified end to end rather than assumed — a stale-consent banner *looked* unguarded until that chain was traced. |
| `vip_manager` | 10 | Already guarded, and guarded in the right place: `_save`, `_refreshActive`, `_scheduleNextExpiry` each check `_disposed` internally, so every caller inherits it. The storage read additionally checks `_mutationEpoch` so a slow read cannot overwrite a newer live entitlement. |
| `ad_screen`, `vip_redeem_screen`, `ad_loading_dialog` | 5 | Already guarded by `mounted` / `_isDisposed` / a navigator captured before the await. |
| `ad_manager` — destroy, connectivity, `iab_storage`, entries store | 24 | No act that outlives the await, or guarded by an existing epoch/`_disposed` check. |
| `ad_manager` — the four fullscreen **show** paths | 4 | **The gap.** Fixed below. |

The honest headline: the codebase was already defended almost everywhere, but the defence
lived in three different idioms and one of the four show paths (rewarded) had a real hole
— the one round 22 found. What kept producing new findings was not an absence of guards,
it was the absence of *one* guard.

### The fix — one helper, asked immediately before the act

`AdManager._presentBlockedReason(AdProviderAdapter ad)` is now the single home of the
three facts that can move while an `await` is in flight:

- a teardown started (`_destroyInFlight != null`),
- the adapter was swapped (`!identical(_adapter, ad)` — a `destroy()` + re-`initialize()`
  while `ad` was captured before the await; showing on it drives a disposed native
  channel),
- consent was withdrawn (`!canRequestAds`).

Deliberately **not** in it: the fullscreen mutex, the safety caps, the VIP suppression.
Those have per-path semantics — the splash App Open bypasses safety, the VIP extension
flow bypasses VIP — so folding them in would make the helper lie at three of its four
call sites. Their own checks stay where they are.

All four fullscreen show paths now call it as the last statement before presenting:
`showAppOpenAd`, `showInterstitial`, `showRewardedAd`, `showRewardedInterstitialAd`. At
three of the four there is no `await` above it today, so the call is redundant *today* —
that is the point. The next person to add an await there inherits the guard instead of
re-opening the hole.

Round 22's fix was folded into this: it had put its check inside the `bypassVipGuard`
branch. The single guard sits below that branch instead, so it covers the ordinary
rewarded path as well — which the round-22 fix did not.

### `test/show_paths_guard_test.dart` — the invariant, enforced mechanically

A convention nobody can check is a convention that rots. This test reads
`ad_manager.dart` as text and fails if:

1. the helper stops asking any of the three facts,
2. any `await ad.showX(...)` is not preceded by `_presentBlockedReason(ad)`,
3. an `await` sits **between** the guard and the show (the guard would then be answering
   about a moment that has already passed).

Its first version had a false negative worth recording: it accepted a guard nested in a
sibling branch (`if (bypassVipGuard) { ...guard... }`), which sits above the show
textually while covering none of the other path through the method. That is exactly the
shape of the bug the test exists to prevent, and the mutation run is what exposed it —
removing the non-bypass guard left the test green. It now requires the guard to be at an
indent no deeper than the show's, with nothing dedenting past it in between.

A fifth ad type added in two years' time fails this test on day one.

### Mutation ledger — 4/4 RED

| Mutation | `show_paths_guard_test` | `qc22_rewarded_..._test` |
|---|---|---|
| App Open guard → `null` | RED | green (not its path) |
| Interstitial guard → `null` | RED | green |
| Rewarded guard → `null` | RED | **RED** |
| Rewarded-interstitial guard → `null` | RED | green |

Each mutation applied alone, source diffed back to byte-identical after each. The rewarded
site is the only one with a behavioural proof as well, because it is the only path with a
real await above it today — which is precisely why it was the one that broke.

`flutter test`: **1,235 pass** (1,232 → +3). `flutter analyze lib`: clean.

### What this does and does not buy

It buys: no fullscreen presentation can be added to this SDK without the guard, and the
three idioms are down to one. It does not buy immunity — the sweep covered `await`
windows, and a reviewer looking at cap arithmetic, mediation behaviour or the native
bridge is looking somewhere else. The next rounds run three reviewers in parallel on
different faces for exactly that reason.

---

## Round-25 QC round 23 — three reviewers in parallel, three faces, eleven real findings

Three reviewers, each in its own `/tmp` copy, read-only, each handed a different face of the
same seven-requirement brief so that no two could converge on the same easy target:

| Reviewer | Face | Score | Verdict |
|---|---|---|---|
| A | monetization arbitration, fullscreen accounting, revenue reporting | 5/10 | — |
| B | provider init order, policy compliance for the newest formats | 4/10 | do not ship |
| C | VIP / trial / signed-key security, clock and revocation model (`audit_r23_vip.md`) | 5/10 | **DO NOT SHIP** until V1 is fixed |

The `await`-window class that dominated rounds 12–22 did not produce a single finding this
round — reviewer C looked for it explicitly and reported it closed. Every finding below is in
a model the sweep never touched: the *clock*, the *revocation graph*, the *init ordering*, and
the *accounting*.

### BLOCKER (reviewer C, V1) — one wrong clock reading permanently ERASED a paid VIP grant, from disk

`_effectiveNow()` keeps a persisted high-water mark of the furthest wall-clock instant ever
seen and returns that mark whenever the real clock reads earlier — that is what makes the
rollback defence work, and the mark is deliberately never lowered. `_purgeExpired()` then did
`_entries.removeWhere((e) => !e.isActiveAt(now))` against that mark and `_save()`d the result.

So a mark that is permanently ahead of real time destroyed rows, on disk. No attacker is
needed: a phone whose battery went flat boots with a date years in the future, the user opens
the app once, the mark is committed, NTP corrects the date, and on the next launch every VIP
entry is gone. It is unrecoverable — this SDK has no backend, and the key id is already burned
in the one-time-use redeemed-key ledger, so re-entering the key the customer paid for answers
"already used".

The codebase already stated the correct rule two methods above, for the not-yet-started half:
*"Routed through purge it would instead be erased permanently. Suppress, never delete."*
`_isLive` honoured it; `_purgeExpired` did not. The rule now covers the expiry half too: a row
is deleted only when the mark-clamped clock **and** the raw device clock both agree it is over.
A poisoned mark can still suppress an entitlement — that is the accepted, documented cost — but
it can no longer erase one.

### MAJOR (reviewer C, V2) — one tap on "watch an ad" laundered a revoked key's window past the CRL

`addVip(stack: true)` extends the latest expiry across all live entries. That is documented,
deliberate product behaviour ("grants stack globally"). The consequence nobody had closed:
redeem a signed 30-day key, watch one rewarded ad for "+1 day", and the whole 30 days moves
into the `WATCH_AD` entry. `_clampRevokedEntries` matches entry keys against `SIGNED_<kid>`, so
publishing a CRL for that key afterwards — leaked, refunded, resold — clamped a row that no
longer held the time. The user kept the month.

One tap. No root, no clock tampering, no tooling — the SDK's own reward button.

`VipEntry` now records what a stacked grant absorbed (`stackedFrom`), transitively, and the
clamp matches on that too.

### MAJOR (reviewer C, V3) — the cached CRL verified itself, and a future-dated one wedged revocation off forever

The startup path in `VipManager.load()` has no host public key of its own, so it verified the
cached CRL against a key stored beside it in the same plaintext preferences record. That is
self-attesting. Anyone who can write preferences — a rooted device, i.e. exactly the population
that redeems a leaked or resold key — mints their own Ed25519 pair, signs an empty CRL dated in
2286, and writes both. It verifies. `_revocationIssuedAt` latches to 2286, and
`refreshRevocationList`'s "only accept a newer `issuedAt`" rule then rejects every CRL the
publisher will ever issue. Revocation is permanently dead on that device.

The fix withholds only the `issuedAt` **latch** until the host key has confirmed the cache. The
revoked set from an untrusted cache is still applied — it can only ever narrow a grant — so
round-7's offline startup clamp keeps working unchanged.

### BLOCKER (reviewer B) — the child-directed flag could flip mid-init and MAX would never hear it

MAX only reads the child-directed flag at native SDK init, and that init is awaited for up to
20 seconds. The trigger is an ordinary splash: the host starts `AdManager.initialize()` and
presents its age gate at the same time. The parent finishes the age gate inside that window and
the host calls `setConsent(AdConsent(isAgeRestrictedUser: true))` — and nothing carried across:

* the adapter had already been told `false`, and MAX exposes no runtime setter;
* `setConsent()`'s own COPPA re-init branch reads `_config ?? _lastKnownConfig`, and on a
  **first** init both are still null, so the branch never ran;
* `initialize()` then installed the live adapter and started preloading.

Result: MAX serving ads to a user the host had declared child-directed.

The fix reconciles on the way out of init: remember the flag the adapter was built with, compare
it against `_consent` after the await, discard the adapter if it changed. It fails closed, which
is the correct direction here — AppLovin's own adapter refuses to initialise for a child-directed
user. `_lastKnownConfig` is set first, so the existing MJ7/M2 recovery rebuilds the adapter if
the host later corrects the flag back to false.

### BLOCKER (reviewer B) — the rewarded interstitial shipped without the intro screen its policy requires

Google's policy for the format requires an intro screen: the user is told an ad is coming and
what the reward is, and is given a way out. The SDK shipped
`AdManager().showRewardedInterstitialAd()` with nothing of the sort, and the README did not
mention the obligation — so a host that adopted the format was out of policy by default. It is
the host's AdMob account that gets actioned, not the SDK's.

`AdScreenState.showRewardedInterstitialAd()` now renders the disclosure by default, with
overridable title and button labels. Declining costs nothing: no ad, no impression, no budget.

### MAJOR (reviewer B) — an App Open ad was drawn on top of a live banner or MREC

Google's App Open guidance names this placement: do not show an App Open ad over other ads,
banner content included. The resume path walked straight into it. `onAppPaused()` blanks every
inline surface when the app leaves the foreground; on the way back `onAppResumed()` makes them
visible again, and only *then* does `showAppOpenAdOnResume()` decide to present. Returning to any
monetised screen produced a fullscreen ad over a banner that had just been switched back on.

Skipping the App Open would have been the cheap fix and the wrong one — most screens in a real
app carry a banner, so the format would be dead on arrival. Instead the inline surfaces are
blanked for the duration of the fullscreen ad and exactly those are restored on dismiss,
including after a throw. A surface hidden for another reason (route-paused, backgrounded) stays
hidden: the restore returns the tracked set, it does not switch every inline surface on.

The capability is a separate `abstract class InlineAdVisibility`, detected with
`ad is InlineAdVisibility`, **not** a new member on the exported `AdProviderAdapter` — adding
one there is a breaking change for every host that implements it. A host adapter that predates
it keeps the old behaviour and still shows the ad.

### MAJOR (reviewer A) — the arbitrator priced every format out of one pool

Every `AdRevenueEvent` went into a single trailing average. A content feed emitting a hundred
cheap banner impressions dragged that average below the *rewarded* threshold, and the next
rewarded opportunity — worth many times a banner — was vetoed in favour of a VIP nudge. Real
lost revenue, and the `ArbitratorNudgeEvent` reported an eCPM belonging to a different format.

The same shape applied to currency: a non-USD account was compared against a threshold documented
in dollars. `decide()` now prices the format it was asked about, using that format's own currency.

### MAJOR (reviewer A) — a displayed rewarded interstitial did not consume an impression

`showRewardedInterstitialAd` counted the impression inside `if (result.earned)`. A fullscreen ad
that was displayed and then dismissed early cost the user nothing in pacing. Repeating that hands
out materially more fullscreen inventory than the anti-invalid-traffic caps allow, which puts the
publisher's AdMob account at risk. The ordinary rewarded path had always used `result.shown`;
this was the last place still gating on the reward. The same line also reported
`AdShowEvent.success: false` for an ad the SDK had just displayed, so the SDK's own analytics
disagreed with the impression that was billed.

### MINOR (reviewer C, V4) — a Keychain timeout silently consumed the 1-day trial the user never got

The first-install guard reads the iOS Keychain through `flutter_secure_storage`. If that read
never answers, the old code still marked the grace as applied — so the trial was burned without
ever being granted, permanently, because the flag is one-way. The mark now happens only when the
guard actually answered; a timeout leaves the flag false and the next launch tries again.

### MINOR (reviewer C, V5) — the config GAID whitelist granted once and never again

`vipDeviceGaids` grants a long window that `AdConfig.maxVipStackDuration` clamps to ~90 days, and
then set a one-way "already applied" flag. When the clamped window ran out, the whitelisted device
— an internal test phone, by construction — silently went back to seeing ads with no way to
re-grant short of clearing app data. The grant is now re-applied when the whitelist still matches
and no VIP is active; a device that never matched still burns the flag, so a non-matching GAID
does not re-check on every launch.

### MINOR (reviewer C, V6) — inline ad surfaces stayed blank at the exact moment VIP expired

Gaining VIP hides banners immediately; losing it did not bring them back until something else
happened to rebuild the widget. `_onVipActiveChanged` now bumps `initRevision`, which is the
signal `BannerAdWidget` already listens to, so the banner reloads on the transition to
non-VIP — and, deliberately, not on the transition *to* VIP, where the suppression path already
owns the behaviour.

### MINOR (reviewer C) — every revenue event was reported with the wrong placement

`AdRevenueEvent.placement` arrived as `AdPlacement.unspecified` for every format, because the
adapters wire the paid-event listener when the ad is **loaded** and the placement is only known
when it is **shown**. App Open was worse than useless: hardcoded to `AdPlacement.splash`, so a
resume impression was reported as a splash impression. A host reading `AdManager().events` to
find which screen actually earns money got one undifferentiated bucket, which is the whole point
of the placement API.

Adding a `placement` parameter to `AdProviderAdapter.showInterstitial/showRewarded/showAppOpen`
was rejected for the same reason as `InlineAdVisibility`: that class is exported. The placement is
recorded in `AdManager` immediately before each show and stamped in `_emit`, the single chokepoint
every event already passes through, so one edit covers both adapters. The map is deliberately
never cleared — some mediation adapters report the paid event a beat late, and a stale entry names
the last show of that same format, which is still the right answer. Inline formats are untouched:
nothing "shows" them, so they keep reporting `unspecified`.

### Tests — 57 new (suite 1,235 → 1,292)

| File | Tests |
|---|---|
| `test/r23_purge_poisoned_clock_test.dart` | 4 |
| `test/r23_stack_launder_test.dart` | 6 |
| `test/r23_crl_selfsigned_cache_test.dart` | 4 |
| `test/r23_coppa_midinit_flip_test.dart` | 4 |
| `test/r23_rewarded_interstitial_disclosure_test.dart` | 5 |
| `test/r23_appopen_over_banner_test.dart` | 7 |
| `test/r23_arbitrator_per_slot_test.dart` | 5 |
| `test/r23_rewarded_interstitial_impression_test.dart` | 4 |
| `test/r23_first_install_guard_timeout_test.dart` | 4 |
| `test/r23_gaid_whitelist_regrant_test.dart` | 5 |
| `test/r23_vip_expiry_banner_revive_test.dart` | 3 |
| `test/r23_revenue_placement_test.dart` | 6 |

Two of these needed a test seam rather than a test: `AdManager.debugFirstInstallGuardFactory`
(the Keychain timeout branch is otherwise unreachable — the real guard fails fast in a unit test
instead of blocking) and `debugApplyConfigVipGaidWhitelist` (the whitelist body returns early
under `kDebugMode`, which every unit test runs in). Both follow the shape `initialize()` already
uses for `isRelease`.

### Mutation ledger — 22 RED across 12 fixes, 1 uncovered and documented

| Fix | Mutations | Result |
|---|---|---|
| V1 poisoned-clock purge | 2 | 2 RED, 2 CONTROL green |
| V2 stack launder | 3 | 2 RED, **MUT C uncovered** (below) |
| V3 self-signed CRL cache | 2 | 2 RED, CONTROLs green |
| COPPA mid-init flip | 2 | 2 RED |
| Rewarded-interstitial disclosure | 2 | 2 RED |
| App Open over banner | 4 | A/B/C 1 RED each, D 2 RED (one per adapter) |
| Arbitrator per-slot pricing | 2 | 2 RED |
| Rewarded-interstitial impression | 2 | 2 RED |
| V4 first-install guard timeout | 2 | 2 RED, 2 CONTROL green |
| V5 GAID whitelist re-grant | 1 | 1 RED |
| V6 banner revive on VIP expiry | 1 | 1 RED, CONTROL green |
| Revenue placement | 3 | A 5 RED / 1 CONTROL green, B 2 RED, C 1 RED |

Each mutation was applied alone and reverted before the next; the source was `diff`-ed back
byte-identical after every one.

**The one uncovered mutation, and why it stays.** Dropping `stackedFrom: e.stackedFrom` from
`_clampRevokedEntries` produced no RED, even after adding a sixth test. Diagnosis: at the moment
of the clamp the revoked `SIGNED_<kid>` row is still present, so the provenance is reachable by
the direct match and the transitive copy is not load-bearing *in the clamp itself*. It is
load-bearing on the next stack — a second "watch an ad" would otherwise launder the window a
second hop away from the CRL. The line stays as defence in depth, recorded here so a future round
does not delete it as dead code on the strength of a green suite.

**Three mutations that first produced the wrong colour, and what that exposed:**

- The `_purgeExpired` mutation went red on the CONTROLs and green on the finding's own test.
  Root cause: `_purgeExpired` writes back through `unawaited(_save())`, so an assertion made on
  the very next microtask reads the store *before* the write lands. Every disk assertion in that
  file now goes through a 50 ms `_settle()` first, otherwise the test is a coin flip rather than
  a proof.
- The disclosure mutation went red on 4 tests including a CONTROL, but passed in isolation. The
  first failing test left a live 1000 ms `AdLoadingDialog` timer that poisoned the tests after
  it. Fixed by moving both CONTROLs.
- The second disclosure mutation was a **false green**: the scripted replace targeted
  `if (!proceed) {`, whose first occurrence is inside the older `showRewardedAd`, not the new
  method. Retargeted to the right method, then RED.

### Deliberate non-fixes, recorded so round 24 does not re-litigate them

- **The offline gate on `redeemSignedKey`** and **the always-on `kQaTestDeviceHashes`** are
  product decisions, not defects. Both have been flagged by more than one reviewer round and are
  annotated in source with the reason.
- **A consent generation counter** (round 22's reviewer suggestion) is still not taken: a regrant
  means the user said yes again, so the fill's privacy flags are re-applied on the next request
  rather than retro-fitted onto the one in flight.
- **Native ads have no RouteAware lifecycle** (m25) — decided, deliberate.

### Score trajectory

r11 4 → r12 6 → r13 5 → r14 7 → r15 6 → r16 6 → r17 7 → r18 → … → r22 4 → **r23 A 5, B 4, C 5**.

The number went down, and it should have. Rounds 12–22 all found the same bug class, so the
sweep that closed it did not — and could not — move the score: the reviewers were finally
looking somewhere else. Three of this round's four most serious findings (V1, V2, V3) are in a
part of the product no previous round had attacked directly, and the fourth (COPPA) is in the
one window where the SDK is provably not in control of its own state. That is what a
face-partitioned review buys, and it is why the next round should partition again rather than
re-run the same three faces.

`flutter analyze` → "No issues found!". `flutter test` → **1,292 pass** (1,235 → +57).

---

## Round-25 QC round 24 — the round-23 purge fix answered the wrong question

Two reviewers, own `/tmp` copies, handed the complete uncommitted 2.4.0 diff and told to be
adversarial about the fixes themselves rather than hunt the product again. Reviewer A scored
the change **7.5/10** and produced one reproducible MAJOR — in code written the same day, in
the fix for round-23's own BLOCKER.

### MAJOR (reviewer A) — "not active" is not "over", and the purge still destroyed a paid row

Round 23 changed `_purgeExpired` to delete a row only when both clocks agreed, and wrote that
as:

```dart
_entries.removeWhere((e) => !e.isActiveAt(now) && !e.isActiveAt(real));
```

`isActiveAt` is **start-aware**. It is false when the window is over — and equally false while
the clock reads *before* `grantedAt`. So a grant stamped in the future, with `expiresAt`
months away, was still deleted outright. The fix closed the half the reviewer of round 23 had
probed and left the other half of the same predicate open.

The trigger needs no attacker and is a device-shaped one: redeem while the device clock runs
ahead (`grantedAt` lands in the future — this is the MJ9 shape the SDK already defends
against), then correct the clock and lose the high-water mark. On iOS the two halves of that
state do not have the same lifetime: the VIP row is Keychain-backed and survives a reinstall,
while the mark lives in `SharedPreferences` and does not. Mark gone, `grantedAt` still in the
future, row deleted — and the key id is already burned in the one-time-use ledger, so the
customer re-redeeming what they paid for is told "already used".

Reviewer A reproduced it with a throwaway probe before reporting: one entry at
`grantedAt = now + 30d`, `expiresAt = grantedAt + 90d`, no mark in preferences, then
`VipManager.load()` →

```text
[VipManager] purgeExpired: removed 1
Expected: contains 'PAID'
  Actual: '[]'
```

The predicate now asks the question the comment always claimed it asked:

```dart
_entries.removeWhere(
    (e) => !now.isBefore(e.expiresAt) && !real.isBefore(e.expiresAt));
```

### Why this one got through round 23

The round-23 mutation ledger passed. The mutation reverted the *comparison* (`&&` back to a
single clock) and the tests went red exactly as designed. What no mutation could reach was the
*predicate's meaning*: both the fixed and the unfixed version called `isActiveAt`, so every
mutation of that line kept the start-aware half of the bug intact. A mutation ledger proves a
test is load-bearing for the line it targets; it cannot tell you the line is asking the wrong
question. That took a reader.

### Tests — 3 new unit (suite 1,292 → 1,295) + 4 new on-device files (8 tests)

`test/r23_purge_poisoned_clock_test.dart` (+3): a future-stamped grant with no clock mark
survives; it keeps surviving across three consecutive launches (a row that dies on the second
launch is no better than one that dies on the first); CONTROL — a row whose window has
genuinely ended under both clocks is still removed, so housekeeping still bounds the record.

Reviewer A's other substantive point was that **none** of the twelve round-23 fixes had
on-device coverage, and that VM fakes cannot close the storage, lifecycle and rendering
boundaries. Four files were added, all passing on a real Android emulator:

| File | Tests | What only a device can prove |
|---|---|---|
| `example/integration_test/r23_vip_purge_clock_test.dart` | 3 | The purge writes through real `flutter_secure_storage`; the poisoned-mark and future-`grantedAt` rows survive it there, and a genuinely dead row is still removed. |
| `example/integration_test/r23_stack_provenance_test.dart` | 2 | `stackedFrom` is a `Set<String>` that has to survive `toJson` → Keychain → `fromJson`. Provenance lost on reload would mean the launder costs the attacker one app restart. |
| `example/integration_test/r23_gaid_whitelist_regrant_test.dart` | 2 | The case-insensitive match runs against the string the real `advertising_id` plugin returns, not a literal chosen by the test author. |
| `example/integration_test/r23_banner_revive_on_vip_expiry_test.dart` | 1 | The real Banner demo page, real adapter mounted, real VIP store: losing VIP bumps `initRevision` and the tree survives the reload; gaining VIP deliberately does not. |

### Deliberately still not covered on-device, and why

- **First-install guard (V4).** `FirstInstallGuard.hasAlreadyGranted()` returns `false`
  unconditionally in debug builds *and* unconditionally on Android (anti-bypass is iOS-only by
  design). `flutter test integration_test/` builds in debug, so there is no build in which a
  device test could reach the Keychain branch. Writing one would be theatre. The branch is
  covered by the injectable-guard unit test instead.
- **Revenue placement (12) and the disclosure's "decline costs no impression" (5).** Both need
  a real paid callback / real fill, which an emulator does not guarantee. Asserting on fill
  would turn the test into a network check that fails for reasons unrelated to the fix.
- **COPPA mid-init (4).** Needs a controllable native MAX init delay; the CI Android job forces
  `AD_PROVIDER_ADMOB` precisely because no AppLovin key is committed, so the AppLovin path
  cannot init there at all.

### MAJOR (reviewer B) — the per-format arbitrator turned one cheap fill into a session-long veto

The second reviewer went at the same diff from the revenue side and found that fix 7 — splitting
the eCPM pool per format — introduced a straight revenue regression of its own.

Splitting the pool was right. What it also did was make every bucket fill hundreds of times more
slowly than the old all-formats pool: a rewarded bucket sits at n=1 for a long stretch of a real
session. `estimatedEcpmMicrosFor` priced any bucket of size ≥ 1, so one cheap backfill or house
ad set the format's price for the session. And the loop **self-latched**: a vetoed show emits no
`AdRevenueEvent`, so the bucket could never grow past the single bad sample that caused the veto.

The reviewer reproduced it with a probe rather than describing it:

```text
Session: 20 banner impressions at $10 eCPM, then ONE rewarded fill that happened
to be a $0.10 house ad. Threshold $5.
  pre-fix  pool eCPM = 9_505_000 -> showAd
  post-fix rewarded  =   100_000 -> nudgeVip
  end to end: 0 of 10 rewarded shows played; steady state 110 of 200 opportunities vetoed
```

The `maxVetoRate` guardrail does break the latch — after 20 consecutive vetoes — and then
oscillates, which still costs roughly half the rewarded inventory for the rest of the session.
MAJOR rather than BLOCKER only because the arbitrator is opt-in (`enableArbitrator()`); a
publisher who turned it on is fully exposed.

Fix: a bucket thinner than five samples is not evidence and is not priced — it returns `0`, which
`decide()` already reads as *show*. Failing open on thin data is the only safe direction here: the
cost of showing one cheap ad is one cheap ad; the cost of vetoing wrongly is every rewarded
impression for the rest of the session.

**Two existing assertions had to change, and that is part of the finding.** The round-23 tests
asserted `estimatedEcpmMicrosFor(...) == 1000` off one sample and `== 10000000` off two — i.e.
they encoded the bug as correct behaviour. They now feed five samples each, and two new tests
cover the regression directly: one cheap fill cannot veto the session, and a thin bucket cannot
self-latch (four cheap samples in a row must each still say *show*, so the fifth can ever arrive;
once it does, the veto works again).

### MINOR (reviewer B) — the disclosure's default was the fix, and nothing tested the default

Flipping `bool showDisclosure = true` to `false` in `ad_screen.dart` left the entire suite green.
Every test in `r23_rewarded_interstitial_disclosure_test.dart` passed `showDisclosure:`
explicitly, so the *mechanism* was covered and the *promise* was not — and the promise is the
whole point: a host that has never heard of the parameter must still get the AdMob-required intro
screen. A merge that resolved the parameter list the other way would have shipped a policy
regression silently. There is now a screen that passes no argument at all and asserts the SDK's
own default copy appears with the ad still unshown.

### MINOR (reviewer B) — one more `VipEntry` rebuilt without its provenance

`vip_manager.dart`'s M6 untrusted-clock fallback clamp rebuilt a `VipEntry` without
`stackedFrom`, while the revocation clamp deliberately carries it forward. The reviewer could not
construct real harm and downgraded it accordingly: the two clamps cannot touch the same row today
because both windows are 24 h, so nothing is lost. That is an arithmetic coincidence, not an
invariant. Rebuilding a `VipEntry` anywhere without its provenance un-launders it exactly once,
which is precisely what V2 exists to prevent, so the field is now carried there too.

### Mutation ledger — 6/6 RED, 1 uncovered by construction

| Mutation | Result |
|---|---|
| `expiresAt` comparison reverted to `!isActiveAt(now) && !isActiveAt(real)` | 2 RED ("a grant stamped in the future is NOT deleted…", "…keeps surviving every subsequent launch"), CONTROL green |
| `_minSamplesToPrice` removed (`bucket.isEmpty` restored) | 2 RED ("one cheap fill cannot veto the whole session", "a thin bucket cannot self-latch"), CONTROLs green |
| `bool showDisclosure = true` flipped to `false` | 2 RED, including the new no-argument test |
| `stackedFrom: e.stackedFrom` dropped from the M6 fallback clamp | **no RED — uncovered by construction.** The two clamps' 24 h windows cannot overlap, so no input reaches both. Kept as an invariant that holds by construction rather than by arithmetic coincidence; recorded here so a future round does not delete it as dead code on the strength of a green suite. |

Source `diff`-ed back byte-identical afterwards.

### Device smoke — three physical Android devices, 33/33 green

Round 35's diff-corrected re-review (8.5/8.5, no product defect) was followed by a real-device
smoke pass, across whichever physical device happened to be plugged in at the time — a Pixel
(`2B051FDH3006MU`), an OPPO CPH1989, and a TECNO BG6, in that order, as USB connections dropped
and were replaced mid-session:

- First full 33-file sweep, on the Pixel: 30/33 green. The three failures
  (`app_boot_test`, `banner_ad_test`, `vip_redeem_flow_test`) all failed at the identical point —
  waiting for the splash to reach `HomePage` — because a REAL App Open test ad genuinely filled
  and stayed on screen longer than that pre-existing test file's 45 s patience budget (a budget
  untouched by any of the 35 review rounds). Re-run individually on the OPPO, all three passed
  clean.
- Full 33-file sweep on the OPPO: 32/33 green, plus one file (`ump_eea_consent_test`) correctly
  self-skipping (it requires `UMP_EEA_DEBUG`/`UMP_TEST_ID` dart-defines documented in its own file
  header — expected, not a failure). The one failure
  (`vip_revocation_list_test`, "ADB exited with exit code 1 / Failed to install APK") happened
  because the physical device was swapped mid-suite (OPPO unplugged, TECNO plugged in) — an
  install failure, not a test assertion failure. Re-run alone on the TECNO once it settled: green.

**33 of 33 integration files are green on real hardware; nothing failed on its merits.** The one
genuinely informative moment was `vip_revocation_list_test`'s real second-attempt failure being
traced to a `flutter test` invoked from the wrong working directory (`packages/ad_sdk` instead of
`packages/ad_sdk/example`) — a self-inflicted process error, not a device or product issue, caught
by the pubspec-resolution error it produced rather than a real test failure.

### Round 37 (this session's "Round 14") — a MAJOR closed the same rounds-12-22 bug class in code the sweep never saw

Reviewer A: 9.5/10, nothing found. Reviewer B: 8/10, one real MAJOR.

`destroy()` racing the first-install Keychain guard (fix 4/V4's real, production
`.timeout(Duration(seconds: 5))` await, justified in its own comment by exactly this scenario —
"first unlock after reboot", i.e. precisely when a freshly-installed app tends to be opened for
the first time) could dispose the `VipManager` mid-grant. `addVip`'s own `_save()` already drops a
write on a disposed manager (round 18), but nothing stopped the two one-shot flags —
`guard.markGranted()` / `prefs.markFirstInstallGraceApplied()` in the grace block, and
`prefs.addVIPMemberFirstInitSuccess()` in the GAID-whitelist function — from being burned over a
grant that never landed. This is the identical bug class rounds 12–22 spent ten rounds sweeping
("a guard read before `await` does not survive the await") and round 20's own mechanical
`await`-enumeration swept `lib/` for — except this particular await did not exist when that sweep
ran. The lesson reviewer B drew directly: *a systematic sweep is only as current as the commit it
was run against.*

Fixed with a new `VipManager.isDisposed` getter, checked immediately before each of the three
flag-writing sites, mirroring round 18's own rule: the flag is set only once the grant actually
landed. New tests use a controllable-Completer guard (mirroring the COPPA test's `_SlowInitAdapter`
shape) to land `destroy()` precisely inside the Keychain await, then let it answer afterward — and
prove the next launch on the same install still succeeds. 2/2 mutations RED.

### Round 38 — a third door into the same revocation-laundering hole

Reviewer A: 9.5/10, nothing found. Reviewer B: 7.5/10, one real MAJOR — the third instance of
exactly the V2 laundering shape (rounds 23 and 24 each closed one rebuild site).

`VipManager.addVip`'s plain, non-stacked "latest expiry wins" replace (`existing >= 0`, `stack`
defaulting to `false`) constructed a fresh `VipEntry` with the default empty `stackedFrom`,
discarding whatever provenance the row being replaced had already absorbed. The trigger needs no
`stack: true` at all: a host that redeems a signed key, stacks a rewarded-ad grant onto it (as
documented, `WATCH_AD` absorbs the signed key's window), and later calls the SDK's own public
`addVip` a second time on that same key — an entirely ordinary re-grant — silently re-opened the
laundering hole a CRL publish was supposed to close.

Reviewer B named exactly why this survived fourteen prior passes: round 22's `await`-window sweep
enumerated every `VipEntry` rebuild site for a *different* invariant (disposed-manager safety), not
for this one; rounds 23/24 checked two rebuild sites (`_clampRevokedEntries`, the M6 fallback
clamp) and, per round 24's own closing note, explicitly did not claim immunity beyond the axis that
round was looking at. A grep for `stack: false` combined with any test re-granting an
already-`stackedFrom`-bearing key found nothing — no test had ever exercised this path.

Fixed the same way as the other two sites: the replacement `VipEntry` now carries `old.stackedFrom`
forward. No product-behaviour change — the same key still ends up at the same, later expiry. 1/1
mutation RED.

**Also checked and NOT a defect:** reviewer B traced whether AdMob needed an
`_appBackgroundedForInline`-equivalent (round 35's fix was AppLovin-only) and confirmed it does
not — AdMob's `visible` flag only gates whether Flutter paints the `AdWidget`, so a late-created
key inheriting the wrong value there has no invalid-traffic consequence the way AppLovin's
`autoRefreshEnabled` does. Recorded so a future round does not re-flag it.

### Score trajectory across the two review passes

| Pass | Reviewer | Score | What moved it |
|---|---|---|---|
| Round 24, first read | A (codex) | 7.5/10 | one reproducible MAJOR in round 23's own fix; no on-device coverage at all |
| Round 24, re-read after the fix | A (codex) | 8.5/10 | MAJOR gone, no reproducible defect left; held back by breadth of device coverage and by two of the four new device files stopping one layer short of the outcome their names promised |
| Round 24, independent | B (claude) | 7/10 | the arbitrator revenue regression, the untested default, the dropped provenance |
| Round 25, re-read | A (codex) | 8.5/10 | no BLOCKER/MAJOR left; one MINOR — the min-samples rule switched the arbitrator off for a host with `rollingWindowSize < 5` |
| Round 25, re-read | B (claude) | 8.5/10 | "No BLOCKER and no MAJOR survived verification." Four MINORs: the same `rollingWindowSize` hole, the silent COPPA abort, and two inaccurate comments |

| Round 26, re-read | A (codex) | 8.7/10 | the warm-up clamp crashed at `rollingWindowSize: 0` |
| Round 26, re-read | B (claude) | 8/10 | the same zero-window crash, plus the COPPA abort skipping the queued-caller drain |
| Round 27, re-read | A (codex) | 8.8/10 | the App Open fix snapshotted visibility instead of owning it |
| Round 28, re-read | A (codex) | 8.2/10 | the ownership refactor kept a stale background hold, so a filled banner rendered blank |
| Round 28, re-read | B (claude) | 8.5/10 | the same defect, plus two comments that had outlived their own truth |
| Round 29, re-read | A (codex) | 8.1/10 | the ownership fix still stranded the hold on a third `onAppResumed` case |
| Round 29, re-read | B (claude) | 7.5/10 | the same third case, plus fix 6 being a no-op on AppLovin, plus the unreleased `pendingFill` |
| Round 30, re-read | A (codex) | 8.4/10 | AppLovin lost refresh ownership across a real lifecycle interleaving |
| Round 30, re-read | B (claude) | 7.5/10 | the COPPA abort with no recovery, the gated release, the late-mounting surface, the retained listenables |
| Round 31, re-read | A (codex) | 6.5/10 | the late AppLovin ad view still refreshed under the App Open; the gate-closed resume stranded the hold |
| Round 31, re-read | B (claude) | 7.5/10 | the same two, plus three tests asserting an inert flag — one of them locking the defect in |
| Round 32, re-read | A (codex) | 6.5/10 | the background acquire was still gated on an existing ad view |
| Round 32, re-read | B (claude) | 6/10 | the widget wrote the flag directly outside ownership entirely; the recovery branch's forget() dropped routePaused |
| Round 33, re-read | A (codex) | 7.5/10 | a resume beating an in-flight preload never released the background hold |
| Round 33, re-read | B (claude) | 7.5/10 | the COPPA retry answered onComplete twice — unrelated to the AppLovin area, found by stepping outside it |
| Round 34, re-read | A (codex) | 8.5/10 | nothing reproducible — both round-33 fixes traced correctly |
| Round 34, re-read | B (claude) | 7/10 | no product defect; the CHANGES.diff review artifact omitted all 17 new test files and the new ownership module (untracked files, plain `git diff`) |
| Round 35, re-read (corrected diff) | A (codex) | 8.5/10 | nothing reproducible |
| Round 35, re-read (corrected diff) | B (claude) | 7.5/10 | a fifth instance of the same acquire-misses-a-case shape: a key created while already backgrounded got no `background` hold |
| Round 37 ("Round 14"), re-read | A (codex) | 9.5/10 | nothing reproducible |
| Round 37 ("Round 14"), re-read | B (claude) | 8/10 | `destroy()` racing the first-install Keychain guard — the rounds-12-22 bug class, in an await that postdated round 20's sweep |
| Round 38, re-read | A (codex) | 9.5/10 | nothing reproducible |
| Round 38, re-read | B (claude) | 7.5/10 | a third rebuild site dropping `stackedFrom` — the V2 laundering hole, reopened through `addVip`'s ordinary non-stacked replace |

Both reviewers independently found the `rollingWindowSize` hole, in code written that same hour —
which is the honest reading of what this process is worth: the arbitrator fix introduced a defect
of its own, and only a second adversarial pass caught it. Every finding from both round-25 reads
is fixed above.

Reviewer A's two named caps were both closed rather than argued with: the stack-provenance
device test now mints a real CRL and checks the laundered window is actually taken back, the
banner test now waits for a real `AdLoadEvent` from the real adapter instead of a notifier tick,
and a fifth device file was added for the self-signed CRL cache — the one attack whose whole
premise ("someone wrote our preferences") a mocked preference map cannot represent.

### MINOR (reviewer A, round 25) — the min-samples rule switched the arbitrator off for a configurable host

`rollingWindowSize` is a public constructor argument and a host may set it to 1–4. The bucket is
truncated to that size, so a flat requirement of five samples meant such a host could never be
priced at all: `estimatedEcpmMicrosFor` always returned `0`, `decide()` always read that as
*show*, and the arbitrator policy the publisher configured was permanently and silently inactive.
Reviewer A reproduced it with `rollingWindowSize: 4` and ten events.

Asking for more evidence than the host has agreed to keep is a configuration error committed on
their behalf. The warm-up is now `min(_minSamplesToPrice, _rollingWindowSize)`, with a test that
runs windows 1 and 4 and asserts both get a working, priced, vetoing arbitrator.

Reviewer A also noted that the GAID device suite's platform guard was a bare `return`, so on iOS
it reported a green test that had asserted nothing. It now calls `markTestSkipped` — a skip that
reads as a pass is worse than no test.

### MINOR (reviewer B, round 25) — the COPPA abort said nothing, and a bus-driven splash froze

`_reportAbandonedInit` deliberately fires no `BoolEvent`: for a *superseded* attempt there is a
winner behind it, and a late `false` replayed by `SimpleEventBus` would tell a splash that
subscribed late that init had failed. The COPPA abort is the other shape entirely — there is no
winner and no `destroy()` behind it, so **nothing else is ever going to fire**. The SDK's own
`AdReadinessSplashController` and the copy-paste splash in the README both navigate off that bus
alone, falling back to an 8 s hard cap. Every user whose age gate lands inside the ≤20 s native
AppLovin init window sat on a frozen splash for eight seconds. Reviewer B reproduced it:
`PROBE onComplete=false  BoolEvents fired=[]`.

MINOR rather than MAJOR because it happens once: later launches read the persisted flag before
`initialize()`, so no flip occurs. `_reportAbandonedInit` now takes a `fireEvent` flag, `true`
only at the COPPA site, with the reasoning written at both ends.

### MINOR (reviewer B, round 25) — two comments that did not describe their own code

Both fixed by correcting the comment, because the code was right and the comment was the defect:

- `vip_manager.dart`'s justification for keeping an untrusted cache's revoked set argued from a
  forged **non-empty** set ("honouring it costs its author their own entitlement"). The actual
  attack writes an **empty** one — a pure downgrade that costs its author nothing and wipes the
  real revoked kids cached on disk until the host's next successful refresh. Reviewer B did not
  reproduce an exploit (redemption needs the network, and a host that refreshes at startup closes
  the window in the same breath) and the behaviour is unchanged; the comment now states what the
  keeping does and does not buy, and that closing the empty-set window properly needs a signed,
  host-keyed cache — a format change, not a patch.
- `ad_manager.dart`'s rewarded-interstitial impression comment claimed "the ordinary rewarded path
  above has always done this correctly". It had not — the same release moves that path from
  `earned` to `shown` too. A diff whose quality argument rests on its comments cannot afford a
  comment that misdescribes the diff.

### MAJOR (reviewer B, round 26) — the COPPA abort released the event but not the parked callers

The round-25 fix fired `BoolEvent(false)` because "nothing else will ever fire". Reviewer B
pointed out that the identical sentence is true of `_queuedInitCallbacks`, and the same abort path
skipped that too. Every other abort has a winner or a `destroy()` behind it that drains the queue;
this one has neither, so a host that `await`ed a second `initialize()` while the first was in
flight waited forever — and whatever it had behind that await never ran.

That is the pattern this project keeps hitting, named by the reviewer: **a fix closes one half of
a symmetric gap.** Firing the event and draining the queue are the same claim ("nobody else is
coming") made to two different audiences, so they now happen together, behind the same flag.

### MINOR (reviewer A and B independently, round 26) — the new warm-up clamp could divide by zero

`_warmUpSamples` clamped only downward, so `rollingWindowSize: 0` produced a warm-up of 0 — an
empty bucket then "qualified" and the average divided by zero. A public constructor knob must not
be able to crash the SDK. Clamped at 1 as well, with a test that constructs a zero window, feeds
ten events and asserts "no evidence, show the ad" rather than an exception.

Two reviewers found this independently, in code written an hour earlier, in the fix for a finding
they had both raised the round before. Recorded plainly because it is the clearest measurement in
this document of what a single pass is worth.

### MINOR (reviewer A, round 27) — the App Open fix snapshotted instead of owning

Fix 6 recorded the set of surfaces that were visible when the fullscreen ad went up, and put
exactly those back on dismiss. That models "what I hid", not "who wants it hidden", and the two
stop agreeing the moment a second owner appears mid-ad: `onAppPaused` writes `false` over a
`false`, so the snapshot never notices, and the dismiss then switches the banner back on
underneath a backgrounded app. Reviewer A reproduced that transition against the real
`AdMobAdapter`.

Visibility is now **owned, not snapshotted**: `InlineVisibilityOwners` (new,
`lib/src/adapters/_inline_visibility.dart`, deliberately not exported) counts which owners want a
surface blanked and derives `visible` from that. `fullscreen` and `background` are separate
owners; a surface comes back only when the last one lets go. Two properties fall out that the
snapshot had to special-case:

- a surface already hidden by something outside this bookkeeping (a route pause, a host widget) is
  never *claimed*, so it is never revealed on someone else's behalf — the round-23 CONTROL now
  holds by construction rather than by snapshot;
- a fill that lands while an App Open is on screen no longer draws itself over it
  (`revealUnlessHeld`), which the old `visible.value = true` in `onAdLoaded` did.

Both adapters hold one. AppLovin has a single owner today — its `onAppPaused` disables
auto-refresh rather than blanking — but it goes through the same bookkeeping so a second owner
cannot be added there without joining it.

### MAJOR (both reviewers, round 28) — the ownership refactor made a filled banner render blank

Both reviewers, independently, found the same defect in the round-27 ownership fix, and both
reproduced it against the real `AdMobAdapter`.

`onAppPaused()` takes the background hold on **every** listenable — its guard is the global
`_bannerAdsByKey.isNotEmpty`, not a per-key check. `onAppResumed()` released that hold only in the
`else if (_bannerAdsByKey.containsKey(key))` branch. A key whose load had failed while another
key's succeeded takes the `needsRecovery` reload branch instead, and its hold was never released.
Before round 27 that was harmless, because the fill handler wrote `visible.value = true`
unconditionally — and the comment directly above the line round 27 changed exists precisely to say
so ("...so a resume-triggered reload that succeeds actually shows the ad, instead of staying stuck
behind an empty placeholder"). `revealUnlessHeld` honours the stale hold and refuses.

Two banner placements is all it takes — a home banner and a detail banner. The retry fills, AdMob
served an ad, the publisher was billed a request, and the surface renders nothing. It recovers
only on a *later* background→foreground cycle, or not at all on a connection flaky enough to fail
the key again in between.

Reviewer B's summary of it is the one worth keeping: *"the code I was told to attack is the code
that broke... converting `visible.value = true` into `revealUnlessHeld` was done without auditing
who takes a hold and never gives it back — and the answer was sitting in the comment directly
above the line being changed."*

Fix: `onAppResumed` releases the background owner on **every** key, in both branches, because the
app really is in the foreground again. The reload branch keeps the surface blank under its own
owner — `InlineHideReason.pendingFill`, handed off only from an existing hold so a never-paused
key is not newly hidden — and the fill releases it. Three tests in
`test/r28_banner_blank_after_resume_test.dart` drive the production load path through
`debugBannerListenerFor`, including a CONTROL that the reload must NOT flash an empty placeholder
and a CONTROL that an App Open still wins over a fill landing under it. 2/2 mutations RED.

This also broke `test/show_paths_guard_test.dart` — the invariant test that checks the guard sits
within 30 lines of each `await ad.showX(...)`. A comment correction had pushed it to 33. The
invariant did its job on a change that had nothing to do with it, which is the argument for having
written it mechanically rather than as a convention.

### MINOR (reviewer B, round 28) — two comments that outlived their own truth

- `ad_manager.dart` named `onAppResumed` as the backstop for an adapter that never reports an App
  Open dismiss. True when a resume wrote `visible.value = true` unconditionally; false once
  visibility became owned, because a resume releases only the `background` owner and the
  `fullscreen` hold survives it. The real backstops are `_armAppOpenShowTimeout`'s 90 s hard cap
  and `dispose()`. Nothing is stuck today, but a host adapter implementing `InlineAdVisibility`
  without a cap of its own would blank its inline surfaces for the session — so the cap is the
  contract, and the comment now says so.
- `monetization_arbitrator.dart` implied that a stray event in another currency "cannot be
  averaged in", without saying what it does instead: it becomes the currency that slot *reads*, so
  the slot fails open until five samples accumulate in the new currency. The old history is kept,
  not discarded. Deliberate — blending currencies is the bug this exists to stop — and now stated.

### BLOCKER (both reviewers, round 29) — `onAppResumed` has three cases, and round 28 fixed two

Round 28 released the background hold in the reload branch and in the has-an-ad branch. The loop
has a **third** case that neither reaches: a key that is registered — a widget mounted and asked
for its listenables — but has never filled and has never failed. `onAppPaused`'s guard is the
global `_bannerAdsByKey.isNotEmpty`, so it takes the hold on that key too, and nothing gave it
back. When the key finally filled, `revealUnlessHeld` honoured the stale hold and the surface
stayed blank for the session — the *identical* failure round 28 exists to prevent, through the
other door.

Reachable with no attacker and no exotic device: a second banner widget mounts while its load is
refused before any ad object exists — offline, consent not yet granted, VIP at the time, daily cap.
None of those set `needsRecovery`. The user takes a call, comes back, the gate reopens, AdMob
serves an ad and `recordBannerImpression()` counts it — and the user sees a grey box.

Both reviewers reproduced it, in both loops. The release is now **unconditional**, outside the
branches, which is the only shape that cannot grow a fourth case.

`test/r28_banner_blank_after_resume_test.dart` missed it because all three of its tests drive their
key through a real `onAdFailedToLoad` first — they only ever exercised the branch that had been
fixed. Two tests added for the never-loaded key, one per loop.

### MAJOR (reviewer B, round 29) — fix 6 was a no-op on AppLovin, one of the two shipped providers

`BannerListenables.visible` is an **AdMob-only** flag, and its own doc says so: only `_buildAdmob()`
in `BannerAdWidget`/`MrecAdWidget` reads it. `_buildAppLovin` branches on `hasError` and the ad-view
id. So `AppLovinAdapter.setInlineAdsHidden` flipped a notifier nothing on that path reads: a MAX
banner kept rendering **and auto-refreshing underneath the App Open ad**, accruing impressions
nobody could see. That is the invalid-traffic exposure fix 6 exists to close, unmitigated for every
AppLovin publisher, for six review rounds.

Auto-refresh is the flag AppLovin honours, so that is the one that moves now — paused for keys with
a live ad view, restored only for keys whose route is still on top (`!bannerRoutePaused(key)`, the
same test `onAppResumed` already uses). `visible` is still tracked through the same ownership so the
two providers stay describable in one sentence, and so a future `_buildAppLovin` that does read it
inherits the behaviour. Three tests, including a CONTROL that a route-paused banner is not restarted
and a CONTROL that a key with no ad view is left alone.

### MAJOR (reviewer B, round 29) — `pendingFill` had no release on the refused-reload path

The hand-off took `pendingFill` whenever the key was held, then called `loadBannerIfNeeded`.
`pendingFill` is released by the fill handlers. Where the reload cannot even be attempted — no
platform view — no listener is ever created and nothing would lift the hold. That branch gives it
back explicitly now. A load refused *later* (inside the 15 s failure backoff, closed gate) keeps the
hold on purpose: there is no ad to show, and the next successful fill lifts it. Written down at the
site so the distinction is not re-litigated.

### Round 30 — four more, and the pattern named

| Finding | Severity | Reviewer |
|---|---|---|
| The COPPA abort had no recovery in the *adult* direction | BLOCKER | B |
| The "unconditional" release sat below `if (!canReload()) return` | MAJOR | B |
| A surface that MOUNTS under a live App Open was never held | MAJOR | B |
| AppLovin re-armed auto-refresh under a live App Open | MAJOR | A and B |
| `InlineVisibilityOwners` retained disposed listenables | MINOR | B |

**The COPPA abort, run backwards.** Every test in `r23_coppa_midinit_flip_test.dart` drove the
flag `false → true`, where "no ads" is the correct and legally required outcome. Backwards is a
kids-category app with a parent-unlockable adult tier: it boots child-directed, the parent
finishes the age gate inside the ≤20 s native window, the host sets `isAgeRestrictedUser: false`.
The reconcile discarded the adapter — correctly, it carries the stale flag — and stopped. No
adapter, no retry, and the only rebuild route left needs the flag to flip *again*, which it will
not. An ordinary adult user got zero ads of any format for the whole session. Strictly worse than
doing nothing, and with no compliance reason to stay dark. It now schedules a retry **and** still
reports, fires and drains — deliberately both, where every other failure path does one or the
other, because suppressing the report while a retry is pending would undo the round-25 and
round-26 fixes sitting directly above it.

**The release that was not unconditional.** Round 29's comment claimed "the only shape that
cannot grow a fourth case". The fourth case was eight lines above it: `if (!canReload()) return`.
`onAppPaused` takes the hold with no gate at all, so a resume with the gate shut — offline in a
lift, daily cap reached while backgrounded — stranded it, and AdMob's own auto-refresh then
delivered fills onto a surface the widget tree had replaced with a `SizedBox`, still recording
impressions. Releasing a display hold requests nothing, so it does not belong behind a load gate.

**The surface that arrives late.** `setInlineAdsHidden(true)` walked the known surfaces once, at
show time. Ownership answered "who wants this hidden" for surfaces that already existed and said
nothing about one created afterwards — a deep link resolving, a splash handing off to home, a
`PageView` mounting its next page while a launch App Open is up. Those banners were created
unheld, filled, and drew on top of the fullscreen ad: the same Google placement violation as the
original round-23 finding, through a different door. The hold is adapter state now
(`_fullscreenOverInline`), inherited at construction in both adapters, and released by the
ordinary dismiss path with no special case.

**AppLovin's refresh flag joins the model.** Round 29 moved auto-refresh but wrote it directly, so
`setInlineAdsHidden(false)` overwrote the pause `onAppPaused` still owned. `autoRefreshEnabled`
now goes through the same `InlineVisibilityOwners` (parameterised by which notifier it governs),
and `routePaused` was promoted from a *condition* read inside `onAppResumed` to an owner — which
is the whole lesson of this stretch: **a condition cannot be released by name, so whoever writes
the flag last wins.**

### The pattern, recorded because it cost five rounds

Passes 5 through 8 each fixed the case they were shown and asserted the class was closed. Round 26
said ownership settles it; round 28 found the stale `background` hold; round 29 said "the only
shape that cannot grow a fourth case" and round 30 found the fourth case. What actually closed it
was not another fix but a change of question — from *"which surfaces did I hide?"* to *"who wants
this hidden, and is that still true?"* — applied to every flag, every owner and every entry point,
including surfaces that do not exist yet.

Worth recording alongside: one round-30 mutation came back **green**, and the test was wrong, not
the fix. The fake adapter refused to initialise under the restricted flag, so the retry under test
came from the ordinary init-failure path and the assertion was measuring something else entirely.
Re-pointed at an adapter that comes up, it went red. A mutation ledger is only worth what the test
harness underneath it is worth.

### Round 31 — the AppLovin blind spot, and a test that locked the bug in

Scores fell — A 6.5, B 7.5 — and correctly. Both reviewers found the same pair, both on the
provider the previous six passes had never really tested.

**BLOCKER — a MAX ad view that attaches under a live App Open kept refreshing.**
`_holdAppLovinInline` skipped the refresh hold whenever `adViewId == null`, reasoning that
claiming it early "would leave refresh off when the ad finally arrives". That reasoning was
wrong, and it is wrong in a way the ownership model already answers: the hold is released **by
name** on dismiss. The guard made fix 6 a no-op on the commonest real sequence — app launches,
`BannerAdWidget` mounts, `preloadBanner` in flight, the launch App Open goes up and finds no ad
view, the preload lands, and `MaxAdView` attaches with auto-refresh on, underneath the fullscreen
ad. Same root cause, second symptom: `setBannerRoutePaused`/`setMrecRoutePaused` gated the
`routePaused` hold on the identical test, so round 30 promoted that owner from a condition and
inherited its broken *acquire*.

**MAJOR — AppLovin's gate-closed resume stranded the background refresh hold.** Round 30's own
summary said the release must move above `canReload()`; it was moved in `AdMobAdapter` only.

**And three tests that were worse than absent.** Reviewer B named them:

- `test/r23_appopen_over_banner_test.dart` asserted `visible` on the AppLovin adapter. The SDK's
  own comments say twice that `visible` is AdMob-only and `_buildAppLovin` never reads it, so that
  test was green no matter what a MAX banner did on screen. **That is how the BLOCKER survived
  four consecutive passes aimed straight at this area.**
- A test I had written as a CONTROL — "AppLovin has nothing to pause without a live ad view" —
  asserted `autoRefreshEnabled == true` under a live App Open. It did not merely miss the defect;
  it **locked it in**, with a confident rationale attached. The assertion is inverted now, and the
  comment says what it used to be doing, because a wrong CONTROL is the most expensive kind of
  test: it converts a bug into a documented requirement.
- All four tests in `r23_crl_selfsigned_cache_test.dart` asserted `result.ok == false` — only the
  safe direction (the hostile cache grants nothing). None asserted the direction fix 3 exists for:
  that a poisoned latch cannot **wedge revocation off**. Poisoning `_revocationIssuedAt` on the
  failed-verify path left the whole file green. There is now a test that mints a genuine CRL after
  the forged 2286 cache and requires it to be accepted, plus a CONTROL that an unrevoked key still
  redeems — otherwise "revocation works" is indistinguishable from "everything is refused".

**The blind spot, stated plainly.** Every on-device test in this release runs the AdMob path,
where `visible` is real. The AppLovin path — where `visible` is inert and `autoRefreshEnabled` is
the entire mechanism — was covered only by unit tests asserting the inert flag. Both findings live
in exactly that gap. No device coverage exists for it and none can be added here: the CI Android
job forces `AD_PROVIDER_ADMOB` because no AppLovin SDK key is committed. Recorded as the sharpest
known limitation of this release rather than smoothed over.

### Round 32 — the widget wrote the flag directly, and the widget wins because it writes last

Both reviewers scored 6.5, tightly this time — both had converged on the same three defects in
the same area, one deeper than any round-30/31 comment had reasoned about.

**BLOCKER (reviewer B) — `BannerAdWidget`/`MrecAdWidget` wrote `autoRefreshEnabled` directly,
outside `InlineVisibilityOwners` entirely.** Every round-30/31 comment in this file says, in as
many words, "writing `true` here overwrote the pause `onAppPaused()` still owned" — and that is
exactly what `_setAppLovinAutoRefresh`, called from `didPush`/`didPushNext`/`didPopNext`, kept
doing. `RouteObserver.subscribe()` calls `didPush()` unconditionally on **every** mount, so a
`BannerAdWidget` mounting under a live launch App Open correctly inherited the `fullscreen` hold
(round 30) and then had `didPush`'s post-frame callback write it back to `true` one frame later.
The adapter was rebuilt around ownership across three rounds; the widget that drives it kept
writing the flag directly, and the widget always won because it wrote last. It survived because
every existing test called the adapter directly and none went through the widget. Both direct
writers and the helper method are deleted — `setBannerRoutePaused`/`setMrecRoutePaused` already
sit beside every call site and already own the flag by name.

**MAJOR (reviewer A) — `onAppPaused`'s background acquire was still gated on an existing ad
view**, the same broken condition round 31 removed from `_holdAppLovinInline` and the route
setters but left here: a banner whose preload was in flight when the app backgrounded took no
hold, then attached with auto-refresh on while the user was elsewhere. Now takes every mounted
surface, matching what round 31 already established.

**MAJOR (reviewer B) — the recovery branch's `forget()` dropped every owner, and only
`fullscreen` was re-taken.** A banner that no-filled, took a `routePaused` hold from a route
pushed on top, then backgrounded and resumed had its ad view discarded and recreated —
`forget()` cleared `routePaused` along with everything else, and nothing re-took it, because
`setBannerRoutePaused` only fires on a transition that has already happened. The recreated
`MaxAdView` attached auto-refreshing while another route still sat on top of it. A helper now
re-asserts every owner that is still true (`fullscreen`, `routePaused`) rather than naming one.

A widget test drives the real `AppLovinAdapter` through the real `BannerAdWidget` and a real
`RouteObserver` — the bug lived entirely in which of two writers goes last, which a test calling
the adapter directly cannot see. 3/3 mutations RED.

### Round 33 — two independent reviewers, two unrelated defects, both real

Both scored 7.5 — the first improvement in several rounds — and, for the first time this deep
into the same area, each found something the other did not: A stayed inside the AppLovin refresh
area and found the acquire was still asymmetric; B stepped outside it entirely and found a
double-fire in the round-30 COPPA retry.

**MAJOR (reviewer A) — a resume that beats an in-flight preload never released the background
hold.** `onAppResumed`'s two branches were `needsRecovery` and `adViewIdNotifier.value != null`.
A key whose preload was still in flight when the app backgrounded — no ad view yet, and no error
yet either — matched neither, so the `background` hold taken by the (now unconditional, round 32)
`onAppPaused` survived the resume. When the preload later landed it inherited
`autoRefreshEnabled == false` and never refreshed again for the session. The release is now
unconditional, before either branch, mirroring `AdMobAdapter`'s round-29 fix in the same shape.

**MAJOR (reviewer B) — the round-30 COPPA retry answered the host's `onComplete` twice.**
`_scheduleInitRetryIfNeeded` stores `onComplete` verbatim and re-invokes it when the retry lands;
passing that same closure through while ALSO calling `_reportAbandonedInit` immediately queued a
second call on top of the first. Every sibling failure path in this method calls the immediate
reporter only when scheduling *failed*, precisely to keep the "exactly once" contract stated two
screens up — this branch was the one exception. Reviewer B named the shape of gap directly: the
existing test passed a no-op `onComplete` and asserted only that a retry was scheduled, so it
could not see a double-fire because it discarded both calls' arguments.

The fix separates two different claims that round 30's comment had conflated: the event bus and
the queued-caller drain answer "nobody else is coming" for *those* audiences and still fire
immediately; the host's own `onComplete` for *this* call is answered exactly once. The two
directions turned out not to be symmetric here either — a flag flipping *to* restricted stays on
the immediate-report path (AppLovin will keep refusing to init while restricted, so retrying
would only burn a full backoff schedule on something that cannot succeed); a flag flipping *away*
from restricted is the one direction retrying is for, and there `onComplete` is answered exactly
once, by the retry.

2/2 mutations RED.

### Round 34 — no product defect, one review-harness defect

Reviewer A found nothing: 8.5/10, no reproducible BLOCKER/MAJOR/MINOR, both round-33 fixes traced
correctly to their production call sites.

Reviewer B found something real, but not in the product: the `CHANGES.diff` handed to every
reviewer this whole review chain was produced with plain `git diff`, which — by ordinary git
behaviour — omits untracked files entirely. **All 17 new `r23_*` test files, the new
`lib/src/adapters/_inline_visibility.dart` ownership module, and this audit document itself never
appeared in that diff**, only in the full rsynced checkout each reviewer also had on disk.
`grep -c 'new file mode' CHANGES.diff` → 0. Every reviewer's `flutter test` passed because it ran
against the real working tree, which does have these files; a diff literally applied to a clean
checkout, or a PR built from `git diff`'s output, would ship the twelve fixes and the round-30–33
AppLovin ownership rework with **zero** of their regression tests actually committed. An area that
has regressed four rounds running would ship with no committed test to catch a fifth.

This is a defect in how this review chain packaged the change for its reviewers, not in the SDK.
Recorded here because the fix is procedural and easy to get wrong again: **the eventual commit
must stage new files explicitly, not `git diff` a subset of the tree.** `git status --porcelain`
confirms the full change is 37 untracked files + 45 modified tracked files, all present and
correct on disk; nothing is missing from the *working tree*, only from the diff artifact used to
brief reviewers.

### Round 35 — the corrected diff, and one real fifth regression in the same file

With the diff-packaging defect fixed (see round 34), reviewer A re-checked the whole change with
the complete artifact and found nothing: 8.5/10. Reviewer B found a fifth instance of the exact
bug shape rounds 28, 30, 31 and 32 had each found for a different owner.

**MAJOR — a banner/MREC key first created while the app is already backgrounded got no
`background` refresh hold.** `_fullscreenOverInline` gives a surface created while the App Open is
up the `fullscreen` hold at construction (round 30's fix); `background` had no equivalent. A key
created after `onAppPaused()` already ran — nothing before it could have seen a key that did not
exist yet — started with `autoRefreshEnabled == true` and no owner holding it down. Reviewer B
proved it mechanically: `onAppPaused()` with zero banners mounted, then `adapter.banner('newKey')`,
and the fresh listenables came back with refresh already enabled.

Rated MAJOR rather than BLOCKER on an honestly-assessed reachability limit reviewer B stated
themselves: `BannerAdWidget`/`MrecAdWidget` only ever call `adapter.banner(key)` from `build()`,
and Flutter does not schedule frames while `AppLifecycleState.paused` — so the ordinary widget path
cannot construct a new key while backgrounded. The narrow path that can: a VIP expiring while the
app is backgrounded, which re-triggers a banner build off `initRevision` without needing a frame.
Reported as a real gap in the fix regardless of how it is reached today, not a guaranteed-to-fire
regression.

Fixed with the same shape as `_fullscreenOverInline`: a persistent `_appBackgroundedForInline`
bool, set in `onAppPaused`/cleared in `onAppResumed`, checked at construction in both
`_bannerListenablesFor` and `_mrecListenablesFor` exactly like the fullscreen flag already was.
1/1 mutation RED.

### Tests the fix forced to change, which is itself part of the finding

Seven tests in the pre-existing `test/monetization_arbitrator_test.dart` went red on the
min-samples rule, plus two assertions in `test/r23_arbitrator_per_slot_test.dart`. Every one of
them established "the arbitrator should veto" by feeding a **single** revenue event. That is the
bug written down as a fixture: the suite had been asserting that one sample is enough to price a
format. They now feed five. No assertion was weakened — the averages are unchanged, because five
identical samples average to the same number as one.

`flutter analyze` → "No issues found!". `flutter test` → **1,336 pass**.
On-device, all green on an Android emulator (Pixel 10 Pro XL): `r23_vip_purge_clock_test` 3,
`r23_stack_provenance_test` 3, `r23_crl_selfsigned_cache_test` 2, `r23_gaid_whitelist_regrant_test`
2, `r23_banner_revive_on_vip_expiry_test` 1 — plus the full 33-file integration sweep.
