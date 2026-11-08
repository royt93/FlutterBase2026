// Example-app regression for audit round 79: privacy settings must be reachable
// from the demo home page without opening the VIP screen.

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home exposes privacy settings and honest signed-key copy', (
    tester,
  ) async {
    app.main();
    await tester.pump();

    final home = find.text('ad_sdk demo');
    for (var i = 0; i < 90 && home.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(home, findsOneWidget);
    await AdManager().vip?.revokeAll();
    await tester.pump(const Duration(milliseconds: 300));

    final privacyTile = find.text('Privacy settings');
    await tester.scrollUntilVisible(
      privacyTile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(privacyTile);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Privacy Options'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(tester.takeException(), isNull);

    Navigator.of(tester.element(find.text('Privacy Options'))).pop();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
  });
}
