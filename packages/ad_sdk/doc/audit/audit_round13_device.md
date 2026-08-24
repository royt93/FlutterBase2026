# Round 13 — on-device consent verification (Pixel 7 Pro, EEA debug geography)

The one thing 12 rounds of green tests could not prove: that the UMP path
actually works on hardware. Run on 2026-08-23 against the example app with
`--dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<device hash>`,
provider AdMob (no AppLovin SDK key is committed, so that path cannot init
locally — see "still unverified" below).

## What passed on the device

| Path | Evidence from the device log |
|---|---|
| Form presentation | `gdprApplies=1`, `status: required`, the real 206-partner TCF form |
| Refusal | `IABTCF_PurposeConsents=00000000000` + `status=obtained` → `nonPersonalizedAds=true, hasUserConsent=false` |
| Non-personalised still serves | `loadBanner ✅` plus an impression after that refusal |
| Acceptance | `PurposeConsents=11111111111` → `nonPersonalizedAds=false, hasUserConsent=true` |

The refusal line is the round-7 z2 Blocker (`obtained` ≠ "agreed") holding on
real hardware, not just in a test.

## What failed — BLOCKER: a withdrawal made after 20 seconds never applied

Withdrawing consent through the Privacy Options form had **no effect** whenever
the form stayed open longer than 20 seconds. Verbatim, and note the missing
`applyConsent` line after the write:

```
18:55:45  [UmpConsent] ⚠️ privacy options form: privacy options form dismiss timed out after 20s
18:55:45  [AdMobAdapter] applyConsent → nonPersonalizedAds=false restrictedDataProcessing=false (hasUserConsent=true, …)
18:56:00  Writing to storage: [IABTCF_PurposeConsents] 00000000000
```

Mechanism: `requestPrivacyOptionsFlow`'s own 20 s wait frees the caller but
cannot close the native form (`Future.timeout` has no such power — that is why
the ad block is deliberately *not* released there). So the flow read
`getConsentStatus()`/`canRequestAds()` **while the form was still on screen**,
handed that pre-decision snapshot to `AdManager.showPrivacyOptions()`, and
nothing ever re-read it. The user's actual choice landed 15 seconds later, into
a process that had already stopped listening: personalised ads for the rest of
the session, with the user's own withdrawal on record. Exactly the failure GDPR
/DMA enforcement looks for, and invisible to every test because no test kept a
form open for 20 s.

Worth naming: the initial consent form had already learned this lesson —
`kFormDismissTimeout` is 180 s *because* "at 20 s the flow was observed
abandoning a form that was still on screen". The privacy-options flow was left
on the network-call bound of 20 s, even though the withdrawal form is the
*longer* read of the two (the user is hunting for the toggle to turn off).

### The fix — three parts, smallest first

1. **The bound.** Privacy options now waits `kFormDismissTimeout` like the
   consent form does. Same human-reading justification, one shared constant,
   and the existing `debugFormDismissTimeoutOverride` makes it testable.
2. **The late dismiss** (`requestPrivacyOptionsFlow(onLateDismiss:)`). No wait
   is long enough for every user, so the flow keeps listening after it has
   given up: when the dismiss callback does arrive it re-reads status +
   `canRequestAds` and hands a fresh `PrivacyOptionsResult` back.
   `AdManager.showPrivacyOptions()`'s apply step was split into
   `_applyPrivacyOptionsResult` so the late result runs the identical path —
   including the `_retryRefillAds()` on a grant.
3. **The resume backstop** (`AdManager._recheckConsentOnResume`). Covers the
   cases where *no* callback arrives at all: a form torn down by the OS, a
   plugin that drops the callback, a process resumed after the form was
   answered. The CMP writes the choice to the IAB TCF keys regardless, so every
   resume compares the device's answer with what is actually applied and
   re-applies on disagreement. Cheap by construction: the TCF read is a
   `SharedPreferences` lookup and the UMP channel is only touched when they
   disagree — i.e. never on an ordinary resume.

### Tests (each verified red against its own reverted fix)

`test/tcf_personalisation_consent_test.dart`:

* *a dismiss arriving after our own timeout still applies the withdrawal* —
  gates the mock `showPrivacyOptionsForm` so the form stays "on screen" past
  the (shortened) wait, then withdraws. Red without part 2: `Expected: false
  Actual: <true>`.
* *resume re-applies a consent change this process never saw land* — the TCF
  keys say refused, nothing was applied, a resume fixes it. Red without part 3:
  `Expected: false Actual: <true>`.
* *resume with the device and the applied state in agreement is a no-op* —
  guards the other direction, so an ordinary resume cannot churn the consent
  epoch and discard loaded ads for nothing.

`test/ump_consent_test.dart`'s existing timeout test now asserts the flow is
still waiting at 20 s and gives up at `kFormDismissTimeout` — the old
assertion was pinning the bug.

## QC gate on the fix (round 13) — 5 findings, all fixed

The first commit of the fix scored codex 5/10 and agy 8/10 (gate is >8.5 from
both), on five findings that all shared one root: a *late* consent apply is a
second writer racing the first.

| Sev | Finding | Fix |
|---|---|---|
| Blocker | The resume branch showed the App Open ad *and* started the consent re-check in the same turn, so a fill cached under the old consent could be on screen before the withdrawal reached either provider. | App Open now runs in `.whenComplete()` of the re-check, capped at 2 s so a wedged UMP channel cannot swallow the ad. **Superseded by round 2 below**: the 2 s cap showed the ad anyway on timeout, so the gate became fail-closed at 5 s — the bound in the code today. |
| Major | The at-timeout snapshot was applied even when the form was demonstrably still open — inconclusive by construction, and it clobbered the (correct) late apply that followed. | `showPrivacyOptions()` returns early on `formShown && error contains 'timed out'`, keeping the current consent until the form reports back. Same shape as the existing `umpInconclusive` guard in `_applyUmpConsentResult`. |
| Major | Two applies could interleave inside `_applyPrivacyOptionsResult`'s `await IabStorage…` and the stale one land last. | A generation counter (`_consentApplySeq`): the apply drops itself if a newer one started while it was reading. Deliberately *not* a chained future queue — round 12 showed a tail future in a dead zone wedges the whole suite. |
| Major | The late apply was fired with bare `unawaited`, so a throw inside it became an unhandled async error. | `.catchError` logs it and returns the result. |
| Minor | `tcfAllowsPersonalisedAds()` reports `true` for `gdprApplies=0` ("out of scope", not "consented"), so the backstop would have flipped a host's own `setConsent(hasUserConsent: false)` — a parental toggle, a CCPA choice — back on at every resume. | The backstop may only ever tighten: `if (tcfAllows) return;`. The asymmetry is the point — a missed withdrawal is a compliance violation, a missed grant costs one session of personalised fill that the normal consent paths grant anyway. |

Two more tests, each verified red against its own reverted fix:

* *resume applies the pending withdrawal BEFORE any App Open work* — pins the
  order, not just the end state (red: `applyConsent` landed at index 2, the
  App Open call at 1).
* *resume never overrides a host-set refusal outside GDPR scope* — red without
  the tighten-only guard: `Expected: false Actual: <true>`.

Suite: 1059 green, `flutter analyze` clean.

## QC gate round 2 on the fix — codex 4/10, four more findings

| Sev | Finding | Fix |
|---|---|---|
| Blocker | Only the App Open ad waited for the consent re-check. `adapter.onAppResumed()` is not a passive notification — it recreates failed banners/MRECs and re-enables auto-refresh, i.e. it *requests* ads, and it still ran first. | All resume ad work moved into `_resumeAdWorkAfterConsent(ad)`, behind the re-check. |
| Blocker | The 2 s cap could not cancel the re-check, so on timeout the App Open was shown anyway — exactly the impression the fix exists to prevent, just later. | The gate is fail-closed: a re-check that times out (5 s) or throws means **no** ad work at all this resume, retried on the next one. A skipped banner refresh costs one resume; a fill under a withdrawn consent is a violation. |
| Major | The `_consentApplySeq` generation counter guarded only the *read* phase: an older apply that had passed the check could still finish its `setConsent` write last and restore the stale value, and neither `destroy()` nor a host `setConsent()` invalidated it. | Two applies never overlap now — `_pendingConsentApply` + `_consentApplyRunning` coalesce them so the in-flight run also writes the newer intent (still no future chain, so the round-12 dead-zone trap stays shut). `_consentIntentEpoch` is bumped by `destroy()` and by any host `setConsent`, and an apply that sees it move drops itself. |
| Minor | Several of the round-1 claims were untested and could regress green. | Four tests added, each verified red against its own reverted fix. |

The four new tests (`test/tcf_personalisation_consent_test.dart`):

* *a resume consent re-check that never settles blocks all ad work* — wedges
  the UMP `getConsentStatus` call and lets the cap fire on the real clock. Red
  without fail-closed: `Actual: ['onAppResumed', 'loadAppOpen']`.
* *the at-timeout snapshot is never applied* — red without the inconclusive
  guard: `Expected: false Actual: <true>`.
* *a host consent decision beats a consent apply already in flight* — the race
  window is a few microtasks wide, so `AdManager.debugConsentApplyBarrier`
  (test-only) parks an apply inside it. Red without the epoch guard.
* *a throwing late apply is logged, not an unhandled zone error* — red without
  the `catchError`: the throw escapes as an unhandled async error.

Suite: 1063 green, `flutter analyze` clean.

## QC gate round 3 — codex 6/10 (agy 10/10), two findings on the same window

agy found nothing on `5aaa528`; codex found two, both about the window *inside*
an apply rather than its end state.

| Sev | Finding | Fix |
|---|---|---|
| Blocker | `_updateCanRequestAds(result.canRequestAds)` ran before the epoch check, so a superseded late callback reopened the ad gate and then yielded on the storage read. An ad could be requested under a consent a newer host decision (or `destroy()`) had already invalidated — the end-state assertions could not see it, because the consent value itself ended up right. | The gate is opened only after the epoch check. |
| Major | `_inConsentApply` was a plain boolean held across the awaited write, so a host `setConsent` during that window was mistaken for the apply's own write and lost its epoch bump. | Replaced with a zone value (`_consentApplyZoneKey`), which is scoped to one async context instead of to wall-clock time. Plus a restore: an apply that finds itself superseded *after* writing puts `_lastHostConsentIntent` back, so it is never the last writer standing. `destroy()` clears that intent, so a dead session never has one re-applied into it. |

Two more tests, red against their own reverted fix:

* *a superseded apply never opens the ad gate on its way out* — red: `Expected:
  false Actual: <true>`.
* *a host decision landing mid-write is restored over the apply* — red:
  `Expected: true Actual: <false>`. Needs a second test-only barrier
  (`debugConsentWriteBarrier`) because the window is the write itself.

Suite: 1065 green, `flutter analyze` clean.

## QC gate round 4 — codex 7/10 (agy 10/10), two findings on teardown

agy found nothing on `b64e763` for the third round running; codex found two,
both about what happens when a session is torn down mid-flight.

| Sev | Finding | Fix |
|---|---|---|
| Major | `_resumeAdWorkAfterConsent(ad)` holds the adapter it was handed across the awaited consent re-check. A `destroy()` + re-initialise in that window means `onAppResumed()` lands on a disposed adapter — which recreates banners and re-enables auto-refresh on a dead native session. | An identity guard before the ad work: `if (!identical(_adapter, ad)) return;`. The consent *write* still reaches whoever is current — that part is correct and required. |
| Major | `destroy()` bumped the intent epoch but never reset `_consentApplyRunning`. A consent write still hanging at teardown left the coalescing loop wedged forever, so every later apply only populated `_pendingConsentApply` and returned: a withdrawal in the next session could stay unapplied indefinitely. | `destroy()` clears the flag. A stray old loop is harmless — the epoch bump makes its payload drop itself. |

Two more tests, red against their own reverted fix:

* *a resume whose adapter was replaced mid-check touches neither* — wedges
  `getConsentStatus`, swaps the adapter, releases. Red: `Expected: empty
  Actual: ['onAppResumed']`.
* *a write hanging at destroy() does not wedge the next session* — parks an
  apply on `debugConsentWriteBarrier`, destroys, then withdraws in the new
  session. Red: `Expected: false Actual: <true>`.

Suite: 1067 green, `flutter analyze` clean.

## QC gate round 5 — codex 7/10 (agy 10/10), one finding on the round-4 fix

agy found nothing on `3b99bca`; codex found that the round-4 teardown fix
opened a smaller version of the same hole.

| Sev | Finding | Fix |
|---|---|---|
| Major | `destroy()` clears `_consentApplyRunning` while the old loop is still alive, so that loop's `finally` released the runner while a *new* run held it. Two apply loops then wrote concurrently, and an older consent decision could land after a newer one. | Ownership is a token now (`_consentApplyRunToken`): a loop releases the flag only if it is still the owner, and `destroy()` bumps the token so the disowned loop can no longer release anything. |
| Minor | The resume cap reads 5 s against a documented 2 s bound. | Doc-only: the 2 s cap was superseded by the round-2 fail-closed gate; the round-1 table now says so, since 5 s is deliberate (a re-check that does not settle skips ad work entirely rather than showing an ad under stale consent). |

One more test, red against its own reverted fix:

* *a disowned apply loop cannot hand the runner to a second one* — parks an
  apply on the write barrier, destroys, starts a withdrawal in the new session,
  lets the orphan finish, then issues a re-grant. Red: `Expected: true Actual:
  <false>` — the older withdrawal lands last.

Suite: 1068 green, `flutter analyze` clean.

## QC gate round 6 — codex 8/10 (agy 10/10), one finding on the write window

codex's first pass on `2e80c35` re-reported both round-4 findings as still
open; challenged to quote the lines, it retracted both (`_consentApplyRunning
= false` at `destroy()`, and the `identical(_adapter, ad)` guard are both
there) and re-scored 8/10 on one new finding, which stands.

| Sev | Finding | Fix |
|---|---|---|
| Major | The apply opened the ad gate *before* its write, so between the write starting and the post-write epoch check noticing a newer host decision, an ad could be requested under the older, more permissive consent. The end-state assertions could not see it because the restore fixes the final value. | The gate may only tighten before the write: a refusal closes it immediately, a grant opens it only after the write has landed under the apply's own epoch. Same asymmetry as the resume backstop — a delayed grant costs one refill, a fill under a stale consent is a violation. |

One more test, red against its own reverted fix:

* *the ad gate stays shut until a permissive write has landed* — parks the
  grant on the write barrier and asserts the gate mid-flight. Red: `Expected:
  false Actual: <true>`.

Suite: 1069 green, `flutter analyze` clean.

## QC gate round 7 — codex 7/10 (agy 10/10), one finding on session identity

| Sev | Finding | Fix |
|---|---|---|
| Major | The late-dismiss callback was not bound to the session that opened the form. A form opened, then `destroy()` + a new session making its own consent decision, then the old native form dismissing — the callback captured the *current* epoch, passed every check, and wrote a dead session's answer over the live one's. | The form is bound to a `_consentSessionEpoch`, bumped by `destroy()` only, and an apply carrying a stale session is dropped. Deliberately *not* `_consentIntentEpoch`: that one is also bumped by a host `setConsent`, so reusing it would drop a late withdrawal whenever the host set anything mid-form — losing the exact decision this path exists to deliver. |

One more test, red against its own reverted fix:

* *a form from a torn-down session never writes into the new one* — opens a
  form, lets our wait expire, destroys, has the new session refuse host-side,
  then releases the form. Red: `Expected: false Actual: <true>`.

Suite: 1070 green, `flutter analyze` clean.

## QC gate round 8 — codex 6/10 (agy 10/10), one finding on the round-7 fix

| Sev | Finding | Fix |
|---|---|---|
| Blocker | `destroy()` does not dismiss the native form, so the callback round 7 started dropping can be carrying a **real withdrawal** the user made while the *new* session was already serving ads — and nothing else would notice, since presenting or dismissing that form need not produce a lifecycle resume. | A stale-session callback no longer drops the user's choice, only the dead session's *values*: it re-reads the device state (`_recheckConsentOnResume`), which is tighten-only, so a withdrawal recorded in the TCF keys lands immediately and a grant cannot be smuggled in. |

One more test, red against its own reverted fix:

* *a withdrawal made in a pre-teardown form still reaches the new session* —
  opens a form, expires our wait, destroys, re-initialises with a grant, then
  withdraws in the old form. Red: `Expected: false Actual: <true>`.

Suite: 1071 green, `flutter analyze` clean.

## QC gate round 9 — codex 8/10 (agy 10/10), one finding on the queue

| Sev | Finding | Fix |
|---|---|---|
| Major | Round 6 stopped the gate opening before a write, but not after one that a **newer intent had already superseded**. A grant's write lands, `_pendingConsentApply` still holds the user's withdrawal, and the older grant opened the gate anyway — with the form already gone, so every mounted banner was free to request under a consent that no longer existed. | Two halves of the same rule: a restrictive result tightens the gate the moment it is *queued* (not when the runner reaches it), and a permissive result may only open it when `_pendingConsentApply == null`. The queued intent gets to decide. |

Three tests for this one, each red against its own reverted fix — unit, widget
and on-device, per the standing rule that every case gets all three:

* **unit** — *an apply in flight never opens the gate over a queued refusal*
  (`test/tcf_personalisation_consent_test.dart`): the grant parks on
  `debugConsentWriteBarrier`, the refusal behind it parks at the apply *entry*
  barrier so it cannot tighten the gate itself, then the grant's write is
  released. Red: `Expected: false Actual: <true>`.
* **widget** — *a mounted banner requests nothing while a queued refusal is
  waiting behind an in-flight grant* (`test/consent_gate_banner_widget_test.dart`,
  new file): the same sequence with a real `BannerAdWidget` mounted over a
  counting adapter, so the regression fails on the *consequence* rather than on
  an internal flag. Red: `Expected: <0> Actual: <1>` — one live banner request
  under a withdrawn consent. Its other half (*a clean grant does let the banner
  request*) pins that the fix costs a consenting user nothing.
* **integration** — *a TCF withdrawal this process never saw land is applied on
  the next resume* (`example/integration_test/consent_resume_backstop_test.dart`,
  new file): the one piece of this round that a mocked store cannot prove. It
  writes the real IAB TCF keys into the platform's own preference store (the
  Android default `<packageName>_preferences` file — the MJ2/m10 plumbing that
  used to be broken while mocked unit tests passed), then drives a real
  lifecycle pause/resume. Both halves ran green on the S24 Ultra
  (`R5CX613VZBR`), including the "healthy resume changes nothing" case.

Suite: 1074 green (1071 + the round-9 unit test + 2 widget tests),
`flutter analyze` clean in both the package and the example.

## QC gate round 10 — codex 6/10 (agy 10/10), and it was right

| Sev | Finding | Fix |
|---|---|---|
| Blocker | Round 9 keyed the pre-write tighten on `canRequestAds`, which the **ordinary withdrawal never trips**: a user turning personalisation off in the CMP form leaves non-personalised ads servable, so UMP keeps reporting `canRequestAds=true` and `status=obtained` — the refusal exists only in the TCF purposes, read halfway through the apply. The gate therefore stayed open for the whole provider + storage write while the OLD personalised configuration was still applied, so any load in that window (banner refresh, a newly mounted ad surface, a host-triggered load) got a *personalised* request out after an explicit withdrawal. Every test written so far had modelled the easy total-ad-block case (`canRequestAds=false`) and so passed over it. | Tighten on **either** signal: `if (!result.canRequestAds || (!hasConsent && appliedBefore.hasUserConsent)) _updateCanRequestAds(false);`. The post-write branch reopens it, so withdrawing personalisation still is not withdrawing ads — it costs the non-personalised path only the duration of the write. |

Both new tests are red against the reverted fix:

* **unit** — *a personalisation withdrawal shuts the gate until the write lands*
  (`test/tcf_personalisation_consent_test.dart`): grant applied, then a
  purposes-only refusal parked on `debugConsentWriteBarrier`. Red:
  `Expected: false Actual: <true>`. It also pins the other half — the gate
  reopens once the non-personalised config has landed.
* **widget** — *a banner mounted during a personalisation withdrawal requests
  nothing until the new config has landed*
  (`test/consent_gate_banner_widget_test.dart`): a second ad surface mounted
  mid-write, as a user navigating while the withdrawal is still applying. Red:
  `Expected: <1> Actual: <3>` — three personalised banner requests after the
  withdrawal.

The on-device backstop test was re-run green on the S24 Ultra against this
change. Suite: 1076 green, `flutter analyze` clean.

## QC gate round 11 — codex 6/10 (agy 10/10), two findings

| Sev | Finding | Fix |
|---|---|---|
| Blocker | Rounds 9 and 10 combined into one window neither covered. Round 9 tightens at **queue** time but reads `canRequestAds` — which a purposes-only withdrawal never trips. Round 10 tightens on the TCF purposes but only **inside the runner**, which cannot reach a queued result while an earlier apply is still in provider/storage I/O. So a withdrawal queued behind another apply left the gate wide open with the OLD personalised configuration applied, for as long as that first write took. Round 9's queued test uses `canRequestAds=false`; round 10's tests are not queued. | Close the gate for **anything queued behind a running apply**, whatever it claims: `if (!result.canRequestAds \|\| _consentApplyRunning) _updateCanRequestAds(false);`. Whether a queued result is a withdrawal cannot be known at queue time — the TCF read lives in the runner — so the pessimistic close is the only honest answer. It costs a queued *grant* nothing but the wait: the runner reopens the gate once its write lands. |
| Major | `destroy()` called `resetUmpFormOnScreen()`, on the stated grounds that the adapter had just been torn down so nothing could be drawn over anything. But `destroy()` does **not** dismiss the native form (the same fact the consent session epoch exists for), and the next `initialize()` brings a fresh adapter with it — so a form the user is still reading lost its ad block, and an App Open ad over a consent form steals the tap the consent choice needs. | Removed the reset. The leak it guarded against (a dismiss callback that never arrives) is now bounded by each presentation's own `kUmpFormOnScreenBackstop` (15 min), which did not exist when that line was written. `resetUmpFormOnScreen()` stays for tests. |

Each new test is red against its own reverted fix:

* **unit (blocker)** — *a purposes-only withdrawal queued behind a running
  apply shuts the gate at queue time* (`test/tcf_personalisation_consent_test.dart`).
  Red: `Expected: false Actual: <true>`. Paired with *a grant queued behind a
  running apply still reopens the gate*, so the pessimistic close can never
  become an outage.
* **widget (blocker)** — *a banner mounted while a purposes-only withdrawal is
  queued requests nothing* (`test/consent_gate_banner_widget_test.dart`). Red:
  `Expected: <1> Actual: <3>` — two extra personalised banner requests after
  the user had turned personalisation off.
* **unit (major)** — *a form still on screen keeps the mutex across destroy()
  and the next session* (`test/privacy_options_test.dart`). Red with the reset
  restored: `Expected: 'a consent form is on screen' Actual: <null>`. Paired
  with *a form whose dismiss never arrives releases via its backstop, even
  across destroy()*.
* **integration (major)** — `example/integration_test/ump_form_block_destroy_test.dart`,
  two tests: the block survives a real `destroy()` + `initialize()` cycle on
  hardware, and the backstop still releases it.

Suite: 1081 green, `flutter analyze` clean.

## QC gate round 12 — codex 8/10, agy 7/10, and they found the same hole

Both reviewers landed on the round-11 close from opposite ends: it is a
*guess*, and a guess needs an owner. The runner normally reopens the gate after
its write — but an apply can finish without writing anything, and it can die on
the way.

| Sev | Finding | Fix |
|---|---|---|
| Major | The apply that owed the reopen gets **superseded**: a host `setConsent` (parental toggle, CCPA switch) bumps the intent epoch and clears the queue, so the apply drops its values at the epoch check and returns. `setConsent` deliberately does not own `_canRequestAds`, and nothing else writes it — so the pessimistic close was permanent. Every ad surface in the app stays dark for the rest of the session. | `_recoverConsentGate()`, scheduled whenever the runner releases. It only ever lifts a close that was a guess (`_pessimisticGateClose`, armed at that one site and cleared by every other gate write), only after asking the real UMP channel whether ads are allowed at all, and only when what is applied still matches the device's TCF state — otherwise it re-applies the device state instead of reopening blind. Free on the ordinary path: the gate is already open by then, so it returns before touching UMP. |
| Major | The apply **throws** (a storage error, a dead channel) — the exception unwound the whole drain loop, so any intent queued behind it, typically the very grant that would have reopened the gate, was dropped and never applied. | Each item in the drain gets its own try/catch; the first error is still rethrown to the caller once every queued intent has had its turn. |

Each new test is red against its own reverted fix:

* **unit** — *a pessimistic close is lifted when the apply that owed it was
  superseded* (red: `Expected: true Actual: <false>`) and *... when the apply
  that owed it failed* (red with the per-item catch reverted, same values), in
  `test/tcf_personalisation_consent_test.dart`.
* **widget** — *banners come back after a queued apply was superseded instead
  of staying dark* (`test/consent_gate_banner_widget_test.dart`). Red:
  `Expected: a value greater than <0> Actual: <0>` — a blank ad slot, which is
  what the user of a consuming app would actually see.
* **integration** — `example/integration_test/consent_gate_recovery_test.dart`,
  both paths on hardware, where the recovery talks to the real UMP channel and
  the platform's own TCF keys.

Suite: 1084 green, `flutter analyze` clean, 4/4 device tests green on the S24
Ultra (`R5CX613VZBR`).

## QC gate round 13 — codex 5/10, both findings on the round-12 recovery

The recovery added in round 12 was itself a new actor on the gate, and codex
attacked it on exactly the two fronts that matter: what it does across its own
awaits, and what happens when it cannot finish.

| Sev | Finding | Fix |
|---|---|---|
| Blocker | `_recoverConsentGate()` checked ownership once, at entry, then awaited the UMP channel and the TCF read. A withdrawal starting inside either await is invisible to it: with the apply held before its own TCF read, the recovery's read still returns the permissive snapshot and the applied state still matches it, so it reopened the gate over an apply that was about to change the provider configuration. A banner refresh in that window is a personalised ad under a withdrawn consent — the bug rounds 9-12 exist to prevent. | Ownership is re-read after **every** await (`_recoveryStillOwed` — the debt flag, the gate, the footgun block, the runner and the queue — plus the intent epoch captured at entry). Any real decision in flight wins; the recovery simply drops out. |
| Major | The recovery was one-shot and detached. A transient channel failure, or a native side that never answered, left the debt armed with nothing coming back for it — the same session-long ad outage the recovery was added to prevent, now with an extra step. | The UMP read is bounded (`_consentGateRecoveryTimeout`, 10s) and a failure schedules a retry (30s, up to 3 attempts, cancelled and reset by `destroy()`). A resume also resets the attempt counter and kicks the recovery once: a channel wedged while the app was backgrounded is usually not wedged afterwards, and the call costs nothing when nothing is owed. |

Each new test is red against its own reverted fix:

* **unit** — *recovery never reopens the gate over an apply that started while
  it was waiting* (red: `Expected: false Actual: <true>`) and *recovery retries
  when the UMP channel fails* (red: `Expected: true Actual: <false>`), in
  `test/tcf_personalisation_consent_test.dart`.
* **widget** — *a banner requests nothing while the gate recovery is overtaken
  by a real apply* (red: `Expected: <0> Actual: <1>` — one personalised
  request) and *banners come back after a transient consent-channel failure*
  (red: `Expected: a value greater than <0> Actual: <0>` — a permanently blank
  slot), in `test/consent_gate_banner_widget_test.dart`.
* **integration** — no new device test. Both findings need the UMP channel to
  park or fail on command, which only a mocked channel can do; the device layer
  already covers the recovery end-to-end
  (`example/integration_test/consent_gate_recovery_test.dart`) and that suite
  was re-run green after this change.

Suite: 1088 green, `flutter analyze` clean.

## QC gate round 14 — codex 6/10, agy 8/10, three findings on the round-13 recovery

Both reviewers stayed on the recovery. codex went after the two places it still
writes or gives up without re-establishing that the debt is its to pay; agy
found a third caller that can invalidate it mid-flight, plus two hygiene gaps.

| Sev | Finding | Fix |
|---|---|---|
| Major | The `!ump.canRequestAds` branch cleared `_pessimisticGateClose` **before** the post-await ownership check. A stale refusal landing after a newer apply had armed its own guessed close settled that apply's debt too — and when that apply then wrote nothing (superseded), nothing was left to reopen the gate. Same shape as the round-12 bug it was supposed to prevent, one indirection deeper. Also let a recovery from a torn-down session clear a new session's debt. | Ownership (`_consentRecoveryStillOwns`) is re-checked before **any** write this run makes, the settle included. |
| Major | Only the UMP read was retried. Everything after it can fail too — the mismatch re-apply writes to both providers — and that error escaped into the detached `catchError` that only logs. The nested recovery its own runner would have kicked is suppressed by `_consentGateRecovering`, so the debt stayed armed with nobody coming back for it: ads dark for the session. | The whole body after the UMP read is wrapped; a failure schedules the same bounded retry (30s × 3). |
| Major | A host `setConsent()` during one of the recovery's awaits bumps `_consentIntentEpoch`, so the recovery stood down — correctly. But `setConsent` deliberately never touches `_canRequestAds`, so nobody took the debt over: a settings toggle at the wrong moment made the guessed close permanent. | `_consentRecoveryStillOwns` hands the debt to a retry when it loses its epoch with the debt still owed. A `destroy()` clears the flag, so that path schedules nothing. |
| Minor | The ordinary apply refills the held fullscreen slots when it reopens the gate; the recovery did not. Mounted banners came back on their own via `canRequestAdsListenable`, but app-open, interstitial and rewarded stayed empty until the next route change or the five-minute scan. | `_retryRefillAds()` on the reopen path. |
| Minor | `_resetGuardState()` cancelled `_resumeFallbackTimer` and `_splashBudgetTimer` but not `_consentGateRecoveryRetry`, so a re-init without `destroy()` left a previous session's retry armed. Harmless when it fires (the reset reopens the gate, which clears the debt) — but a guard timer outliving its session is exactly what the T63 and round-5 entries above are about. | Cancelled and its attempt counter reset alongside the other two. No test: there is no behaviour to assert, the timer is a no-op either way. |

Each new test is red against its own reverted fix:

* **unit** (`test/tcf_personalisation_consent_test.dart`) — *a stale UMP refusal
  never settles a debt a newer apply owns*, *recovery retries when its own
  re-apply fails*, *a host consent decision mid-recovery does not strand the
  gate*, *recovery refills the held fullscreen slots when it reopens the gate*.
  All four red as `Expected: true Actual: <false>` (or a missing
  `loadInterstitial` call) against their own revert.
* **widget** (`test/consent_gate_banner_widget_test.dart`) — *banners come back
  after a host decision lands mid-recovery*, red as
  `Expected: a value greater than <0> Actual: <0>`: every banner in the app
  blank for the rest of the session after a settings toggle.
* **integration** (`example/integration_test/consent_gate_recovery_test.dart`) —
  *a recovered gate has its fullscreen slots refilled behind it*, the one
  finding of the three-plus-two that a real device can hold: the other two
  Majors need the UMP channel to park mid-call on command, which no on-device
  seam can do.

On device (S24 Ultra `R5CX613VZBR`): 5/5 green — the three recovery tests plus
the two form-block ones. The refill test first went red for a reason worth
recording: the fleet's devices carry VIP entries from the other suites, and a
VIP loads no ads at all by design, so the refill scan legitimately did nothing.
It now calls `vip!.revokeAll()` first, the same setup the other ad-loading
integration tests use.

Suite: 1093 green, `flutter analyze` clean.

## QC gate round 15 — codex 7/10, agy 10/10, one finding

agy found nothing open. codex found the one await the round-14 pass still left
unguarded, and it was right.

| Sev | Finding | Fix |
|---|---|---|
| Major | The recovery's own mismatch re-apply is an await like any other, and the only one with no re-check after it. A host decision landing while that re-apply is in flight supersedes it, so it writes nothing — and the recovery run its runner kicks on the way out is suppressed by `_consentGateRecovering` for as long as the outer run is still on the stack. The debt was left armed with nobody to pay it: the guessed close became permanent again, one await deeper than round 14. | One owner for the debt, in `_recoverConsentGate`'s `finally`: if this run is leaving with the debt still owed and no timer armed for it, it arms one. The two inner `_scheduleConsentGateRecoveryRetry()` calls (round 13's UMP-failure retry, round 14's post-UMP one) were folded into it, and `_consentRecoveryStillOwns` went back to being a pure predicate — one place decides to re-arm, so there is no path that can forget to. |

Red-proof: reverting only the `finally` sweep turns four unit tests red at once
(the new *a host decision during the recovery's own re-apply does not strand the
gate*, plus round 13's *recovery retries when the UMP channel fails* and round
14's *recovery retries when its own re-apply fails* and *a host consent decision
mid-recovery does not strand the gate*) — which is the point of a single owner:
every retry path now runs through the same line. The widget half (*banners come
back after a host decision lands in the recovery's own re-apply*) is red as
`Expected: a value greater than <0> Actual: <0>`.

Not device-testable, same class as the two round-14 Majors: the scenario needs
the UMP channel parked mid-call and the apply held at its entry barrier on
command, which no on-device seam can do. The device suite (5 tests) was re-run
green on the S24 Ultra against this commit anyway, since the change is in a path
every one of them walks.

Suite: 1095 green, `flutter analyze` clean.

## QC gate round 16 — codex 8/10, agy 10/10, one finding

agy: "No open defects found in rounds 11-15." codex found one, and it was right
— the same family again, one level up: not *who* pays the debt, but *how much
budget* the debt gets.

| Sev | Finding | Fix |
|---|---|---|
| Major | The three-attempt retry budget was session-global, not per-debt. A debt that burned all three attempts left `_consentGateRecoveryAttempts` at 3; an ordinary consent apply then settled that debt by reopening the gate itself, without resetting the counter. The next guessed close therefore inherited a spent budget and was refused its very first retry — so one transient UMP/TCF/provider failure left the gate shut, and every ad surface in the app dark, until the next consent decision or app resume. | Reset the counter where the debt is armed (`_applyPrivacyOptionsResult`, immediately after `_pessimisticGateClose = true`). One debt, one budget: an older debt that gave up cannot spend a newer one's retries. |

Red-proof: reverting the one reset line turns *a second gate debt gets a retry
budget of its own* red (`Expected: true Actual: <false>`) and the widget half
*banners come back for a second gate debt after an older one gave up* red
(`Expected: a value greater than <1> Actual: <1>`). Both tests exhaust the first
debt's budget against a dead channel, settle it with a clean apply, arm a second
debt, fail its first recovery once, and assert the gate (and the banner behind
it) comes back.

Both harnesses gained a `statusThrows` seam for this: a channel that is down
stays down, which is what a `Completer.completeError` wedge — good for exactly
one failure — cannot express, and exhausting a budget needs three in a row.

Not device-testable, same class as rounds 14-15: three consecutive UMP channel
failures on command plus an apply held at its write barrier is not something any
on-device seam can produce. The device suite (5 tests) was re-run green on the
S24 Ultra against this commit anyway.

Suite: 1097 green, `flutter analyze` clean.

## QC gate round 17 — codex 6/10, agy 8/10, two findings, both real

The first round where the two reviewers found *different* defects and both were
right. Same family, two different holes.

| Sev | Finding | Fix |
|---|---|---|
| Major (agy) | The withdrawal close in `_applyConsentResultOnce` armed no debt. An ordinary personalisation withdrawal leaves ads ALLOWED (`canRequestAds` stays true; the withdrawal shows up only in the TCF purposes), so the gate it closes across the write is owed a reopen. When a host `setConsent` superseded that write — or the write threw — the apply returned before the reopen, `setConsent` deliberately never touches `_canRequestAds`, and nothing had armed `_pessimisticGateClose`. Every ad surface in the app stayed dark for the rest of the session. | Split the close into its two cases: a real `!canRequestAds` refusal stays a plain close (a genuine "no" must stay shut), while the withdrawal-tightening close arms the same debt the queued close arms, with a fresh retry budget. `_recoverConsentGate` pays it. |
| Blocker (codex) | `destroy()` mid-consent-write disowns that apply, and `_resetGuardState()` then reopens the gate unconditionally — it has to, because a stale close would lock the next session out of ads for good (T63). So a withdrawal that never finished writing came back in the next session as personalised requests under the previous session's configuration, until the next app resume ran the backstop. | Reconcile against the device at the end of `initialize()`, before the first ad request: read the TCF keys (a local `SharedPreferences` lookup) and, only on a disagreement, fail CLOSED, arm the recovery debt, and run the same re-apply the resume backstop uses. Nothing changes on an agreeing start. |

codex's own proposed fix — carry the closed gate across teardown — was not taken:
that is precisely the T63 regression, a stale `false` with no owner in the new
session. Reconciling the *consent* instead of preserving the *gate* closes the
same hole without it, and covers a plain cold start too, not just `destroy()`.

Red-proof:
- Major: reverting the withdrawal-close branch turns *a withdrawal whose write is superseded still reopens the gate* red (`Expected: true Actual: <false>`) and the widget half *banners come back after a withdrawal write is superseded* red (`Expected: a value greater than <1> Actual: <1>`).
- Blocker: not reachable in `flutter test` — `initialize()` cannot be driven without a native adapter — so it is proven **on device**. `example/integration_test/consent_resume_backstop_test.dart` gained *a withdrawal a teardown interrupted is reconciled at the next init* plus its silent half *an init that agrees with the device changes nothing*. 4/4 green on the S24 Ultra; reverting the reconcile block makes the S24U run fail exactly there (`... survives as personalised ads for the whole session`).

Both new device tests run with `autoRequestUmpConsent: false` — a host that owns
its own consent flow. With the SDK's UMP flow on, that flow reconciles TCF
itself, so the init reconcile is the only thing that can notice in such a
session, which is what makes it the honest test of it.

Suite: 1099 green, `flutter analyze` clean (package + example).

## QC gate round 18 — codex 3/10, agy 7/10, and they converged

Both reviewers landed on the round-17 init reconcile, from opposite ends, and
both were right. The rule they were both pointing at is the one this whole audit
trail rests on: **every device-vs-applied comparison is tighten-only.** A missed
grant costs one refill; a fill under a withdrawn consent is a compliance
violation — and a *guessed close with nobody to lift it* is a session-long ad
outage. The round-17 reconcile broke the rule in both directions at once.

| Sev | Finding | Fix |
|---|---|---|
| Blocker (agy + codex) | The init reconcile compared device against applied **symmetrically** (`deviceTcfAllows != hasUserConsent`), and so did `_recoverConsentGate`'s mismatch branch. A host that runs its own consent UI and starts a session with personalisation OFF on a device whose TCF keys are permissive — a parental toggle, a CCPA switch, a user who consented in the CMP and later turned it off in the app — had its ad gate shut at launch. Then either nothing could reopen it (the resume backstop is already tighten-only and returns immediately on a permissive device) → every ad surface dark for the session; or the recovery's symmetric branch re-applied the permissive CMP keys **over the host's stricter decision** → personalised ads served against a refusal. | Both conditions are now `tcfAllows == false && applied.hasUserConsent`. The permissive direction falls through to the plain reopen: non-personalised ads under the stricter applied state, which is always safe. |
| Major (codex) | The init reconcile shut the gate and then handed the re-apply to `_recheckConsentOnResume`, which arms no debt. If that re-apply threw or hung, the close it had just guessed had no owner. | Route it through `_recoverConsentGate()` instead — the one path that both re-applies a stricter device state *and* arms the bounded retry when it cannot (and times out its own UMP read). |
| Blocker (codex) | What the SDK has **recorded** is not what is **applied**. `ConsentManager.set()` updates its in-memory value first, persists second, and writes to the providers last, so a store that refuses the write (a full disk, an OEM store that throws) left the record saying "withdrawn" while AdMob and AppLovin still held the personalised configuration. Every device-vs-applied comparison read that record, found it in agreement with the device, and walked away. | Two halves. (a) `_lastCommittedConsent` / `_committedConsent`: the last consent whose write actually reached both providers, and what every comparison now reads. (b) `AdManager.setConsent` no longer lets a persist failure stop the decision from reaching the providers — it logs and applies anyway. Losing the value across a restart is by far the lesser failure, and the init reconcile re-derives it from the device's own TCF keys. |

Red-proof:
- Tighten-only recovery: *recovery never grants personalisation the host has switched off* (`test/tcf_personalisation_consent_test.dart`) — reverting the mismatch branch to the symmetric form turns it red (`Expected: false Actual: <true>`, i.e. it granted).
- Persist-failure resilience: *a withdrawal the store refuses to persist still reaches the providers* — red without the `try`/`catch` (the call throws before either provider is told). Driven by `_FailableConsentStore`, an `InMemorySharedPreferencesStore` that fails writes to the consent key only, which is the *legacy* `SharedPreferences` store `AdPreferences` actually uses.
- Committed-vs-recorded: *a recorded-but-never-applied withdrawal is not mistaken for applied* — goes through `ConsentManager.set()` directly (the built-in consent dialog's path, the one that does not run `AdManager.setConsent`), so the record diverges from the providers for real. Red on reverting `_committedConsent` in `_recheckConsentOnResume` (`Expected: a value greater than <2> Actual: <2>` — nothing re-applied).
- The init half is not reachable in `flutter test` (`initialize()` needs a native adapter), so it is proven **on device**: `example/integration_test/consent_resume_backstop_test.dart` gained *an init with the host stricter than the device keeps ads flowing without granting*. 5/5 green on the Pixel 7 Pro; reverting both conditions to their symmetric form makes exactly that test fail on hardware with `Expected: true Actual: <false>` on `... every ad surface stayed dark for the whole session`.

Note on the pair: with the recovery tighten-only, a symmetric init condition is
merely wasteful rather than fatal, and vice versa. The device test is red only
when *both* are reverted — which is the honest statement of what it pins: the
contract, not either line.

Suite: 1102 green, device suite 5/5, `flutter analyze` clean (package + example).

## QC gate round 19 — codex 6/10, agy 8/10, and both found the same thing

Both reviewers independently reported the same Blocker, and it is a regression
round 18 introduced: **round 18 tracked "what is really applied" in the wrong
place.** `_lastCommittedConsent` was assigned inside `AdManager.setConsent`,
which is only one of the writers that reaches the provider SDKs. The built-in
consent dialog writes straight through `ConsentManager`, and `initialize()`
applies to the providers itself. After either of those, the marker still
described an older decision — and pointing every device-vs-applied comparison at
a stale marker is *worse* than the in-memory record it replaced, because it fails
in the unsafe direction:

1. host `setConsent(hasUserConsent: false)` → marker says refused;
2. user grants in the built-in dialog → `ConsentManager.set(true)` → the
   providers really are personalised now, marker unchanged;
3. user withdraws in the CMP and the dismiss callback is lost;
4. resume backstop: device says refuse, marker says refuse → "already applied",
   return. Personalised ads keep going out under a withdrawal.

| Sev | Finding | Fix |
|---|---|---|
| Blocker (codex + agy) | as above | Record it in the one funnel every provider write goes through instead of at any call site: `applyConsentToProviders` (`lib/src/core/ad_consent.dart`) sets `_lastAppliedToProviders` at the end, exposed as `lastConsentAppliedToProviders`, and `AdManager._committedConsent` reads that. This covers `initialize()`'s own apply and the dialog path for free, and any future caller too. `destroy()` clears it (`resetLastConsentAppliedToProviders()`) — the next session re-applies from its own bootstrapped state, and leaving it set would leak across tests. |

Red-proof: *a grant that did not come through setConsent still counts as
applied* (`test/tcf_personalisation_consent_test.dart`) — a host refusal through
`setConsent`, then a grant through `ConsentManager.set` (the dialog's path), then
a device that refuses. Restoring round 18's arrangement (the marker assigned only
in `setConsent`) turns it red: `Expected: a value greater than <1> Actual: <1>`
— the backstop re-applied nothing.

Suite: 1103 green, device suite 5/5, `flutter analyze` clean (package + example).

## Round 20 — the hardware found it, not a reviewer: a tighten must not need the network

This one did not come out of a review. The round-19 device run went from 5/5 to
2/5, and the log said why on every failing test:

```
[UmpConsent] ⚠️ requestConsentInfoUpdate failed: 2:Error making request.
[AdManager]  📶 connectivity watch started (connected=false)
[AdManager]  ⚠️ 🔐 init: device TCF personalisation=false disagrees with the applied consent (true) — gating ads until it is re-applied
```

and then nothing. The reconcile fired, shut the gate, handed the re-apply to
`_recoverConsentGate()` — and the recovery's very first act is a UMP read. With
UMP unreachable it logged "could not reach UMP — retrying" and returned **without
applying anything**. Three retries later the debt was abandoned. Net effect on a
device with no network, or during a UMP outage (which is a real thing — this is
what the hardware actually did):

* the withdrawal recorded in the device's own TCF keys never reached AdMob or
  AppLovin, so both stayed configured for **personalised** ads under a refusal;
* and the ad gate stayed shut for the whole session.

Both halves of the same mistake: **the tighten direction was made to depend on a
network round-trip.** It never needed one. Whether ads may be *personalised* is
`statusAllows && tcfAllows`, so a `tcfAllows == false` settles that half on its
own; UMP is only ever consulted for whether ads may be requested *at all*. The
resume backstop had the identical bug in a nastier form: its UMP read was
unbounded, and `_resumeAdWorkAfterConsent` caps the whole re-check at 5 s — so
even where UMP eventually answered, the cap could cut the re-apply and the
withdrawal survived the resume.

| Sev | Finding | Fix |
|---|---|---|
| Blocker | `_recheckConsentOnResume` read UMP first, unbounded, with no `catch`. Offline (or slower than the caller's 5 s cap) the withdrawal was never applied. | The read is bounded at `_deviceWithdrawalUmpTimeout` (2 s, deliberately well inside the caller's 5 s) and wrapped: a failure logs and falls through to the apply with `ump == null`. |
| Blocker | `_recoverConsentGate`'s UMP `catch` returned, so the re-apply the init reconcile had handed it never happened. | The `catch` now applies a withdrawal the device is already reporting — tighten-only, and only while this run still owns the debt (`_consentRecoveryStillOwns(epoch)`). |
| Major | A debt whose three retries all burned while offline had nobody left to pay it: gate shut for the session even once the network was back. | `_onConnectivityChanged`'s reconnect branch pays an outstanding debt (`if (_recoveryStillOwed) _recoverConsentGate()`). Reconnect is the one event that says the read which failed can now succeed. |

Both applies go through one new helper, `_applyDeviceWithdrawal(ump)`, so the
policy lives in one place: `canRequestAds: ump?.canRequestAds ?? _canRequestAds`
— without a UMP answer the gate is left **exactly as it is**, never guessed open
— and `status: ConsentStatus.unknown` *unconditionally*, which
`_umpStatusAllowsPersonalisation` maps to "personalisation not allowed", i.e. the
tighten. It cannot grant: the only caller-side condition is
`tcfAllows == false && _committedConsent.hasUserConsent`, the same tighten-only
rule as everywhere else.

### The reviewers' two Blockers on the fix itself

codex scored the first cut **4/10, "not safe to push"** and both reviewers
independently reported the same first item. Both are now fixed, each with its own
red-proof test.

| Sev | Finding | Fix |
|---|---|---|
| Blocker | `_applyDeviceWithdrawal(null)` reached with the gate **already shut** (the init reconcile shuts it, then hands the re-apply over) *extinguished the recovery debt*: `_updateCanRequestAds` clears `_pessimisticGateClose` on every deliberate gate write, and nothing else in the SDK ever reopens the gate. So the fix for a session-long outage caused one. | Re-arm after the apply: `if (!result.canRequestAds && !_canRequestAds) _pessimisticGateClose = true;`. |
| Blocker | The re-check reads the device, then waits on UMP. A host `setConsent` landing in that window is the **newer** decision, and the apply pipeline recomputes `hasUserConsent` from its own fresh TCF read — so a re-apply built from the stale device state overwrote the host's own newer value. | `final epoch = _consentIntentEpoch;` captured **before** the UMP await, with a stand-down if it moved. The pipeline's own epoch check cannot cover this: it captures the epoch *after* the host write has landed. |
| Blocker | The withdrawal still rested on the apply pipeline's **second** TCF read. `tcfAllowsPersonalisedAds()` returns `null` for "no TCF data" (a storage error, `gdprApplies` cleared under us) and `null` means *assume allowed* there — so a re-apply carrying a withdrawal came back out of the pipeline as a **grant**. | `status: ConsentStatus.unknown` is now passed unconditionally, never `ump.status`: every caller has already read the refusal off the device, so `statusAllows == false` settles personalisation with no second read involved. `canRequestAds` still comes from UMP, so non-personalised ads keep serving and the pipeline's own tighten branch closes the gate for the write and arms the debt that reopens it. |

The first cut of the third fix pre-closed the gate inside `_applyDeviceWithdrawal`
instead. That shut the right window but did **not** fix the bug — the pipeline
still recomputed a grant and reopened — and its fake gate transition made
`wasBlocked` true, so the reopen fired `_retryRefillAds()` and broke *a resume
whose adapter was replaced mid-check touches neither* (round-13 round 4). Passing
the fact in beats shutting a window around it.

Red-proof, three tests in `test/tcf_personalisation_consent_test.dart`, each red
on its own line and nothing else:

| Test | Revert | Result |
|---|---|---|
| *a withdrawal is applied on resume even when UMP cannot be reached* | resume read back to unbounded + no `catch` | red |
| *a gate debt whose UMP is unreachable still applies the device withdrawal* | recovery `catch` back to a bare `return` | red |
| *a reconnect pays a gate debt that gave up while offline* | drop the reconnect kick | red |
| *a host consent decision landing mid-re-check is not overwritten* | drop the epoch stand-down | red |
| *a withdrawal survives a second TCF read that comes back empty* | `status:` back to `ump?.status ?? …` | red |
| *an offline init reconcile applies the withdrawal even when the second TCF read comes back empty* | drop `knownTcfRefusal` from the offline branch | red |

## Round 21 — the same fallible read, one level up

agy scored the fixed round-20 change **10/10**. codex scored it **4/10, "not
safe to push"**, on one Blocker, and it was right: passing
`ConsentStatus.unknown` removed the dependency on a second TCF read *inside* the
apply pipeline, but `_recoverConsentGate`'s own offline branch still re-read the
keys to establish a refusal the init reconcile had read moments earlier —

```dart
if (await IabStorage.tcfAllowsPersonalisedAds() == false && …)
```

The failure: init reads `tcfAllows == false`, shuts the gate, hands the re-apply
to the recovery. UMP is unreachable. That second read then throws or returns
`null` (storage error, `gdprApplies` cleared) — `null` is not `false`, so
`_applyDeviceWithdrawal(null)` is never reached and both providers keep the
personalised configuration under a refusal the SDK had *already seen*, for the
session.

Fix: carry the fact instead of re-deriving it.
`_recoverConsentGate({bool knownTcfRefusal = false})`, short-circuited
(`knownTcfRefusal || await …`) so with the refusal in hand there is no second
read to fail, threaded through `_scheduleConsentGateRecoveryRetry` so the bounded
retries keep it, and passed as `true` by the init reconcile — the one caller that
has already read the device.

| Test | Revert | Result |
|---|---|---|
| *an offline init reconcile applies the withdrawal even when the second TCF read comes back empty* (`test/consent_init_reconcile_offline_test.dart`, new) | drop `knownTcfRefusal \|\|` from the offline branch | red |

That test drives the real `initialize()` path (AppLovin provider — AdMob's
adapter init cannot succeed under a mock channel), wedges `getConsentStatus` so
the recovery parks on UMP, clears the TCF keys underneath it, then fails the
channel: nothing but what the reconcile already read says "do not personalise".

Suite: 1109 green, `flutter analyze` clean (package + example).

The device half of this round is the round-19 hardware run itself: it is the log
above that produced the finding. A clean device re-run needs UMP reachable again
(the file's other assertions grant consent through the real UMP flow, which no
amount of local fixing can do offline).

## On-device smoke test of the whole round (Pixel 7 Pro, 2026-08-23)

Same device and debug geography as the round itself, running `3b99bca`:

| Step | Device log |
|---|---|
| Grant | `IABTCF_gdprApplies=1`, `PurposeConsents=11111111111` → `applyConsent nonPersonalizedAds=false (hasUserConsent=true)` |
| Resume with consent settled | `onAppResumed` + `evaluating app-open on resume` both run — the fail-closed gate does not hold a healthy device back |
| Privacy options held open 180 s | `⚠️ privacy options: our wait expired with the form still on screen — keeping the current consent until the form reports back` (the round-1 MAJOR, on hardware) |
| Withdrawal at 195 s | `PurposeConsents=00000000000` → `privacy options form dismissed AFTER our timeout — re-applying` → `applyConsent nonPersonalizedAds=true (hasUserConsent=false)` — the original round-13 BLOCKER, fixed on hardware |
| Resume while that apply was still in flight | `⚠️ a consent apply is still in flight on resume — skipping ad work until it has landed` (the round-2 coalescing guard, on hardware) |
| Next resume | ad work proceeds again; the only skip left is `cold start (one-shot)`, not consent |

## Still unverified

* **AppLovin after a consent change.** Needs a real MAX SDK key; the example
  ships a placeholder, so the AppLovin path cannot init locally. The cached-fill
  limitation from round 7 stands unchanged.
* **iOS.** CI is red on GitHub billing (deliberately not being fixed this
  month), and this round was Android hardware only.
