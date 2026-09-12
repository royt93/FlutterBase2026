import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T207 device smoke: repeated destroy remains safe',
      (tester) async {
    final manager = AdManager();
    await manager.destroy();
    await manager.destroy();
    await tester.pump();
    expect(manager.isInitialised, isFalse);
  });
}
