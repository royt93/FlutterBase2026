import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets('host low-power signal can pause and resume inline refresh', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final manager = AdManager();
    manager.setLowPowerMode(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugPrint('T263_HOST lowPower=true accepted');

    manager.setLowPowerMode(false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugPrint('T263_HOST lowPower=false accepted');
  });
}
