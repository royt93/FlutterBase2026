# QC rounds 8–10 — the fixes' own fixes

Rounds 8, 9 and 10 reviewed **round 7's own commits**, not the original code.
Two independent reviewers per round (codex, agy), scored out of 10; the gate for
pushing is >8.5 from both.

| Round | codex | agy | Findings acted on |
|---|---|---|---|
| 8 | 5.0 | 7.2 | 3 Majors → `38a2b38` |
| 9 | 7.0 | 10.0 | 2 Majors → `0e978d8`, 1 Major → `d87da49` |
| 10 | 7.0 | 8.5 | 5 findings → `088ded4` |

Everything below lives in `lib/src/vip/vip_manager.dart` unless stated, and
every production change has a revert-to-red test in
`test/vip_secure_read_recovery_test.dart` (or `test/ump_consent_test.dart` /
`test/vip_revocation_test.dart`) — reverted individually, its own test goes red
and no other.

## Round 8 (`38a2b38`, plus `aea5b49` before it)

* **A load parked on secure storage came back to life after `dispose()`.** A
  retry timer that had already fired was waiting on the Keystore; when it
  answered it mutated entries, pushed the notifier, added to a closed stream and
  armed fresh timers — on a host that does `destroy()` + `initialize()` that is
  a discarded manager with a heartbeat. `_disposed` is now checked after every
  await, and `load()` is serialised through `_loadQueue`.
* **A stale read could wipe a live grant.** `_mutationEpoch` is bumped by every
  write to `_entries` that does not come from `_load`, and a load whose epoch
  moved while it waited abandons its read: whoever wrote last wins, and RAM is
  newer than a read that started before it.
* **A grant arriving during a retry wait left the retry armed** — cancelled now
  in `_refreshActive`.
* **The UMP form block leaked** (`lib/src/core/ump_consent.dart`): the 15-minute
  backstop of a form that had already been reset kept firing over the next
  form's block. `resetUmpFormOnScreen()` releases every live ref-count holder,
  and both `ConsentForm` calls are wrapped so a synchronous throw still releases.

## Round 9 (`0e978d8`, `d87da49`)

* **A load queued behind another one still trusted its read.** The epoch check
  covers the load that is reading; a load that starts afterwards snapshots the
  already-bumped epoch and read storage before the grant's save had landed. A
  load now drains pending writes first.
* **A disposed manager could still write storage.** The guard moved into the
  shared `_save()` path — RAM mutations on a discarded object are harmless,
  persistence is not.
* **A redeem on a disposed manager burned the customer's key.** `redeemSignedKey`
  marks the key id used *after* `addVip`, so a dropped save spent a one-time key
  for nothing. It now refuses up front with `VipRedeemStatus.invalid` and a
  message telling the user to redeem again after the SDK re-initialises (a new
  enum case would be a breaking API change — the enum is exported).

## Round 10 (`088ded4`)

* **The save queue is process-wide.** It was per-instance, but every manager
  writes the same secure-storage key: on destroy + re-init a write the old
  manager had already *started* (past any disposed check, inside the platform
  call) could land after the replacement's and resurrect an entitlement the live
  manager had just revoked.
* **A queued save re-checks `_disposed` at execution time**, not only when
  `_save()` is called — a write can sit in the queue long enough for the host to
  tear the SDK down.
* **The epoch is snapshotted BEFORE the drain.** A grant landing while the drain
  waits queues its write behind the drained one, so the read that follows can
  still predate the grant; snapshotting afterwards read as "nothing changed" and
  dropped it.
* **The drain is bounded** by `kSaveDrainTimeout` (5 s), and so is a queued
  save's wait on its predecessor. `AdManager.initialize()` awaits `load()`, so an
  unanswered platform write would hang SDK startup, and one wedged write would
  freeze every later save for the life of the process. On timeout the load keeps
  the in-memory state and forces a read retry rather than trusting a read it
  never took.
* **The one-shot 1.x GAID migration flag** is not set when the manager was
  disposed mid-load — the flag makes every later launch skip migration, so the
  legacy entitlement would be lost for good.

## Test-harness note, worth knowing before writing more VIP tests

A `Future` propagates its completion in the zone that **created** it. The save
queue is static, so a tail created outside a `fakeAsync` zone (in `setUp`, or by
the previous test's own fake zone) resolves on the real event loop, where
`flushMicrotasks` never sees it — and every save chained onto it stalls until the
real loop turns. `VipManager.resetSaveQueueForTest()` is therefore called per
test **and** again inside each fake zone. Two round-10 tests were red for exactly
this reason before the cause was understood.

## Two vacuous tests, and how they were caught

Two of the round-8 lifecycle tests passed with the production change reverted:
the retry schedule is bounded, so `pendingTimers` is empty five minutes later
either way. Rewritten to count reads against the fake storage instead
(`Expected: <2> / Actual: <8>` with the dispose guards reverted). Assert on the
thing the fix changes, not on a side effect that decays on its own.
