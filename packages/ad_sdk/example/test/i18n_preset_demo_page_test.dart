// T219 — I18nPresetDemoPage: switching the segmented control must actually
// re-render the CCPA toggle and VIP dialog strings preview with the
// newly-selected preset's real text — not just flip a label.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host() => const MaterialApp(home: I18nPresetDemoPage());

  testWidgets('starts on English — shows English CCPA/VIP text',
      (tester) async {
    await tester.pumpWidget(host());

    expect(
        find.text('Do Not Sell or Share My Personal Information'),
        findsOneWidget);
    expect(find.textContaining('successTitle: VIP Activated'),
        findsOneWidget);
  });

  testWidgets('switching to Tiếng Việt re-renders CCPA/VIP text in '
      'Vietnamese', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('Tiếng Việt'));
    await tester.pump();

    expect(
        find.text('Không bán hoặc chia sẻ thông tin cá nhân của tôi'),
        findsOneWidget);
    expect(find.textContaining('successTitle: Kích hoạt thành công'),
        findsOneWidget);
    expect(find.text('Do Not Sell or Share My Personal Information'),
        findsNothing);
  });

  testWidgets('opening the VIP redeem screen shows the currently-selected '
      'preset\'s text', (tester) async {
    // The button is further down the page than the default 600px-tall test
    // surface shows.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.tap(find.text('Tiếng Việt'));
    await tester.pump();

    await tester.ensureVisible(find.text('Open VIP redeem screen'));
    await tester.tap(find.text('Open VIP redeem screen'));
    // Not pumpAndSettle(): VipRedeemScreen runs its own periodic VIP-status
    // timer, which never quiesces — mirrors vip_redeem_screen_test.dart's
    // own bounded-pump pattern.
    await tester.pump(); // process the route push
    await tester.pump(const Duration(milliseconds: 300));

    // No AdManager/VipManager is wired up in this test (this page is only
    // reachable pre-SDK-init in the test harness), so the screen falls
    // back to its "SDK not ready" state rather than the redeem form — but
    // that fallback text is itself part of VipRedeemStrings, so it still
    // proves the Vietnamese preset actually reached this screen.
    expect(find.byType(VipRedeemScreen), findsOneWidget);
    expect(find.text(VipRedeemStrings.vi.sdkNotReady), findsOneWidget);
    expect(find.text(VipRedeemStrings.en.sdkNotReady), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
