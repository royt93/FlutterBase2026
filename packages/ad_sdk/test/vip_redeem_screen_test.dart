// Widget tests for the shared VipRedeemScreen (used identically by the host and
// the SDK example). Verifies it renders the inactive state, and that redeeming
// a valid signed key via the UI flips the hero to the active state.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ed = Ed25519();

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mint(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final payload = utf8.encode('$seconds|$kid');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;
  late String pub;
  late VipManager vip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await VipManager(prefs).revokeAll();
    keyPair = await _ed.newKeyPair();
    pub = await _pubB64(keyPair);
    vip = VipManager(prefs);
    await vip.load();
    AdManager().debugVipManager = vip;
  });

  tearDown(() {
    AdManager().debugVipManager = null;
    vip.dispose();
  });

  // Tall surface so the whole ListView (hero → redeem → watch-ad → buy) is
  // built and tappable (default 800×600 leaves lower sections unbuilt).
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders inactive state with redeem + watch-ad + buy sections',
      (tester) async {
    useTallSurface(tester);
    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('VIP NOT ACTIVE'), findsOneWidget);
    expect(find.text('Enter VIP key'), findsOneWidget);
    expect(find.text('Watch ad → free VIP'), findsOneWidget);
    expect(find.text('Buy VIP'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'entering a valid signed key and tapping Activate flips the hero '
      'to VIP ACTIVE', (tester) async {
    useTallSurface(tester);
    final code = await _mint(keyPair, seconds: 1, kid: 'k1');

    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    // `onPressed` awaits a real SharedPreferences write (VipManager._save).
    // Under AutomatedTestWidgetsFlutterBinding that Future never resolves
    // from inside a tap-dispatched callback — flutter_test's documented
    // escape hatch is runAsync(), which runs a real event-loop turn outside
    // the test's synthetic time so the platform-channel reply is delivered.
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50),
        ));
    await tester.pump();

    expect(find.text('VIP ACTIVE'), findsOneWidget);
    expect(find.text('VIP NOT ACTIVE'), findsNothing);

    // VipManager.isActive/expiresAt is checked against real DateTime.now(),
    // not the fake_async clock pump() advances — so pump() alone lets the
    // expiry Timer *fire* without the entry actually being real-time expired
    // yet, which just re-arms another Timer (leaked at teardown). runAsync()
    // genuinely sleeps past the 1s grant so the entry is really expired by
    // the time the Timer's virtual delay elapses below.
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 1100),
        ));
    await tester.pump(const Duration(seconds: 1, milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'entering a garbage key shows the invalid-key SnackBar and keeps the '
      'field populated (only the success branch clears it)', (tester) async {
    useTallSurface(tester);
    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), 'not-a-real-key');
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('The VIP key you entered is invalid or expired.'),
        findsOneWidget);
    expect(find.text('VIP ACTIVE'), findsNothing);
    expect(find.text('not-a-real-key'), findsOneWidget,
        reason: 'field only clears on the success branch');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'redeeming the same signed key twice shows the already-used SnackBar '
      'on the second attempt and leaves the first activation intact',
      (tester) async {
    useTallSurface(tester);
    final code = await _mint(keyPair, seconds: 2, kid: 'reuse-k1');

    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 1200));

    // First redeem succeeds.
    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('VIP ACTIVE'), findsOneWidget);
    // Clear the first SnackBar ("VIP activated") outright — Scaffold-
    // Messenger otherwise queues the second showSnackBar call behind it,
    // and its dismiss animation timing is brittle to fake-clock pumping.
    ScaffoldMessenger.of(tester.element(find.byType(VipRedeemScreen)))
        .clearSnackBars();
    await tester.pump();

    // Second redeem of the identical key is rejected — ledger (T30) already
    // recorded its kid.
    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('This key has already been used on this device.'),
        findsOneWidget);
    expect(find.text('VIP ACTIVE'), findsOneWidget,
        reason: 'the first, successful activation must still stand');
    expect(find.text(code), findsOneWidget,
        reason: 'alreadyUsed branch does not clear the field');
    expect(tester.takeException(), isNull);

    // Let the short-lived grant actually expire in real time so VipManager's
    // expiry Timer fires and clears itself — otherwise flutter_test's
    // end-of-test invariant check flags it as a leaked pending Timer.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('privacy footer hidden when no onPrivacyPolicyTap',
      (tester) async {
    useTallSurface(tester);
    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Privacy Policy'), findsNothing);

    await tester.pumpWidget(MaterialApp(
        home:
            VipRedeemScreen(publicKeyBase64: pub, onPrivacyPolicyTap: () {})));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('privacy-options footer hidden when no onPrivacyOptionsTap',
      (tester) async {
    useTallSurface(tester);
    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Privacy Options'), findsNothing);

    await tester.pumpWidget(MaterialApp(
        home:
            VipRedeemScreen(publicKeyBase64: pub, onPrivacyOptionsTap: () {})));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Privacy Options'), findsOneWidget);
  });

  testWidgets('tapping privacy-options footer invokes onPrivacyOptionsTap',
      (tester) async {
    useTallSurface(tester);
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
        home: VipRedeemScreen(
            publicKeyBase64: pub, onPrivacyOptionsTap: () => tapped = true)));
    // Entry stagger animation is 1100ms; a repeating pulse controller means
    // pumpAndSettle never quiesces, so advance a fixed duration instead.
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.tap(find.text('Privacy Options'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
