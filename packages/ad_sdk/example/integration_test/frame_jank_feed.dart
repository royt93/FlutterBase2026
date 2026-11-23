// Frame-time measurement for an SDK-driven scroll (InFeedAdListView) with the
// AdLoadingDialog shown/hidden mid-scroll. Engine numbers (build + raster
// per frame), not a proof that frames were presented, and not a T267 result.
//
// Run in PROFILE mode (debug numbers are meaningless):
//   flutter drive --profile --no-dds \
//     --driver=test_driver/frame_jank_driver.dart \
//     --target=integration_test/frame_jank_feed.dart -d <device-id>
//
// Not named *_test.dart on purpose: CI globs integration_test/*_test.dart and
// this needs `flutter drive --profile`, which CI does not run.
// Output: build/frame_jank_feed.timeline_summary.json (per run). Do not use
// as a CI gate: the number depends on the device.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scroll feed while loading dialog toggles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              return InFeedAdListView.builder(
                itemCount: 200,
                adInterval: 5,
                itemBuilder: (_, i) => ListTile(
                  title: Text('Feed Item #$i'),
                  subtitle: const Text('row'),
                ),
                adBuilder: (_, i) => Container(
                  height: 120,
                  color: Colors.amber[100],
                  alignment: Alignment.center,
                  child: Text('Ad slot #$i'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> scroll(double dy) async {
      await tester.fling(find.byType(ListView), Offset(0, dy), 3000);
      await tester.pumpAndSettle();
    }

    await binding.traceAction(() async {
      for (var pass = 0; pass < 4; pass++) {
        await scroll(-900);
      }
      // The dialog's spinner never settles and its scrim blocks input, so
      // measure it by pumping real time instead of flinging / settling.
      AdLoadingDialog.show(tester.element(find.byType(ListView)));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      AdLoadingDialog.dismiss();
      await tester.pumpAndSettle();
      for (var pass = 0; pass < 4; pass++) {
        await scroll(900);
      }
    }, reportKey: 'frame_jank_feed');
    expect(tester.takeException(), isNull);
  });
}
