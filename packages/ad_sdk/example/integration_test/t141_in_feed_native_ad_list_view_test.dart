import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T141: InFeedAdListView scrolls and mounts/recycles on physical device', (tester) async {
    final items = List.generate(30, (i) => 'Feed Item #$i');
    var adBuildCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('InFeedAdListView Integration Test')),
          body: InFeedAdListView.builder(
            itemCount: items.length,
            adInterval: 5,
            itemBuilder: (context, index) {
              return Container(
                height: 80,
                color: index.isEven ? Colors.grey[200] : Colors.white,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(items[index], style: const TextStyle(fontSize: 16)),
              );
            },
            adBuilder: (context, adIndex) {
              adBuildCount++;
              return Container(
                height: 120,
                color: Colors.amber[100],
                alignment: Alignment.center,
                child: Text('In-Feed Native Ad Slot #$adIndex'),
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial viewport contains first items and first ad
    expect(find.text('Feed Item #0'), findsOneWidget);
    expect(find.text('Feed Item #4'), findsOneWidget);
    expect(find.text('In-Feed Native Ad Slot #0'), findsOneWidget);

    // Scroll down to trigger recycling and mount next ad slot
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();

    expect(find.text('In-Feed Native Ad Slot #1'), findsOneWidget);
    expect(adBuildCount, greaterThanOrEqualTo(2));
  });
}
