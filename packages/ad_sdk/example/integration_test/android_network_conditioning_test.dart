import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline transition blocks loads and reconnect recovers', (
    tester,
  ) async {
    app.main();
    await tester.pump();

    for (var i = 0; i < 120 && !AdManager().isInitialised; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(AdManager().isInitialised, isTrue);
    await AdManager().vip?.revokeAll();

    final skips = <AdSkipEvent>[];
    final subscription = AdManager().events.listen((event) {
      if (event is AdSkipEvent) skips.add(event);
    });
    addTearDown(subscription.cancel);

    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(false);
    await tester.pump(const Duration(milliseconds: 20));
    expect(AdManager().isConnected, isFalse);

    bool? loaded;
    await AdManager().loadAppOpenAd(onAdLoaded: (result) => loaded = result);
    await tester.pump();
    expect(loaded, isFalse);
    expect(
      skips.any(
        (event) => event.action == 'load' && event.reason == 'no_network',
      ),
      isTrue,
    );

    AdManager().debugConnectivityChanged(true);
    AdManager().debugConnectivityReady = true;
    await tester.pump(const Duration(milliseconds: 100));
    expect(AdManager().isConnected, isTrue);

    final slot = AdManager().adapter!.appOpenSlot;
    for (var i = 0; i < 40 && !slot.isReady; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(AdManager().isInitialised, isTrue);
    expect(tester.takeException(), isNull);
  });
}
