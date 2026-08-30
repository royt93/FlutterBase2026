# Round 23 — VIP, trial and security face

Reviewer: independent, own `/tmp` copy, read-only. Face assigned: the Ed25519 signed-key
scheme end to end, VIP stacking / expiry / grace, the 1-day trial, storage and clock,
and VIP's interaction with the ad surfaces. Safety-cap arithmetic and consent plumbing
belong to the other two reviewers this round and are not covered here.

Baseline established before anything else: `flutter analyze lib tool` clean,
`flutter test` **1,235 pass**. Every finding below was reproduced against that baseline
with a throwaway probe test, then the probe was deleted; the working tree is unchanged.

Read first, and not re-litigated: `audit_round23_consolidated.md`, including the round-22
section and the `await`-window sweep. Nothing here is an `await`-window finding — that
class really is swept. The three real findings are in the *clock* and the *revocation*
model, which no previous round has attacked directly.

---

## BLOCKER V1 — one wrong clock reading permanently ERASES a paid VIP grant, from disk

**Where:** `lib/src/vip/vip_manager.dart:828` (`_purgeExpired`), driven by
`lib/src/vip/vip_manager.dart:336` (`_effectiveNow`) and
`lib/src/vip/vip_manager.dart:368` (`resyncSessionClock`, called from
`lib/src/core/ad_manager.dart:6251`).

**What the code does.** `_effectiveNow()` keeps a persisted high-water mark of the
furthest wall-clock instant ever observed, and returns that mark whenever the real clock
reads earlier. `_purgeExpired()` then does:

```dart
final now = _effectiveNow();
_entries.removeWhere((e) => !e.isActiveAt(now));   // vip_manager.dart:831
```

`removeWhere` **deletes rows**, and the change is written straight back to secure storage
by the `_save()` on the next line. So if the mark is ahead of an entry's `expiresAt`, that
entry is destroyed — in RAM and on disk — on the very next `load()`.

This directly contradicts the design intent stated two methods above it.
`_isLive`'s own doc comment (`vip_manager.dart:800-820`) says, about exactly this
situation: *"Routed through purge it would instead be erased permanently. Suppress, never
delete."* `_isLive` honours that. `_purgeExpired` does not, because it is the one place
that still compares `isActiveAt(mark)` and then deletes. `_effectiveNow`'s own
"deliberately not closed" note likewise says the accepted cost is that the mark can
*"freeze the remaining time on a grant the customer paid for"* — freeze, not erase. The
accepted cost and the actual cost are not the same thing.

**Concrete trigger, no attacker required.** Two independent routes, both ordinary:

1. *Honest fault.* A phone with a flat battery and no SIM/NTP boots with its date years
   in the future. The user opens the app once. `VipManager`'s constructor anchors
   `_sessionAnchorRealMs` to that bogus reading, so the drift check at
   `vip_manager.dart:338-344` finds wall clock and monotonic clock in perfect agreement,
   trusts it, and commits it as the mark (`vip_manager.dart:350`). NTP later corrects the
   date. Next launch: every VIP entry is gone.
2. *Backgrounded edit.* The user changes the device date forward in Settings (people do
   this for other apps and games), then returns to this app. `didChangeAppLifecycleState`
   calls `resyncSessionClock()` (`ad_manager.dart:6251`), which re-anchors to the bogus
   clock **on purpose** — that resync exists so a normal sleep gap is not misread as
   tampering. Drift detection is therefore blind to the edit, the mark is committed, and
   the user setting the clock back is what triggers the deletion.

**Reproduced.** A probe seeded `ad_sdk_vip_max_observed_clock_ms` one year ahead and gave
the store one genuine grant (`grantedAt` yesterday, `expiresAt` in 29 days), then called
`load()`:

```
[VipManager] purgeExpired: removed 1
entries in RAM: []
entries on disk: []
```

**Real-world consequence.** A customer who paid for 30 or 90 days loses all of it, and
there is **no recovery path** — this is the serverless design (requirement 5), so nothing
can restore it, and the customer cannot re-redeem their own code either: the kid is
already burned in `AdPreferences.addRedeemedVipKeyId` and (on iOS) in the Keychain
`RedeemedKeyLedger`, both of which survive the wipe that took the entitlement. The user
re-enters the key they paid for and is told **"already used"**. That is a refund request
and a one-star review per affected user, and it can be triggered by a dead battery.

**Why it is a BLOCKER rather than a MAJOR.** It destroys paid entitlement, it is
irreversible by construction, it needs no attacker and no root, and the failure is silent
— the log line is a debug-level `purgeExpired: removed 1`.

**Shape of the fix** (not applied — read-only review): purge is the one operation that
must be certain, so it should require *both* clocks to agree that the entry is dead —
delete only when the entry is expired against `_effectiveNow()` **and** against
`DateTime.now()`. That keeps the anti-rollback property intact (a rolled-back clock makes
the raw check *more* permissive, never less, and the mark still handles that half) while
turning the poisoned-mark case back into the suppression the design already documents.
Anything the mark alone says is expired should be suppressed by `_isLive`, which already
happens.

---

## MAJOR V2 — one tap on "watch an ad" launders a revoked key's window past the CRL

**Where:** `lib/src/vip/vip_manager.dart:982-1014` (`addVip`, `stack: true` branch) vs
`lib/src/vip/vip_manager.dart:1508-1541` (`_clampRevokedEntries`).

**What the code does.** The stack branch takes its base from the latest expiry across
**all** live entries regardless of which key produced them:

```dart
var base = now;
for (final e in _entries) {
  if (_isLive(e, now) && e.expiresAt.isAfter(base)) base = e.expiresAt;   // :985-987
}
var newExpiry = base.add(duration);
```

The revocation clamp, by contrast, only ever touches entries whose key literally matches a
revoked kid:

```dart
final revokedEntryKeys = _revokedKeyIds.map((kid) => normaliseKey('SIGNED_$kid')).toSet();
...
if (!revokedEntryKeys.contains(e.key)) continue;    // :1518
```

So any later `stack: true` grant copies the revoked window into an entry the CRL can never
reach. The shipped reference `VipRedeemScreen` passes `stack: true` on **both** its paths —
code redemption (`lib/src/vip/vip_redeem_screen.dart:273`) and watch-ad-to-extend
(`lib/src/vip/vip_redeem_screen.dart:336`) — and `redeemSignedKey` defaults to
`stack: true` (`vip_manager.dart:1183`).

**Concrete trigger.** A user redeems a leaked / refunded / resold 30-day key. At any point
before the publisher revokes it, they tap the screen's own **"watch an ad for +1 day"**
button once. That creates a `WATCH_AD` entry stacked to `base + 1 day`. The publisher then
publishes a CRL revoking the leaked kid.

**Reproduced.** Probe, using the same mint helpers as `test/vip_revocation_test.dart`:

```
after redeem:    29d
after watch-ad:  30d  entries=[SIGNED_LEAKED->2026-09-28, WATCH_AD->2026-09-29]
[VipManager] refreshRevocationList: clamped 1 revoked grant(s) to 24h
after CRL:       30d  entries=[SIGNED_LEAKED->2026-08-30, WATCH_AD->2026-09-29]
```

The clamp fired, reported success, and changed nothing: 743 hours of VIP survive against
an expected ≤24. `test/vip_revocation_test.dart`'s existing "applying a CRL clamps VIP
already granted by that kid" passes only because no second grant is ever stacked in it.

**Real-world consequence.** The CRL is the *only* revocation primitive in a design with no
backend, and it is defeated by one tap that requires no technical skill, no root, and no
knowledge that it is an exploit — a user doing the ordinary thing the UI invites gets the
side effect for free. A key sold on a reseller site, or refunded via the store, keeps
earning for its full window on every device that watched one ad. With `stack: true`
chaining, the ceiling is `AdConfig.maxVipStackDuration` — 90 days — not the 24-hour
`revokedGraceWindow` the design intends.

The existing doc comment at `vip_manager.dart:1505-1507` *notes* this ("a later legitimate
key's entry has already absorbed the revoked window"), but notes it as a property, not as
an accepted risk, and only for the legitimate-second-key case — the watch-ad case, which
is the one the shipped UI makes one tap away, is not covered.

**Shape of the fix:** carry the contributing kid(s) on the stacked entry (an additive
field on `VipEntry`, which the file already floats as the way to close the neighbouring
case-collision issue), and have `_clampRevokedEntries` walk the provenance chain rather
than matching on `key` alone. A cheaper stopgap: when a clamp fires, re-derive every
stacked entry's expiry from the clamped base instead of leaving it alone.

---

## MAJOR V3 — the cached CRL verifies itself, and a future-dated one wedges revocation off forever

**Where:** `lib/src/vip/vip_manager.dart:657` (startup) →
`lib/src/vip/vip_manager.dart:1338` (`_ensureCachedRevocationLoaded`) →
`lib/src/vip/vip_manager.dart:1411` (the `issuedAt` monotonicity check), reading
`lib/src/utils/ad_preferences.dart:477` (`getVipRevocationCache`).

**What the code does.** At startup the cached CRL is verified against the public key
**stored next to it in the same plaintext `SharedPreferences` value**:

```dart
final cachedCrl = _prefs.getVipRevocationCache();
if (cachedCrl != null) {
  await _ensureCachedRevocationLoaded(cachedCrl.publicKey);   // :657-658
```

A signature checked against a key that arrived from the same untrusted store as the
signature is not a verification — it is self-certification. Round 22 made the CRL and its
key one atomic write so the pair can never be *crossed*; it did not, and could not, make
the pair *trusted*. `VipManager` genuinely has no configured public key at `load()` time
(the host passes it per-call to `redeemSignedKey` / `refreshRevocationList`), which is why
the key is stored — but that is the bug, not a justification.

The second half is what makes it permanent. `_ensureCachedRevocationLoaded` sets
`_revocationCacheLoaded = true` and latches `_revocationIssuedAt` from that self-signed
CRL. `refreshRevocationList` then refuses anything not strictly newer:

```dart
if (cachedIssuedAt != null && !parsed.issuedAt.isAfter(cachedIssuedAt)) {   // :1411-1412
  ... 'fetched CRL is not newer than cached — ignoring'
  await _clampRevokedEntries();
  return;
}
```

There is no other path that lowers `_revocationIssuedAt`. A cached `issuedAt` of the year
2286 is a final answer for the lifetime of the install.

**Concrete trigger.** Write one value into `FlutterSharedPreferences.xml` under
`ad_sdk_vip_revocation_v2`: `{"raw": "<CRL1 signed with the attacker's own Ed25519 key,
issuedAt = 9999999999, revoking nothing>", "key": "<attacker's public key>"}`. The write
needs root, an emulator, or a backup/restore path — note that this SDK's own README
instructs host apps to enable Android Auto Backup over exactly this file (see
`_first_install_guard.dart`'s class doc), so the file is a documented, user-reachable
surface, not only a root one.

**Reproduced.** Probe planted that value, ran `load()`, then had the publisher push a
genuine CRL revoking kid `LEAKED`, then redeemed a `LEAKED` key:

```
[VipManager] refreshRevocationList: fetched CRL is not newer than cached — ignoring
[VipManager] 🔑 redeemSignedKey ok kid=LEAKED +720:00:00.000000
redeem of a REVOKED key -> VipRedeemStatus.success active=true
```

**Real-world consequence.** One write, once, permanently disables revocation on that
device — it survives app updates and every future CRL, and unlike forging VIP entries
(which the M6 clamp caps at 24 hours per plant and which must be re-applied) it never has
to be touched again. That is strictly the *most durable* thing an attacker with root gets
out of this scheme, which is why it is worth saying even though root is otherwise close to
game over: every other root attack is rate-limited or self-healing, and this one is not.
It also poisons the honest-fault case — a corrupt or migrated prefs value with a garbage
`issuedAt` has the same effect.

**Shape of the fix:** the host's real public key is the only one that may verify a cached
CRL. Either pass `publicKeyBase64` into `VipManager`'s constructor (it is already required
by both methods that use it) and drop the stored key entirely, or — if the stored key must
stay for rotation — treat a cached CRL whose stored key is not in the host's current
rotation list as absent, and clamp `_revocationIssuedAt` to at most "now" so a
future-dated list can never outrank a real one.

---

## MINOR V4 — a Keychain timeout silently consumes the 1-day trial the user never got

**Where:** `lib/src/core/ad_manager.dart:2221-2236`.

`FirstInstallGuard.hasAlreadyGranted()` is bounded by a 5-second timeout that returns
`true` ("already granted") on expiry — correct, conservative, and documented. But the
`alreadyGranted` branch then does:

```dart
if (alreadyGranted) {
  await prefs.markFirstInstallGraceApplied();   // :2231
```

which is only sound when `true` came from a real Keychain flag. On a timeout it burns the
one-shot flag for an install that was never granted anything: `graceCfg.isEnabled &&
!prefs.isFirstInstallGraceApplied()` at `:2204` is false forever after, so the user never
receives the 24-hour trial (requirement 4) on that install.

**Trigger:** first launch of a genuinely new install where the iOS Keychain read blocks
past 5s — realistically a background-triggered first run before first unlock after a
reboot, or a Keychain under contention on a cold device.

**Consequence:** a new user silently loses the trial that exists to hold them through
day 1. Narrow, but free to fix: don't mark the flag on the timeout branch — leave it unset
so the next init re-runs the guard, which is exactly the recovery the surrounding
"ORDER MATTERS" comment already relies on for the force-kill case.

---

## MINOR V5 — the config GAID whitelist grants "50 years" and silently gets 90 days, once

**Where:** `lib/src/core/ad_manager.dart:1908-1913`.

```dart
await vip.addVip(key: 'CONFIG_${gaid.trim()}', duration: const Duration(days: 365 * 50));
...
await prefs.addVIPMemberFirstInitSuccess();   // :1913 — one-shot, never re-runs
```

`addVip` with the default `stack: false` clamps a single grant to `now + maxStackDuration`
(`vip_manager.dart:1017-1026`), i.e. 90 days with the default config. The one-shot flag is
then set, so the whitelist never re-applies. A device on `AdConfig.vipDeviceGaids` — the
publisher's own QA handsets, and any reviewer/influencer device put there — loses VIP
after 90 days with no way back short of clearing app data.

Not a security hole; the clamp is deliberate (T49) and doing its job. The bug is that the
call site asks for something the clamp will silently refuse and then permanently records
that it succeeded. Either re-apply the whitelist on every init (it is idempotent through
`addVip`'s "latest expiry wins"), or have the whitelist path bypass the stack cap
explicitly.

---

## MINOR V6 — inline ad surfaces stay blank at the exact moment VIP expires

**Where:** `lib/src/core/ad_manager.dart:3093-3109` (`_onVipActiveChanged`) vs
`lib/src/widget/banner_ad_widget.dart:295-320` (and the identical shape in
`mrec_ad_widget.dart:255-262`, `native_ad_widget.dart:197-203`).

`_onVipActiveChanged` exists precisely to handle the `true → false` transition and kicks
all four fullscreen slots plus the adapter-level banner/MREC preload. It does not bump
`initRevision`. The banner widget's retry of `_initBanner` lives in the **outer**
`ValueListenableBuilder<int>` keyed on `initRevision` (`:296-306`); the VIP gate is an
**inner** `ValueListenableBuilder<bool>` (`:311-320`). When VIP flips false only the inner
builder rebuilds, so `_allowed` — left `false` because `_initBanner` short-circuited on
`isVIPMember()` at `:157` — is never re-evaluated, and the widget keeps rendering
`SizedBox.shrink()`.

**Trigger:** the user is in the app, on a banner-bearing screen, when their 1-day trial
(or a redeemed window) runs out. **Consequence:** no banner on that screen until it is
remounted by navigation, a connectivity reconnect (`ad_manager.dart:6605` is the only
`initRevision` bump on this path), or an app restart. Lost impressions only — no policy or
user harm — and the window is narrow because most trials expire while the app is closed.
One line closes it: bump `initRevision` in `_onVipActiveChanged`'s inactive branch, next
to the preloads it already fires.

---

## Things I checked and found sound (recorded so round 24 does not re-walk them)

- **Domain separation, both directions.** A CRL cannot be replayed as an AVP1 key: the CRL
  signs `"CRL1|" + payload` (`signed_vip_key.dart:_crlSignedMessage`) while AVP1 signs the
  payload bare. An AVP2 key relabelled `AVP1.` (or the reverse) dies on the field-count
  check at `signed_vip_key.dart:200-203` (4 vs 2), which is what makes the unsigned prefix
  safe despite being unsigned.
- **Rotation-list handling.** One malformed entry in the comma-separated public key list is
  skipped rather than failing the whole verify (`signed_vip_key.dart:158-186`), 32-byte
  length is enforced, and the retired-key caveat is correctly stated in the comment.
- **Key-expiry clock.** AVP2's `expiresAt` is checked against `_effectiveNow()`
  (`vip_manager.dart:1240`), not the raw clock, so winding the clock back cannot revive an
  expired key.
- **The one-time-use claim.** `_signedKidsInFlight.add(kid)` happens synchronously after
  the two persisted checks with no `await` between (`vip_manager.dart:1266-1273`); the
  durable Keychain ledger check follows. A concurrent double-redeem of the same kid cannot
  grant twice.
- **The burn-vs-grant ordering.** The grant is persisted before the kid is burned, and the
  round-18 `_disposed` re-check sits between them — so a teardown mid-redeem over-serves by
  at most one window rather than burning a key the customer paid for. Correct direction to
  be wrong in.
- **The `_isLive` / MJ9 start-half check.** A forged fallback entry stamped
  `grantedAt: 2099` is not live, and the M6 clamp anchors its 24h to the entry's own
  `grantedAt` so the clamp is idempotent across launches. Both hold. (V1 above is the
  *other* direction of the same clock, which `_isLive` explicitly leaves to `_purgeExpired`
  — and `_purgeExpired` does not honour the contract.)
- **The 90-day stack clamp.** Applied on both the `stack: true` and `stack: false` paths
  (`vip_manager.dart:989-995`, `:1017-1026`), so a mis-minted 100-year key is worth 90 days.
- **The grace-nudge half-window clamp.** `_effectiveNudgeThreshold` correctly stops a
  24-hour trial from nudging on its first launch.
- **`bypassVipGuard`.** It skips exactly one branch (`ad_manager.dart:5658`) and nothing
  else: consent, the fullscreen mutex, the safety caps and `_presentBlockedReason` all still
  apply on that path. It is not a policy bypass, as its doc claims.
- **The plaintext fallback trust rule.** `lastReadWasUntrustedFallback` is only ever set
  from a healthy-probe-plus-successful-read combination, and a failed read is correctly
  treated as evidence of nothing.

---

## UNVERIFIABLE from source

- **Whether the iOS Keychain flags (`FirstInstallGuard`, `RedeemedKeyLedger`) actually
  survive uninstall on the shipping build.** The whole anti-bypass story for the trial and
  for cross-reinstall key reuse rests on it, and it is a signing/entitlement-dependent
  platform behaviour that no unit test can reach. *Evidence that would settle it:* install a
  signed release build on a real device, redeem a signed key and take the trial, delete the
  app, reinstall from TestFlight, and confirm the trial is not re-granted and the key
  reports `alreadyUsed`.
- **Whether Android Auto Backup actually restores `FlutterSharedPreferences.xml` before
  first run on a current OS version.** This is the sole Android mitigation for both trial
  re-grants and cross-reinstall key reuse, and it also determines how reachable V3's planted
  CRL is without root. *Evidence:* a real backup/restore cycle on the target Android
  versions, checking `isFirstInstallGraceApplied()` and the redeemed-kid list on first run
  of the restored install.
- **Whether `AdProviderAdapter.showRewarded` can throw past its own guards** (a
  `PlatformException` from the native bridge). If it can, `_rewardedInFlight` is never reset
  (`ad_manager.dart:5727` sets it; only `onDone` and the early returns clear it), which would
  block every rewarded show for the rest of the session, and `VipRedeemScreen._onWatchAdForVip`
  would hang on its un-timed `Completer` (`vip_redeem_screen.dart:317`) with `_isProcessing`
  stuck true. I could not establish from Dart source that the native call throws rather than
  reporting through the callback, so I am not reporting it as a finding. *Evidence:* force a
  `PlatformException` from the platform channel in an integration test on device and observe
  whether a second `showRewardedAd()` still works.

---

## Score

**5 / 10.**

The signed-key scheme itself is genuinely good for a design with no backend, and the
`await`-window class really is closed — I looked for it and did not find it. The score is
driven by where the remaining damage lives: V1 destroys paid entitlement with no recovery
and needs no attacker at all, and V2/V3 between them mean the only revocation primitive in
the product can be defeated by one tap by an ordinary user (V2) or switched off for good by
one file write (V3). Those are the two things requirement 5 actually has to deliver —
"secure, with no server" — and both are currently reachable.

**DO NOT SHIP** until V1 is fixed; V2 and V3 should be fixed in the same release, because a
revocation list that can be laundered or wedged is worse than no revocation list at all —
it is one the publisher will believe in.
