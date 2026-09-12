import 'dart:ui' as ui;

import 'package:applovin_admob_sdk/src/core/ad_crash_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(uninstallAdCrashGuard);

  testWidgets('widget build can install and uninstall guard safely',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (_) {
        installAdCrashGuard();
        return const Text('guard-ready');
      }),
    ));
    expect(find.text('guard-ready'), findsOneWidget);
    uninstallAdCrashGuard();
    expect(ui.PlatformDispatcher.instance.onError, isNull);
  });
}
