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

  test('critical() ignores tagFilter too', () {
    // Round-25 QC round 4 — this used to assert the opposite, and `codex` and
    // `claude` both made it their top deduction. `critical` replaced two
    // `assert`s that no logger configuration could silence; honouring the tag
    // filter meant a host whose filter did not list `AdManager` lost the "no
    // consent flow configured" warning entirely, i.e. the replacement was
    // weaker than the assert on the one diagnostic with a legal consequence.
    final captured = <String>[];
    SafeLogger.configure(
      level: AdLogLevel.none,
      tagFilter: const ['AllowedTag'],
      onLog: (level, tag, message) => captured.add(message),
    );

    SafeLogger.critical('OtherTag', 'boom');
    SafeLogger.critical('AllowedTag', 'ok');
    expect(captured, ['boom', 'ok']);

    // The contrast case: an ordinary error is still scoped by the filter, so
    // this is not "the filter stopped working".
    captured.clear();
    SafeLogger.configure(
      level: AdLogLevel.verbose,
      tagFilter: const ['AllowedTag'],
      onLog: (level, tag, message) => captured.add(message),
    );
    SafeLogger.e('OtherTag', 'filtered');
    SafeLogger.e('AllowedTag', 'kept');
    expect(captured, ['kept']);
  });

  test('a log message builder that throws cannot take the caller down', () {
    // Pins the second half of `_emit`'s guard (`agy`, round 4): every `d()`
    // call site in the SDK passes a lambda, several of them interpolating
    // adapter state — which is exactly what is broken in the situations worth
    // logging. Deleting the try/catch around `_resolve` makes this red.
    final captured = <String>[];
    SafeLogger.configure(
      onLog: (level, tag, message) => captured.add(message),
    );

    expect(
        () => SafeLogger.d('Tag', () => throw StateError('interpolation blew up')),
        returnsNormally);
    expect(captured, hasLength(1));
    expect(captured.single, contains('threw while being built'));
  });

  test('an onLog sink that throws cannot take the caller down', () {
    // The other half of the same guard (`codex`, round 3). A host wrapper
    // around Crashlytics/Sentry that throws used to make EVERY SafeLogger
    // call a throw site, including the ones inside teardown `catch` blocks.
    SafeLogger.configure(
      onLog: (level, tag, message) => throw StateError('sink blew up'),
    );

    expect(() => SafeLogger.w('Tag', 'anything'), returnsNormally);
    expect(() => SafeLogger.critical('Tag', 'anything'), returnsNormally);
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
