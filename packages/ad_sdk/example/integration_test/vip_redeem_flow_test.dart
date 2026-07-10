// On-device integration test for the VIP redeem flow end-to-end (test gap
// #10 companion — the widget test covers the screen in isolation; this
// drives the REAL VipRedeemScreen mounted inside the real running app,
// backed by the real native shared_preferences plugin, and proves the
// redeem → VipManager → AdManager wiring actually suppresses ads afterward.
//
// Run with:
//   flutter test integration_test/vip_redeem_flow_test.dart -d <device-or-sim-id>

import 'dart:convert';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _ed = Ed25519();

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mint(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final payload = utf8.encode('$seconds|$kid');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'redeeming a signed VIP key via the real screen flips VIP active and '
      'suppresses interstitials', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Splash shows a hard-capped App-Open ad then replaces itself with the
    // real Home route on the ROOT navigator — pushing on top of Splash too
    // early races that replace and gets wiped out. Wait for a Home landmark
    // before doing anything with the navigator.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('VIP / redeem').evaluate().isNotEmpty) break;
    }
    expect(find.text('VIP / redeem'), findsOneWidget);

    // Fresh installs may auto-grant a first-install VIP grace window (see
    // DemoConfig.firstInstallVipGrace) — revoke to get a deterministic
    // starting point regardless of this device's install history.
    await AdManager().vip!.revokeAll();
    await tester.pump();
    expect(AdManager().isVIPMember(), isFalse);
    expect(AdManager().canShowInterstitial, isNotNull);

    final keyPair = await _ed.newKeyPair();
    final pub = await _pubB64(keyPair);
    final code = await _mint(keyPair, seconds: 120, kid: 'integration_kid');

    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute(
      builder: (_) => VipRedeemScreen(publicKeyBase64: pub),
    ));
    // VipRedeemScreen has a repeating pulse AnimationController (see
    // vip_redeem_screen_test.dart) — pumpAndSettle never quiesces against it,
    // so advance a fixed duration instead (entry stagger anim is ~1100ms).
    await tester.pump(const Duration(milliseconds: 1200));

    // Off-screen ListView children aren't built at all (find.byType would
    // match 0), so the redeem TextField needs a real scroll-and-recheck loop
    // to bring it into the tree — not just a single ensureVisible, which
    // requires the finder to already match something.
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), code);
    await tester.pump();

    // ACTIVATE is already built (same viewport window as the TextField) —
    // a precise scroll instead of scrollUntilVisible's fixed-increment
    // drags, which previously overshot and left the tap offset stale
    // against the post-keyboard layout. alignment: 0.5 centers it so it
    // isn't left sitting right under the AppBar/status bar edge (tester's
    // ensureVisible() has no alignment param, so call Scrollable directly).
    await Scrollable.ensureVisible(
      tester.element(find.text('ACTIVATE')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('VIP ACTIVE'), findsOneWidget);
    expect(AdManager().isVIPMember(), isTrue);
    expect(AdManager().canShowInterstitial(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
