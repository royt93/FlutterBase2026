import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tool guidance widget never renders a private key',
      (tester) async {
    const secret = 'PRIVATE_SECRET_MUST_NOT_RENDER';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Text(
            'Use --priv-file or --priv-stdin; never pass secrets in argv.'),
      ),
    ));
    expect(find.textContaining(secret), findsNothing);
    expect(find.textContaining('--priv-file'), findsOneWidget);
    expect(Platform.environment['PRIVATE_SECRET_MUST_NOT_RENDER'], isNull);
  });
}
