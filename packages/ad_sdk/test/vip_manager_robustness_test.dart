// T19 — VIP robustness: non-positive duration rejection, eager expired-entry
// purge on load/redeem, and the stack-cap-vs-non-stacking-uncapped contract.
//
// Backing store is the in-memory SharedPreferences mock, same pattern as
// vip_entitlement_flow_test.dart / vip_manager_stacking_test.dart.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_entry.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so VIP tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    // Shared singleton store → wipe persisted entries for a clean slate.
    await VipManager(prefs, vipEntriesStore: store).revokeAll();
    // …and the anti-rollback high-water mark, which revokeAll() deliberately
    // does NOT clear (a wipe must not hand an abuser a fresh clock). Several
    // tests below park it in the future on purpose; without this reset the
    // next test inherits that parked mark and its grants get stamped a year
    // out, which the MJ9 start guard then correctly suppresses.
    await prefs.setVipMaxObservedClockMs(
        DateTime.now().millisecondsSinceEpoch);
  });

  group('non-positive duration rejected', () {
    test('addVip with Duration.zero fails the debug assert', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(
        () => mgr.addVip(key: 'ZERO', duration: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('addVip with a negative duration fails the debug assert', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(
        () => mgr.addVip(key: 'NEG', duration: const Duration(hours: -1)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a rejected duration never creates or activates an entry', () async {
      // Assertions are disabled in some release-style harnesses; exercise the
      // guarded branch directly by tolerating either outcome and asserting
      // the invariant that matters: no dead/inverted entry survives.
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      try {
        await mgr.addVip(key: 'BAD', duration: Duration.zero);
      } catch (_) {
        // Debug mode: assert throws before mutating state — expected.
      }
      expect(mgr.isActive, isFalse);
      expect(mgr.entries.any((e) => e.key == 'BAD'), isFalse);
    });
  });

  group('eager purge on load/redeem', () {
    test(
        'load() shrinks the persisted store, not just the in-memory active '
        'flag', () async {
      final expired = VipEntry(
        key: 'STALE',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        grantedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      await store.setRaw(VipEntry.encodeList([expired]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(mgr.entries, isEmpty);
      // load()'s purge-triggered save is fire-and-forget (unawaited) in
      // production, so give the queued write a turn to land before reading.
      await Future<void>.delayed(Duration.zero);
      // The raw persisted JSON itself must be shrunk, not just the in-memory
      // list — otherwise stale rows keep accumulating in the store.
      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted, isEmpty);
    });

    test(
        'addVip purges an entry that expired AFTER load (not just at load '
        'time) before adding a new one', () async {
      // Was active at load() time, so load()'s purge doesn't touch it — it
      // only crosses into "expired" a moment later, mid-session. Without an
      // eager purge in addVip itself this would sit in persistence until the
      // next expiry-timer fire or app relaunch.
      final soonToExpire = VipEntry(
        key: 'SOON_STALE',
        expiresAt: DateTime.now().add(const Duration(milliseconds: 5)),
        grantedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await store.setRaw(VipEntry.encodeList([soonToExpire]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      expect(mgr.entries.length, 1, reason: 'still active at load() time');

      // Let it actually cross into expired before the next mutation.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await mgr.addVip(key: 'FRESH', duration: const Duration(hours: 1));

      expect(mgr.entries.length, 1);
      expect(mgr.entries.single.key, 'FRESH');
      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted.any((e) => e.key == 'SOON_STALE'), isFalse);
    });

    test('redeemSignedKey-style add (via addVip) purges expired entries too',
        () async {
      // redeemSignedKey forwards to addVip, so exercising addVip covers the
      // redeem path without needing a signed key fixture here.
      final expired = VipEntry(
        key: 'OLD',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        grantedAt: DateTime.now().subtract(const Duration(days: 2)),
      );
      await store.setRaw(VipEntry.encodeList([expired]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(
          key: 'REDEEMED', duration: const Duration(days: 1), stack: true);

      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted.length, 1);
      expect(persisted.single.key, 'REDEEMED');
    });
  });

  group('maxStackDuration cap scope', () {
    test('stacking clamps at the cap', () async {
      final mgr = VipManager(prefs,
          maxStackDuration: const Duration(days: 10), vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(
          key: 'S', duration: const Duration(days: 8), stack: true);
      await mgr.addVip(
          key: 'S', duration: const Duration(days: 8), stack: true);
      // 8 + 8 = 16d, clamped to 10d.
      final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
      expect(remainingDays, inInclusiveRange(9, 10));
    });

    test(
        'T49: non-stacking grants ARE ALSO capped by maxStackDuration, even '
        'when the requested duration is far beyond it', () async {
      final mgr = VipManager(prefs,
          maxStackDuration: const Duration(days: 10), vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      // Plain (default stack: false) grant, absolute duration way past cap.
      final entry =
          await mgr.addVip(key: 'PLAIN', duration: const Duration(days: 365));

      final remainingDays = entry.expiresAt.difference(DateTime.now()).inDays;
      expect(remainingDays, inInclusiveRange(9, 10),
          reason: 'non-stacking path must also respect maxStackDuration');
    });
  });

  group('VipEntry ISO8601 encoding preserves the exact instant', () {
    // Round-23 audit, MAJOR — [VipEntry.toJson] now always stamps UTC (`Z`),
    // whatever zone the DateTime carried, and [VipEntry.fromJson] converts
    // back to local. Before that a grant written as a zone-less local
    // timestamp was re-read in whatever zone the device was in next, so the
    // stored instant moved on DST rollover or westward travel — and
    // `_purgeExpired()` then deleted it for good. This group locks in the
    // zone-explicit encoding AND that the instant survives the round trip.
    test('an explicitly-UTC entry round-trips through JSON with a Z suffix',
        () {
      final entry = VipEntry(
        key: 'UTC_CHECK',
        expiresAt: DateTime.utc(2026, 1, 1, 12, 30),
        grantedAt: DateTime.utc(2025, 12, 31, 12, 30),
      );
      final json = entry.toJson();
      expect(json['expiresAt'], endsWith('Z'));
      expect(json['grantedAt'], endsWith('Z'));

      final back = VipEntry.fromJson(json);
      // Handed back as local (the in-memory contract every caller relies on),
      // but the same absolute instant.
      expect(back.expiresAt.isUtc, isFalse);
      expect(back.expiresAt.isAtSameMomentAs(entry.expiresAt), isTrue);
      expect(back.grantedAt.isAtSameMomentAs(entry.grantedAt), isTrue);
    });

    test('a local entry is persisted with a zone marker, not zone-less', () {
      final json = VipEntry(
        key: 'LOCAL_CHECK',
        expiresAt: DateTime(2026, 1, 1, 12, 30),
        grantedAt: DateTime(2025, 12, 31, 12, 30),
      ).toJson();
      // The whole point: a reader in ANY zone resolves this to one instant.
      expect(json['expiresAt'], endsWith('Z'));
      expect(json['grantedAt'], endsWith('Z'));
    });

    test(
        'a real VipManager grant (local DateTime.now()) round-trips through '
        'persistence with the same absolute instant', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final entry =
          await mgr.addVip(key: 'RT', duration: const Duration(hours: 3));

      final reader = VipManager(prefs, vipEntriesStore: store);
      await reader.load();
      addTearDown(reader.dispose);

      final reloaded = reader.entries.single;
      // Compare in UTC so the assertion holds regardless of which zone each
      // DateTime happens to carry — what matters is the same instant survived.
      expect(reloaded.expiresAt.toUtc(), entry.expiresAt.toUtc());
      expect(reloaded.grantedAt.toUtc(), entry.grantedAt.toUtc());
    });
  });

  group(
      'no-validator guard forwards isRelease (R12-A round 4 — '
      'isActuallyRelease() was previously unthreaded here)', () {
    test('isRelease: true refuses redemption instead of demo-mode success',
        () async {
      final mgr = VipManager(prefs, vipEntriesStore: store, isRelease: true);
      await mgr.load();
      addTearDown(mgr.dispose);

      final ok = await mgr.debugRunValidator('ANY_KEY', null);
      expect(ok, isFalse,
          reason: 'a release build with no vipKeyValidator configured must '
              'refuse every key, not silently grant free VIP');
    });

    test('isRelease: false keeps demo-mode success (debug/profile)', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store, isRelease: false);
      await mgr.load();
      addTearDown(mgr.dispose);

      final ok = await mgr.debugRunValidator('ANY_KEY', null);
      expect(ok, isTrue,
          reason: 'debug/profile builds without a validator stay in demo '
              'mode so hosts can wire the integration before shipping');
    });
  });

  group('anti clock-rollback — mid-window reactivation', () {
    // T17's VipEntry.isActive only rejects a clock reading *before*
    // grantedAt. It does NOT catch the more common abuse: let a grant
    // expire in real time, then roll the clock back to any point still
    // *inside* [grantedAt, expiresAt) — from the entry's own point of view
    // that's indistinguishable from a legitimate still-active window.
    // VipManager closes this by clamping `now` to a persisted high-water
    // mark. We simulate "the device's clock was previously seen far in the
    // future" by seeding that persisted mark directly, rather than actually
    // moving the OS clock (which the SDK has no injectable seam for) — the
    // clamping code path is identical either way.
    test(
        'entry inside its granted window is NOT active once a later '
        'high-water clock mark has been observed', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final now = DateTime.now();
      await mgr.addVip(key: 'ROLLBACK', duration: const Duration(days: 10));
      expect(mgr.isActive, isTrue,
          reason: 'sanity check — freshly granted entry must start active');

      // Simulate: the app already observed the clock at now+30d (e.g. the
      // grant's own expiry timer or a later launch advanced the high-water
      // mark), then the device clock got rolled back to `now` — still well
      // inside the granted [now, now+10d) window.
      await prefs.setVipMaxObservedClockMs(
          now.add(const Duration(days: 30)).millisecondsSinceEpoch);

      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);

      expect(reloaded.isActive, isFalse,
          reason: 'a clock rolled back into the granted window after the '
              'entry was observed to have already expired must NOT '
              'resurrect it');
    });
  });

  group('MJ9 — a clock parked in the future cannot mint a permanent VIP', () {
    // The exploit the [VipManager._isLive] guard closes. Before round 24 the
    // high-water mark was the ONLY clock consulted, so:
    //   1. set the device clock a year forward,
    //   2. redeem any grant (its grantedAt/expiresAt get stamped a year out,
    //      and the mark is left parked a year out too),
    //   3. put the clock back to the real time.
    // Every later check compared the entry against that same poisoned mark,
    // which agreed the entry was mid-window — so a 10-day grant never
    // expired. Requiring the entry to have STARTED according to the raw
    // device clock breaks step 3: the abuser has to give the device a usable
    // clock, and against that clock the grant has not begun.
    test('a grant stamped a year ahead is NOT active once the clock is '
        'usable again', () async {
      final farFuture = DateTime.now().add(const Duration(days: 365));
      await prefs.setVipMaxObservedClockMs(farFuture.millisecondsSinceEpoch);

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      await mgr.addVip(key: 'MJ9', duration: const Duration(days: 10));

      // The mark is deliberately left parked in the future — that is the
      // whole point. _effectiveNow() still answers with it, so the ONLY
      // thing that can reject this entry is the raw-clock start guard.
      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);

      expect(reloaded.isActive, isFalse,
          reason: 'an entry whose granted window has not begun on the real '
              'device clock must not entitle anything');
      expect(reloaded.expiresAt, isNull,
          reason: 'expiresAt reports the latest LIVE entry — a not-yet-'
              'started one must not be reported as the active window');
    });

    test('the suppressed entry is kept, not deleted', () async {
      final farFuture = DateTime.now().add(const Duration(days: 365));
      await prefs.setVipMaxObservedClockMs(farFuture.millisecondsSinceEpoch);

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      await mgr.addVip(key: 'PAID-FAST-CLOCK', duration: const Duration(days: 10));

      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);

      // Same suppression as the test above, but this is also the honest case:
      // a customer whose device clock was genuinely fast when they paid. The
      // guard must not reach _purgeExpired() — losing the row would destroy a
      // real entitlement instead of postponing it.
      expect(reloaded.isActive, isFalse);
      expect(reloaded.entries.map((e) => e.key), contains('PAID-FAST-CLOCK'),
          reason: 'suppress, never delete — the entry has to survive so it '
              'becomes live again once the real clock reaches its window');
    });

    test('the slack boundary is where it says it is', () async {
      // Round-25 reviewer minor: the honest-clock test below only proves a
      // point well inside the slack, so a slack accidentally widened to a year
      // would still pass it. Pin both sides of the edge instead.
      Future<bool> activeWithMarkLead(String key, Duration lead) async {
        await prefs.setVipMaxObservedClockMs(
            DateTime.now().add(lead).millisecondsSinceEpoch);
        final m = VipManager(prefs, vipEntriesStore: store);
        await m.load();
        addTearDown(m.dispose);
        await m.addVip(key: key, duration: const Duration(days: 3));
        final active = m.isActive;
        await m.revokeAll();
        return active;
      }

      expect(
          await activeWithMarkLead('INSIDE',
              VipManager.futureGrantSlack - const Duration(minutes: 1)),
          isTrue,
          reason: 'a grant stamped just inside the slack must be live');
      expect(
          await activeWithMarkLead('OUTSIDE',
              VipManager.futureGrantSlack + const Duration(minutes: 5)),
          isFalse,
          reason: 'and just outside it must not — otherwise the slack is not '
              'the bound this class documents');
    });

    test('an ordinary grant on an honest clock stays active', () async {
      // Guards the guard: addVip anchors grantedAt to _effectiveNow(), which
      // on a normal device is the raw clock, so a fresh grant must not be
      // caught by the start check. [VipManager.futureGrantSlack] is what
      // absorbs a small mark lead (a recent backwards correction).
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      await mgr.addVip(key: 'HONEST', duration: const Duration(days: 3));
      expect(mgr.isActive, isTrue);

      await prefs.setVipMaxObservedClockMs(DateTime.now()
          .add(VipManager.futureGrantSlack - const Duration(minutes: 5))
          .millisecondsSinceEpoch);
      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      await reloaded.addVip(key: 'HONEST-2', duration: const Duration(days: 3));
      expect(reloaded.isActive, isTrue,
          reason: 'a grant stamped inside the slack window must take effect '
              'immediately — a paying customer cannot be told to wait');
    });
  });

  group('addVip must grant against the anti-rollback clock, not a raw one',
      () {
    // Regression for: addVip() used to compute expiresAt from a raw
    // DateTime.now(), bypassing the high-water-mark clamp _effectiveNow()
    // applies everywhere else in this class. Simulate "the app already
    // observed the clock far in the future" (same technique as the group
    // above) *before* granting — a real forward clock edit followed by a
    // grant would leave exactly this high-water mark behind. If addVip used
    // the raw clock, the new grant's expiresAt would be anchored to "now"
    // (i.e. before the high-water mark) instead of to the mark itself.
    test('new grant is anchored to the high-water mark when it is ahead of '
        'the raw clock', () async {
      final now = DateTime.now();
      final farFuture = now.add(const Duration(days: 365));
      await prefs.setVipMaxObservedClockMs(farFuture.millisecondsSinceEpoch);

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      const duration = Duration(days: 10);
      await mgr.addVip(key: 'CLOCK-TAMPER', duration: duration);

      final entry = mgr.entries.single;
      expect(
        entry.expiresAt.isAfter(farFuture),
        isTrue,
        reason: 'expiresAt must be computed from the high-water-mark clock '
            '(farFuture + duration), not from the raw wall clock — '
            'otherwise winding the clock forward, granting any VIP, then '
            'winding it back yields an effectively permanent VIP',
      );
      expect(
        (entry.expiresAt.difference(farFuture) - duration).abs(),
        lessThan(const Duration(seconds: 1)),
        reason: 'expiresAt should be ~high-water-mark + duration',
      );
    });
  });
}
