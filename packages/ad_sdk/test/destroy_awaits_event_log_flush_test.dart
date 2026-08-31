// T102 regression: AdManager.destroy() used to fire-and-forget the event
// log's flush() instead of awaiting it. A host that calls initialize() right
// after destroy() (a supported pattern — see the "auto-disposing previous"
// branch in initialize()) constructs a brand-new AdEventLog over the same
// AdPreferences; its constructor reads the persisted blob synchronously off
// whatever is on disk *right now*. If the old log's flush write hadn't
// landed yet, the new log loaded a stale/empty blob and the old log's queued
// entries were gone for good.
//
// The first two attempts at this fix made `flutter test` hang on
// ad_manager_core_test.dart's remoteSafetyProvider timeout test — round 3
// found the real cause: that test mixed `fakeAsync` with genuine
// platform-channel work in AdMobAdapter.initialize(), which kept running in
// real wall-clock time after the test's virtual zone had already closed.
// `unawaited(...)` hid it; `await` exposed it because destroy()'s own
// tearDown then waited on that orphaned tail. Fixed by making that test real
// (no fakeAsync) instead of adding a timeout here that would have masked it.
//
// AdEventLog.debugPersistDelay (see ad_event_log_test.dart) reproduces the
// real-device timing gap that the in-memory SharedPreferences mock is too
// fast to exhibit on its own. This test drives that seam through the real
// AdManager.destroy() path — not just AdEventLog in isolation — to prove the
// fix actually closes the gap at its real call site.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdEventLog.debugPersistDelay = null;
    AdManager().debugEventLog = null;
  });

  test('destroy() awaits the event log flush before returning', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    final log = AdEventLog(prefs);
    log.recordEvent(
      const AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        success: true,
      ),
      timestampMs: 1,
    );
    AdManager().debugEventLog = log;

    AdEventLog.debugPersistDelay = const Duration(milliseconds: 60);

    final stopwatch = Stopwatch()..start();
    await AdManager().destroy();
    stopwatch.stop();

    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(55),
        reason: 'destroy() must actually wait for the flush write to land — '
            'if this used unawaited(...) again, destroy() would return '
            'almost immediately regardless of debugPersistDelay');
  });
}
