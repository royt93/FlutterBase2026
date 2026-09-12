import 'dart:ui' as ui;

import 'package:applovin_admob_sdk/src/core/ad_crash_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T206 device smoke: guard restores host platform handler',
      (tester) async {
    bool hostHandler(Object _, StackTrace __) => true;
    ui.PlatformDispatcher.instance.onError = hostHandler;
    installAdCrashGuard();
    uninstallAdCrashGuard();
    expect(
        identical(ui.PlatformDispatcher.instance.onError, hostHandler), isTrue);
    await tester.pump();
  });
}
