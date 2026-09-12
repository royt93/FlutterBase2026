import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('matrix target renders platform/provider label', (tester) async {
    final target = CompatibilityMatrix.minimum[0];
    await tester
        .pumpWidget(const MaterialApp(home: Text('android · admob · API 34')));
    expect(find.textContaining(target.platform.name), findsOneWidget);
    expect(find.textContaining(target.provider.name), findsOneWidget);
  });
}
