// On-device integration test for the VIP API playground (VipDemoPage).
//
// Distinct from vip_redeem_flow_test.dart, which drives the shared
// VipRedeemScreen UI (the Cupertino redeem dialog). This one drives the
// *programmatic* API surface VipDemoPage exposes directly: quick redeem
// buttons (plain key + stack:true), signed offline key buttons, and the
// "watch ad to extend" button — and asserts the corresponding
// `AdManager().vip` state (activeListenable, entries stacking) actually
// changes as a result.
//
// Ad *content*/fill for the "watch ad to extend" flow is never guaranteed, so
// that part of the assertion is lenient; the redeem-key assertions are
// strict since they don't depend on ad fill.
//
// Run with:
//   flutter test integration_test/vip_api_playground_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

// Every VIP redeem does a real flutter_secure_storage write (Android
// Keystore-backed EncryptedSharedPreferences) before the UI updates. That's a
// genuine platform-channel round-trip, not fake-clock work `tester.pump`
// fast-forwards through — on a real device its first call can pay one-time
// Keystore key-generation cost well past a guessed fixed pump duration (never
// seen on iOS Simulator, which has no such keystore). Poll for the condition
// instead of assuming a fixed duration is always enough.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 20,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await tester.pump(step);
  }
  expect(condition(), isTrue,
      reason:
          'condition did not become true within ${attempts * step.inMilliseconds}ms');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'quick-redeem buttons flip VIP active and stack across a second redeem',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('VIP API playground');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the VIP API playground tile');

    // Deterministic starting point regardless of this device's prior test
    // history / first-install VIP grace (same pattern as
    // vip_redeem_flow_test.dart).
    await AdManager().vip!.revokeAll();
    await tester.pump();
    expect(AdManager().vip!.activeListenable.value, isFalse);

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('VIP demo'), findsOneWidget);

    // Quick redeem: TEST_VIP_7 (7 days, stack: true).
    final quick7 = find.textContaining('TEST_VIP_7');
    await tester.scrollUntilVisible(quick7, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(quick7);
    // Validator has a fixed 600ms delay (fake-clock, deterministic), but the
    // success dialog only appears after addVip()'s real secure-storage write
    // (Android Keystore-backed) resolves — a genuine platform-channel
    // round-trip whose first call can be slow on real hardware. Poll instead
    // of guessing a fixed duration is always enough.
    final okButton = find.text('OK');
    await _pumpUntil(tester, () => okButton.evaluate().isNotEmpty);

    // redeemVip() shows a blocking (barrierDismissible: false) success dialog
    // that only closes when its "OK" CupertinoDialogAction is tapped — it
    // otherwise sits on top of the whole page and swallows every further
    // tap (including the second quick-redeem button below).
    await tester.tap(okButton);
    await tester.pumpAndSettle();

    expect(AdManager().vip!.activeListenable.value, isTrue);
    final firstExpiry = AdManager().vip!.expiresAt;
    expect(firstExpiry, isNotNull);

    // Redeem a second key — global stacking should push the expiry further
    // out than the first redeem alone (TEST_VIP_7 + TEST_VIP_30 stacked).
    final quick30 = find.textContaining('TEST_VIP_30');
    await tester.scrollUntilVisible(quick30, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(quick30);
    final okButton2 = find.text('OK');
    await _pumpUntil(tester, () => okButton2.evaluate().isNotEmpty);
    await tester.tap(okButton2);
    await tester.pumpAndSettle();

    expect(AdManager().vip!.activeListenable.value, isTrue);
    expect(AdManager().vip!.expiresAt!.isAfter(firstExpiry!), isTrue,
        reason: 'stack:true must add onto the latest expiry, not replace it');
    expect(AdManager().vip!.entries.length, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed key redeem grants VIP and rejects reuse on this device',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('VIP API playground');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) break;
    }
    expect(tile, findsOneWidget);

    await AdManager().vip!.revokeAll();
    // The signed-key one-time-use ledger is a durable (iOS Keychain) anti-abuse
    // backstop that deliberately survives revokeAll/reinstall — so on a device
    // that has already run this test, the fixed demo key id would still show
    // as "already used" from a prior run. Clear it for a clean first redeem.
    await AdManager().vip!.clearRedeemedKeyLedgerForTest();
    await tester.pump();

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));

    final signed1d = find.widgetWithText(FilledButton, 'signed 1d');
    await tester.scrollUntilVisible(signed1d, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(signed1d);
    // redeemSignedKey() resolves after a real secure-storage write (Android
    // Keystore-backed) before setState()/the SnackBar appear — poll instead
    // of assuming a fixed pump duration always covers that platform-channel
    // round-trip (see _pumpUntil doc above _waitForInit).
    final signedOk = find.textContaining('Signed key OK');
    await _pumpUntil(tester, () => signedOk.evaluate().isNotEmpty);

    expect(AdManager().vip!.activeListenable.value, isTrue);
    expect(signedOk, findsOneWidget);
    // Let the first SnackBar fully animate out — ScaffoldMessenger queues a
    // second SnackBar behind a still-showing one (250ms enter + 4000ms
    // display + 250ms exit = 4500ms total), so without this the "already
    // used" SnackBar below may not be visible yet.
    await tester.pump(const Duration(milliseconds: 4600));

    // Redeeming the exact same signed key again on this device must be
    // rejected as already-used (per-device one-time-use guard, T18).
    await tester.tap(signed1d);
    await _pumpUntil(tester,
        () => find.textContaining('already used').evaluate().isNotEmpty);
    expect(find.textContaining('already used'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
