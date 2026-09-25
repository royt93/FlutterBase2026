import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T204 device smoke: sensitive log fields are redacted',
      (tester) async {
    final messages = <String>[];
    SafeLogger.configure(onLog: (_, _, message) => messages.add(message));
    SafeLogger.d('Smoke', 'GAID=device-secret VIP_CODE=vip-secret');
    await tester.pump();
    expect(messages.single, contains('GAID=<redacted>'));
    expect(messages.single, contains('VIP_CODE=<redacted>'));
    expect(messages.single, isNot(contains('device-secret')));
    expect(messages.single, isNot(contains('vip-secret')));
    SafeLogger.resetForTest();
  });
}
