// T115 — unit tests for the AsyncEpoch primitive. This does NOT test any
// migrated call site (none exist yet, deliberately — see the class doc).

import 'package:applovin_admob_sdk/src/utils/async_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a fresh epoch starts at generation 0, not disposed', () {
    final epoch = AsyncEpoch();
    expect(epoch.token, 0);
    expect(epoch.isCurrent(0), isTrue);
    expect(epoch.isDisposed, isFalse);
  });

  test('invalidate() bumps the generation, stale tokens stop being current',
      () {
    final epoch = AsyncEpoch();
    final staleToken = epoch.token;

    epoch.invalidate();

    expect(epoch.isCurrent(staleToken), isFalse,
        reason: 'a token captured before invalidate() must be stale after');
    expect(epoch.isCurrent(epoch.token), isTrue,
        reason: 'the NEW current token must still read as current');
  });

  test('the classic pattern: capture token, await, check isCurrent', () async {
    final epoch = AsyncEpoch();
    final token = epoch.token;

    // Simulates a newer call superseding this one while we were awaiting
    // something (e.g. a native platform-channel round trip).
    Future<void>.delayed(Duration.zero).then((_) => epoch.invalidate());
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(epoch.isCurrent(token), isFalse,
        reason: 'work started before the supersede must see itself as '
            'stale once it resumes');
  });

  test('dispose() is a permanent, one-way invalidation', () {
    final epoch = AsyncEpoch();
    final token = epoch.token;
    epoch.dispose();

    expect(epoch.isDisposed, isTrue);
    expect(epoch.isCurrent(token), isFalse);
    expect(epoch.isCurrent(epoch.token), isFalse,
        reason: 'unlike invalidate(), there is no new "current" generation '
            'to become current after dispose() — everything is stale');
  });

  test('dispose() is idempotent — calling it twice does not throw or bump '
      'generation further', () {
    final epoch = AsyncEpoch();
    epoch.dispose();
    final genAfterFirstDispose = epoch.token;
    epoch.dispose();
    expect(epoch.token, genAfterFirstDispose);
  });

  test('invalidate() after dispose() is a no-op, not a resurrection', () {
    final epoch = AsyncEpoch();
    epoch.dispose();
    epoch.invalidate();
    expect(epoch.isDisposed, isTrue);
    expect(epoch.isCurrent(epoch.token), isFalse);
  });
}
