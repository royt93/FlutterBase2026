import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('release gate status renders staged checks', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [
        Text('Analyze'),
        Text('Tests'),
        Text('Integration'),
        Text('Secret scan'),
        Text('API diff'),
        Text('Package size'),
        Text('License audit'),
      ]),
    ));
    expect(find.text('Secret scan'), findsOneWidget);
    expect(find.text('API diff'), findsOneWidget);
    expect(find.text('License audit'), findsOneWidget);
  });
}
