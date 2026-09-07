// T145 — Cross-provider Revenue Integrity Ledger. NO shared request/
// impression ID exists between AdShowEvent and AdRevenueEvent (verified in
// the ticket itself, ad_event.dart:46-137 — both only carry providerTag,
// type, placement) — this is a TIME-WINDOW HEURISTIC, not exact
// reconciliation: a successful show with no matching AdRevenueEvent for the
// same (providerTag, placement) within `matchWindow` is flagged via the
// existing IncidentRecorder, not a new reporting mechanism.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

AdShowEvent _show(
        {String providerTag = '[AdMob]',
        AdPlacement placement = AdPlacement.unspecified,
        bool success = true}) =>
    AdShowEvent(
      providerTag: providerTag,
      type: AdSlotType.interstitial,
      placement: placement,
      success: success,
    );

AdRevenueEvent _revenue(
        {String providerTag = '[AdMob]',
        AdPlacement placement = AdPlacement.unspecified}) =>
    AdRevenueEvent(
      providerTag: providerTag,
      type: AdSlotType.interstitial,
      placement: placement,
      valueMicros: 1000,
      currencyCode: 'USD',
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
