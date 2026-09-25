import 'dart:ui' as ui;

import 'package:applovin_admob_sdk/src/core/ad_crash_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(uninstallAdCrashGuard);

  test('uninstall restores previous handlers', () {
    final oldFlutter = FlutterError.onError;
    final oldPlatform = ui.PlatformDispatcher.instance.onError;
    void priorFlutter(FlutterErrorDetails _) {}
    bool priorPlatform(Object _, StackTrace _) => true;
    FlutterError.onError = priorFlutter;
    ui.PlatformDispatcher.instance.onError = priorPlatform;

    installAdCrashGuard();
    expect(identical(FlutterError.onError, priorFlutter), isFalse);
    uninstallAdCrashGuard();
    expect(identical(FlutterError.onError, priorFlutter), isTrue);
    expect(identical(ui.PlatformDispatcher.instance.onError, priorPlatform),
        isTrue);

    FlutterError.onError = oldFlutter;
    ui.PlatformDispatcher.instance.onError = oldPlatform;
  });

  test('uninstall preserves a host handler that replaced the guard', () {
    void hostFlutter(FlutterErrorDetails _) {}
    bool hostPlatform(Object _, StackTrace _) => false;
    installAdCrashGuard();
    FlutterError.onError = hostFlutter;
    ui.PlatformDispatcher.instance.onError = hostPlatform;
    uninstallAdCrashGuard();
    expect(identical(FlutterError.onError, hostFlutter), isTrue);
    expect(identical(ui.PlatformDispatcher.instance.onError, hostPlatform),
        isTrue);
  });
}
