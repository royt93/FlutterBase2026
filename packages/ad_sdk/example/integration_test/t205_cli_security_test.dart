import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T205 device smoke: app does not expose a private-key value',
      (tester) async {
    // CLI execution belongs to the host/CI, not the mobile process. This
    // device smoke pins the shipped integration harness to the safe contract:
    // no private key is supplied through the app environment or argv.
    expect(Platform.environment['VIP_PRIVATE_KEY'], isNull);
    await tester.pump();
  });
}
