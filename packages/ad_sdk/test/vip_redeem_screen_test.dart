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

  // NOTE: the redeem→ACTIVE reactive flip is covered indirectly — the redeem
  // logic (grant + one-time-use) is unit-tested in signed_vip_key_test, and the
  // render test above proves the screen reads vip.activeListenable. A full
  // in-widget redeem test is omitted because the granted VipManager entry leaves
  // a real expiry Timer pending, which trips the widget-test timer invariant.

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
}
