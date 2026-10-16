import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app pause and resume handles ad lifecycle without crashes', (
    tester,
  ) async {
    app.main();
    await tester.pump();

    for (var i = 0; i < 120 && !AdManager().isInitialised; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(AdManager().isInitialised, isTrue);

    // Giả lập app chuyển trạng thái background (paused)
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump(const Duration(milliseconds: 500));

    // Giả lập app quay lại màn hình foreground (resumed)
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(AdManager().isInitialised, isTrue);
    expect(tester.takeException(), isNull);
  });
}
