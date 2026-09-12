import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('support widget renders bounded diagnostics export',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FutureBuilder<String>(
        future: AdManager().exportSafeDiagnostics(maxBytes: 1024),
        builder: (context, snapshot) => Text(snapshot.data ?? 'loading'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('schemaVersion'), findsOneWidget);
    expect(find.textContaining('sha256'), findsOneWidget);
  });
}
