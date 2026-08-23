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
