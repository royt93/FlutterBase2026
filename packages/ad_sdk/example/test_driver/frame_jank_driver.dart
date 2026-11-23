import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  return integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final timeline = Timeline.fromJson(
        data['frame_jank_feed'] as Map<String, dynamic>,
      );
      final summary = TimelineSummary.summarize(timeline);
      await summary.writeTimelineToFile(
        'frame_jank_feed',
        pretty: true,
        includeSummary: true,
      );
    },
  );
}
