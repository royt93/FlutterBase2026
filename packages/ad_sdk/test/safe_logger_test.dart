// Unit tests for SafeLogger.critical — the one log path meant to bypass
// AdLogLevel.none (see AdSafetyConfig's R12-A dryRun release guard).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SafeLogger.resetForTest);

  test('critical() still reaches onLog when level is none', () {
    final captured = <String>[];
    SafeLogger.configure(
      level: AdLogLevel.none,
      onLog: (level, tag, message) => captured.add(message),
    );

    SafeLogger.critical('Tag', 'boom');

    expect(captured, ['boom']);
  });

  test('e() is suppressed when level is none (contrast case)', () {
    final captured = <String>[];
    SafeLogger.configure(
      level: AdLogLevel.none,
      onLog: (level, tag, message) => captured.add(message),
    );

    SafeLogger.e('Tag', 'boom');

    expect(captured, isEmpty);
  });

  test('critical() still honors tagFilter', () {
    final captured = <String>[];
    SafeLogger.configure(
      level: AdLogLevel.none,
      tagFilter: const ['AllowedTag'],
      onLog: (level, tag, message) => captured.add(message),
    );

    SafeLogger.critical('OtherTag', 'boom');
    expect(captured, isEmpty);

    SafeLogger.critical('AllowedTag', 'ok');
    expect(captured, ['ok']);
  });

  test(
      'critical() is a safe no-op (current documented behavior) when no host '
      'ever configured an onLog sink', () {
    // No SafeLogger.configure(onLog: ...) call in this test — _sink is null,
    // exactly like a host that never wired one up. critical()'s "always
    // reaches the host" guarantee silently degrades to debugPrint-only in
    // this case; this test documents that gap rather than asserting a
    // stronger guarantee that doesn't exist yet.
    expect(() => SafeLogger.critical('Tag', 'no sink configured'),
        returnsNormally);
  });
}
