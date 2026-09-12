import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SafeLogger.resetForTest);

  testWidgets('a widget-triggered log never exposes a device identifier',
      (tester) async {
    final messages = <String>[];
    SafeLogger.configure(onLog: (_, __, message) => messages.add(message));
    await tester.pumpWidget(MaterialApp(
      home: ElevatedButton(
        onPressed: () => SafeLogger.d('Widget', 'idfa=widget-secret'),
        child: const Text('log'),
      ),
    ));
    await tester.tap(find.text('log'));
    expect(messages.single, 'idfa=<redacted>');
  });
}
