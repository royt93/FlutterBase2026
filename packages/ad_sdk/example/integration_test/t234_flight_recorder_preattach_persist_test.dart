// T234 — on-device proof that an AdFlightRecorder entry recorded BEFORE
// attach() runs actually survives a real (not mocked) SharedPreferences
// round-trip once attach() finally does run, mirroring
// integration_test/bypass_audit_trail_persistence_test.dart's proof of the
// same bug-class fix (T155) for BypassAuditTrail.
//
// A genuine "kill the process and relaunch" cannot be automated through
// `flutter test` — a single test file/process never truly dies mid-run.
// The strongest automatable proof instead: record on a fresh, never-attached
// AdFlightRecorder (simulating a host that calls enableFlightRecorder() and
// mounts an ad widget before its own splash-screen initialize() resolves
// AdPreferences — see AdFlightRecorder.attach's doc comment), THEN attach()
// it to the app's real on-device storage, flush, and confirm a SEPARATE
// fresh instance attached to that same real storage reads the entry back.
// If the real plugin channel round-trip works, it reads back the entry
// that would otherwise only ever have lived in memory.
//
// Run with:
//   flutter test integration_test/t234_flight_recorder_preattach_persist_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// Internal on purpose — a real consuming app has no access to AdPreferences
// either; this test needs it directly to prove the real plugin round-trip.
// ignore: implementation_imports
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a pre-attach flight-recorder entry survives a real device '
      'persist/reload cycle once attach() runs', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Keep this proof isolated from a prior run's recorder history. The
    // recorder under test remains unattached; only the test itself has the
    // real preference handle needed to clear the one SDK-owned key.
    final prefs = await AdPreferences.getInstance();
    await prefs.setFlightRecorderRaw('');

    // Simulates the real ordering gap this ticket fixes: a recorder that
    // records BEFORE anything ever calls attach() on it — e.g. a host
    // enabling the recorder and mounting a banner ahead of its own
    // splash-screen initialize() resolving AdPreferences.
    final label = 'preAttachDeviceTest_${DateTime.now().millisecondsSinceEpoch}';
    final recorder = AdFlightRecorder();
    await recorder.record(
      label: label,
      slotType: 'banner',
      placement: 'device_test',
      providerTag: '[SDK]',
    );
    expect(recorder.entries, hasLength(1),
        reason: 'sanity: recorded in-memory before any attach() call');

    recorder.attach(prefs);
    // Deliberately NO record() and NO flush() after attach(): T234 must make
    // attach() itself schedule the write after the normal debounce window.
    // This is a real Timer on the real binding (not fake-async), so a real
    // wall-clock wait — not tester.pump — is what actually lets it fire.
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    // Separate, never-recorded-to instance reading the SAME real on-device
    // SharedPreferences storage — proves the real (not mocked) plugin
    // round-trip actually persisted the pre-attach entry to disk.
    final reloaded = AdFlightRecorder();
    reloaded.attach(prefs);

    expect(reloaded.entries.any((e) => e.label == label), isTrue,
        reason: 'T234 — an entry recorded before attach() must not be lost: '
            'attach() must schedule the persist record() could not while '
            'AdPreferences was unavailable');
    expect(await verifyFlightRecorderChain(reloaded.entries), isTrue);
    expect(tester.takeException(), isNull);
  });
}
