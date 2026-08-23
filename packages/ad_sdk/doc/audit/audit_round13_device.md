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
| Blocker | The resume branch showed the App Open ad *and* started the consent re-check in the same turn, so a fill cached under the old consent could be on screen before the withdrawal reached either provider. | App Open now runs in `.whenComplete()` of the re-check, capped at 2 s so a wedged UMP channel cannot swallow the ad. |
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

## Still unverified

* **AppLovin after a consent change.** Needs a real MAX SDK key; the example
  ships a placeholder, so the AppLovin path cannot init locally. The cached-fill
  limitation from round 7 stands unchanged.
* **iOS.** CI is red on GitHub billing (deliberately not being fixed this
  month), and this round was Android hardware only.
