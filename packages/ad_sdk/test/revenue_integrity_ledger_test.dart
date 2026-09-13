// T145 — Cross-provider Revenue Integrity Ledger. This is a TIME-WINDOW
// HEURISTIC fallback: a successful show with no matching AdRevenueEvent for
// the same (providerTag, type, placement) within `matchWindow` is flagged
// via the existing IncidentRecorder, not a new reporting mechanism.
//
// T185 — both events now carry an OPTIONAL `requestId`; when both sides of
// a pair carry the same non-null one, the ledger matches EXACTLY instead of
// falling back to the heuristic above (see the "requestId exact match
// (T185)" group below). `requestId` defaults to null in the helpers here so
// every pre-T185 test in this file keeps exercising the exact fallback path
// it always did.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

AdShowEvent _show(
        {String providerTag = '[AdMob]',
        AdPlacement placement = AdPlacement.unspecified,
        AdSlotType type = AdSlotType.interstitial,
        bool success = true,
        String? requestId}) =>
    AdShowEvent(
      providerTag: providerTag,
      type: type,
      placement: placement,
      success: success,
      requestId: requestId,
    );

AdRevenueEvent _revenue(
        {String providerTag = '[AdMob]',
        AdPlacement placement = AdPlacement.unspecified,
        AdSlotType type = AdSlotType.interstitial,
        String? requestId}) =>
    AdRevenueEvent(
      providerTag: providerTag,
      type: type,
      placement: placement,
      valueMicros: 1000,
      currencyCode: 'USD',
      requestId: requestId,
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AdManager().incidentRecorder.clear();
  });

  group('normal match', () {
    test('a revenue event within the window clears the pending show — no '
        'incident recorded', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 60),
        debugClock: () => now,
      );
      AdManager().debugEmit(_show());
      await _flush();

      now = now.add(const Duration(seconds: 5));
      AdManager().debugEmit(_revenue());
      await _flush();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, isEmpty);
      ledger.dispose();
    });

    test('revenue arriving LATE but still inside the window does not '
        'false-positive', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 60),
        debugClock: () => now,
      );
      AdManager().debugEmit(_show());
      await _flush();

      // 59s later — one second before the window closes.
      now = now.add(const Duration(seconds: 59));
      AdManager().debugEmit(_revenue());
      await _flush();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, isEmpty,
          reason: 'revenue arrived before the window closed — not a real '
              'integrity issue, must not be flagged');
      ledger.dispose();
    });
  });

  group('genuinely missing revenue', () {
    test('a successful show with NO matching revenue event past the '
        'window is flagged via IncidentRecorder EXACTLY ONCE', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 60),
        debugClock: () => now,
      );
      AdManager().debugEmit(_show(providerTag: '[AppLovin]'));
      await _flush();

      now = now.add(const Duration(seconds: 61));
      // Any subsequent event drives the expiry sweep.
      AdManager()
          .debugEmit(_show(providerTag: '[AppLovin]', success: false));
      await _flush();

      expect(ledger.pendingCount, 0,
          reason: 'the stale entry was swept; the new failed show never '
              'creates a pending entry (only success:true does)');
      expect(AdManager().incidentRecorder.entries, hasLength(1));
      expect(AdManager().incidentRecorder.entries.single.label,
          contains('[AppLovin]'));

      // Round-1 review — the swept entry must not linger and re-report on
      // a LATER, unrelated event: it was already removed from the pending
      // list by the sweep above, so a further event must not add a
      // second incident for the same (already-gone) entry.
      now = now.add(const Duration(seconds: 1));
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
      ));
      await _flush();
      expect(AdManager().incidentRecorder.entries, hasLength(1),
          reason: 'a swept entry must not re-report on a later event');
      ledger.dispose();
    });

    test('a failed show never creates a pending entry at all', () async {
      final ledger = RevenueIntegrityLedger();
      AdManager().debugEmit(_show(success: false));
      await _flush();

      expect(ledger.pendingCount, 0);
      ledger.dispose();
    });
  });

  group('matching keys', () {
    test('a revenue event for a DIFFERENT providerTag (same placement) '
        'does not clear an unrelated pending show', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show(providerTag: '[AdMob]'));
      await _flush();

      AdManager().debugEmit(_revenue(providerTag: '[AppLovin]'));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: 'different providerTag — must not match');
      ledger.dispose();
    });

    test('a revenue event for a DIFFERENT placement (same providerTag) '
        'does not clear an unrelated pending show', () async {
      const placementA = AdPlacement.custom('level_complete');
      const placementB = AdPlacement.custom('reward_shop');
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show(placement: placementA));
      await _flush();

      AdManager().debugEmit(_revenue(placement: placementB));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: 'same providerTag but different placement — must not '
              'match');
      ledger.dispose();
    });

    // T150 — the match key used to be just (providerTag, placement), with
    // no `type`. If an app shows two different ad formats at the same
    // placement (e.g. both left at AdPlacement.unspecified) with the same
    // provider, a revenue event for one format could FIFO-match a pending
    // show of the OTHER format — silently "paying off" the wrong show and
    // hiding a genuine gap on whichever format actually lost its callback.
    test(
        'a revenue event for a DIFFERENT type (same providerTag+placement) '
        'does not clear an unrelated pending show', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show(type: AdSlotType.interstitial));
      await _flush();

      AdManager().debugEmit(_revenue(type: AdSlotType.rewarded));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: 'same providerTag+placement but different type — must '
              'not match, or a revenue event for one ad format silently '
              'pays off a pending show of a completely different format');
      ledger.dispose();
    });

    test(
        'a revenue event for the MATCHING type (same providerTag+placement) '
        'still clears the pending show, even when a different-type entry '
        'is also pending for the same providerTag+placement', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show(type: AdSlotType.interstitial));
      await _flush();
      AdManager().debugEmit(_show(type: AdSlotType.rewarded));
      await _flush();
      expect(ledger.pendingCount, 2, reason: 'sanity: both pending');

      AdManager().debugEmit(_revenue(type: AdSlotType.rewarded));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: 'only the rewarded entry must clear, leaving the '
              'interstitial one still pending');
      ledger.dispose();
    });

    test(
        'multiple pending shows for the same key are matched FIFO — the '
        'OLDEST is the one actually cleared, not just "some" entry',
        () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 10),
        debugClock: () => now,
      );
      AdManager().debugEmit(_show()); // #1 (older) at t0
      await _flush();
      now = now.add(const Duration(seconds: 5));
      AdManager().debugEmit(_show()); // #2 (newer) at t0+5s
      await _flush();
      expect(ledger.pendingCount, 2);

      // One revenue event — under FIFO this clears #1 (older), leaving
      // only #2 (newer, still has 5s left in its own 10s window) pending.
      AdManager().debugEmit(_revenue());
      await _flush();
      expect(ledger.pendingCount, 1);

      // Advance to t0+11s: #1 would have expired at t0+10s if it were
      // STILL pending (proving a LIFO/any-non-FIFO match had wrongly kept
      // it) — but #2 (matched at t0+5s, expires at t0+15s) has not. A
      // driving event here must therefore report ZERO incidents under the
      // correct FIFO behavior.
      now = now.add(const Duration(seconds: 6));
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
      ));
      await _flush();
      expect(AdManager().incidentRecorder.entries, isEmpty,
          reason: 'FIFO must have cleared #1 (older) on the revenue '
              'event — if the newer one had been cleared instead (LIFO), '
              '#1 would still be pending and would have expired by now, '
              'producing an incident here');
      expect(ledger.pendingCount, 1,
          reason: '#2 (newer) is still legitimately pending, not yet '
              'expired');
      ledger.dispose();
    });
  });

  group('requestId exact match (T185)', () {
    test('a revenue event with a matching requestId clears the pending '
        'show even outside (providerTag, type, placement) — the ID alone '
        'is authoritative', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.custom('a'),
        requestId: 'req-1',
      ));
      await _flush();

      // Deliberately mismatched provider/type/placement — only requestId
      // should decide this.
      AdManager().debugEmit(_revenue(
        providerTag: '[AppLovin]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.custom('b'),
        requestId: 'req-1',
      ));
      await _flush();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, isEmpty);
      ledger.dispose();
    });

    test('a requestId match is chosen over an unrelated pending show that '
        'would otherwise match by (providerTag, type, placement) FIFO',
        () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      // #1 has no requestId (simulates a not-yet-updated adapter) and would
      // normally be the FIFO match for the same-key revenue event below.
      AdManager().debugEmit(_show());
      await _flush();
      // #2 carries the real requestId this revenue event should resolve to.
      AdManager().debugEmit(_show(requestId: 'req-exact'));
      await _flush();

      AdManager().debugEmit(_revenue(requestId: 'req-exact'));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: '#2 (matched by requestId) is gone; #1 (no requestId, '
              'FIFO-oldest) must still be pending — proves the exact match '
              'was NOT bypassed in favor of FIFO ordering');
      ledger.dispose();
    });

    test('a requestId that matches nothing pending falls back to the '
        '(providerTag, type, placement) heuristic instead of being '
        'dropped', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      // Pending show has no requestId at all (adapter didn't stamp one).
      AdManager().debugEmit(_show());
      await _flush();

      // Revenue event has a requestId, but it matches no pending show's id
      // — must still fall back to the same-key FIFO match, not treat this
      // as unmatched.
      AdManager().debugEmit(_revenue(requestId: 'req-orphan'));
      await _flush();

      expect(ledger.pendingCount, 0,
          reason: 'falls back to (providerTag, type, placement) FIFO when '
              'the requestId itself matches no pending show');
      expect(AdManager().incidentRecorder.entries, isEmpty);
      ledger.dispose();
    });

    test('omitting requestId on both sides is the exact pre-T185 fallback '
        'behavior — unchanged', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show());
      await _flush();
      AdManager().debugEmit(_revenue());
      await _flush();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, isEmpty);
      ledger.dispose();
    });
  });

  group('unrelated events do not disturb existing state', () {
    test('an unrelated AdClickEvent does not clear an existing pending '
        'show (only a matching AdRevenueEvent may)', () async {
      final ledger = RevenueIntegrityLedger(
          matchWindow: const Duration(seconds: 60));
      AdManager().debugEmit(_show());
      await _flush();
      expect(ledger.pendingCount, 1);

      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
      ));
      await _flush();

      expect(ledger.pendingCount, 1,
          reason: 'an unrelated event must not clear an existing, '
              'still-valid pending entry');
      ledger.dispose();
    });

    test('an AdClickEvent alone, with nothing pending, creates no entry',
        () async {
      final ledger = RevenueIntegrityLedger();
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
      ));
      await _flush();
      expect(ledger.pendingCount, 0);
      ledger.dispose();
    });
  });

  group('dispose', () {
    test('stops listening — no further pending entries or incidents after '
        'dispose', () async {
      final ledger = RevenueIntegrityLedger();
      ledger.dispose();

      AdManager().debugEmit(_show());
      await _flush();

      expect(ledger.pendingCount, 0);
    });
  });
}
