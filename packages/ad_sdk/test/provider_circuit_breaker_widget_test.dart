import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('health widget can render the circuit state', (tester) async {
    final advisor =
        ProviderFailoverAdvisor(consecutiveFailureThreshold: 1, persist: false);
    await advisor.ready;
    await tester.pumpWidget(MaterialApp(
      home: Text('state=${advisor.circuitState.name}'),
    ));
    expect(find.text('state=closed'), findsOneWidget);
    await advisor.dispose();
  });
}
