import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('InFeedIndexCalculator converts indices correctly', () {
    // adInterval = 4
    // Raw indices:
    // raw 0 -> item 0
    // raw 1 -> item 1
    // raw 2 -> item 2
    // raw 3 -> item 3
    // raw 4 -> ad 0 (after 4 items)
    // raw 5 -> item 4
    // raw 6 -> item 5
    // raw 7 -> item 6
    // raw 8 -> item 7
    // raw 9 -> ad 1 (after 8 items)
    // raw 10 -> item 8

    expect(InFeedIndexCalculator.isAdPosition(0, adInterval: 4), isFalse);
    expect(InFeedIndexCalculator.isAdPosition(3, adInterval: 4), isFalse);
    expect(InFeedIndexCalculator.isAdPosition(4, adInterval: 4), isTrue);
    expect(InFeedIndexCalculator.isAdPosition(5, adInterval: 4), isFalse);
    expect(InFeedIndexCalculator.isAdPosition(8, adInterval: 4), isFalse);
    expect(InFeedIndexCalculator.isAdPosition(9, adInterval: 4), isTrue);

    expect(InFeedIndexCalculator.toOriginalItemIndex(0, adInterval: 4), equals(0));
    expect(InFeedIndexCalculator.toOriginalItemIndex(1, adInterval: 4), equals(1));
    expect(InFeedIndexCalculator.toOriginalItemIndex(3, adInterval: 4), equals(3));
    expect(InFeedIndexCalculator.toOriginalItemIndex(5, adInterval: 4), equals(4));
    expect(InFeedIndexCalculator.toOriginalItemIndex(8, adInterval: 4), equals(7));
    expect(InFeedIndexCalculator.toOriginalItemIndex(10, adInterval: 4), equals(8));

    expect(InFeedIndexCalculator.totalCount(itemCount: 0, adInterval: 4), equals(0));
    expect(InFeedIndexCalculator.totalCount(itemCount: 3, adInterval: 4), equals(3));
    expect(InFeedIndexCalculator.totalCount(itemCount: 4, adInterval: 4), equals(5)); // 4 items + 1 ad
    expect(InFeedIndexCalculator.totalCount(itemCount: 8, adInterval: 4), equals(10)); // 8 items + 2 ads
    expect(InFeedIndexCalculator.totalCount(itemCount: 9, adInterval: 4), equals(11)); // 9 items + 2 ads
  });

  testWidgets('InFeedAdListView renders items and native ad widgets at intervals', (tester) async {
    final originalItems = List.generate(20, (i) => 'Item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InFeedAdListView.builder(
            itemCount: originalItems.length,
            adInterval: 5,
            itemBuilder: (context, index) {
              return SizedBox(
                height: 50,
                child: Text('Rendered: ${originalItems[index]}'),
              );
            },
            adBuilder: (context, adIndex) {
              return SizedBox(
                height: 100,
                child: Text('Ad Position $adIndex'),
              );
            },
          ),
        ),
      ),
    );

    // Initial view should render Items 0..4, then Ad 0, then Item 5...
    expect(find.text('Rendered: Item 0'), findsOneWidget);
    expect(find.text('Rendered: Item 4'), findsOneWidget);
    expect(find.text('Ad Position 0'), findsOneWidget);
    expect(find.text('Rendered: Item 5'), findsOneWidget);

    // Scroll down to reveal more items and the next ad
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('Ad Position 1'), findsOneWidget);
  });

  testWidgets('InFeedAdListView disposes off-screen native ads when scrolled away', (tester) async {
    var disposedCount = 0;
    final originalItems = List.generate(40, (i) => 'Item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InFeedAdListView.builder(
            itemCount: originalItems.length,
            adInterval: 5,
            itemBuilder: (context, index) {
              return SizedBox(
                height: 100,
                child: Text('Content: ${originalItems[index]}'),
              );
            },
            adBuilder: (context, adIndex) {
              return _DisposalTrackerWidget(
                onDispose: () => disposedCount++,
                child: SizedBox(
                  height: 100,
                  child: Text('Tracked Ad $adIndex'),
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('Tracked Ad 0'), findsOneWidget);
    expect(disposedCount, equals(0));

    // Scroll far down so Tracked Ad 0 is recycled and unmounted
    await tester.drag(find.byType(ListView), const Offset(0, -2500));
    await tester.pumpAndSettle();

    expect(find.text('Tracked Ad 0'), findsNothing);
    expect(disposedCount, greaterThan(0));
  });
}

class _DisposalTrackerWidget extends StatefulWidget {
  const _DisposalTrackerWidget({required this.child, required this.onDispose});
  final Widget child;
  final VoidCallback onDispose;

  @override
  State<_DisposalTrackerWidget> createState() => _DisposalTrackerWidgetState();
}

class _DisposalTrackerWidgetState extends State<_DisposalTrackerWidget> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
