// Widget test for VipDemoPage's T156 fix: "Watch ad -> +3 days VIP (stack)"
// now goes through showRewardedAd() (the documented AdScreenState helper),
// not AdManager().showRewardedAd() directly — proving the helper's
// bypassVipGuard forwarding works via the real page, not just the isolated
// unit test in test/ad_screen_test.dart. Needs a real, initialised adapter
// to actually show anything — this only pins the pre-init fallback path
// (converting VipDemoPage from StatefulWidget to AdScreen must not have
// broken it) doesn't crash the page.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'Watch ad -> +3 days VIP (stack) button exists and tapping it before '
      'SDK init does not crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: VipDemoPage()));
    await tester.pump();

    final button = find.text('Watch ad → +3 days VIP (stack)');
    await tester.scrollUntilVisible(button, 300,
        scrollable: find.byType(Scrollable).first,
        duration: const Duration(milliseconds: 50));
    // scrollUntilVisible stops as soon as the item is *any* fraction
    // visible, which can still land its center a few px past the fold —
    // nudge one more full page down to be safely centered.
    await tester.drag(
        find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();

    await tester.tap(button);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
