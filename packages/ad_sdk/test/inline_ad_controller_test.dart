// T201 — InlineAdController's own attach/detach/command bookkeeping, in
// isolation from any real BannerAdWidget/MrecAdWidget/NativeAdWidget: a
// fake InlineAdControllerTarget records exactly which commands it received
// and in what final state, so this can pin "command serialization" (calls
// made before anything attaches are coalesced into the right final state,
// not lost and not replayed as a literal call-for-call log) without
// spinning up a widget tree at all.

import 'package:applovin_admob_sdk/src/widget/inline_ad_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTarget implements InlineAdControllerTarget {
  int refreshCalls = 0;
  final List<bool> pauseCalls = [];

  @override
  void controllerRefresh() => refreshCalls++;

  @override
  void controllerSetPaused(bool paused) => pauseCalls.add(paused);
}

void main() {
  group('InlineAdController — attach state', () {
    test('starts detached', () {
      final controller = InlineAdController();
      expect(controller.status, InlineAdControllerStatus.detached);
      expect(controller.isAttached, isFalse);
      controller.dispose();
    });

    test('attach() flips status to active', () {
      final controller = InlineAdController();
      final target = _FakeTarget();

      controller.attach(target);

      expect(controller.status, InlineAdControllerStatus.active);
      expect(controller.isAttached, isTrue);
      controller.dispose();
    });

    test('detach() flips status back to detached', () {
      final controller = InlineAdController();
      final target = _FakeTarget();
      controller.attach(target);

      controller.detach(target);

      expect(controller.status, InlineAdControllerStatus.detached);
      controller.dispose();
    });

    test('detach() with a different (stale) target is a no-op', () {
      final controller = InlineAdController();
      final current = _FakeTarget();
      final stale = _FakeTarget();
      controller.attach(current);

      controller.detach(stale);

      expect(controller.status, InlineAdControllerStatus.active);
      expect(controller.isAttached, isTrue);
      controller.dispose();
    });

    test('attach() to a second target while already attached asserts', () {
      final controller = InlineAdController();
      controller.attach(_FakeTarget());

      expect(() => controller.attach(_FakeTarget()), throwsAssertionError);
      controller.dispose();
    });
  });

  group('InlineAdController — refresh()', () {
    test('refresh() while attached calls the target immediately', () {
      final controller = InlineAdController();
      final target = _FakeTarget();
      controller.attach(target);

      controller.refresh();

      expect(target.refreshCalls, 1);
      controller.dispose();
    });

    test('refresh() before attach is remembered and replays exactly once '
        'on attach', () {
      final controller = InlineAdController();
      controller.refresh();

      final target = _FakeTarget();
      controller.attach(target);

      expect(target.refreshCalls, 1);
      controller.dispose();
    });

    test('multiple refresh() calls before attach coalesce into one replay '
        '(command serialization), not one call per refresh()', () {
      final controller = InlineAdController();
      controller.refresh();
      controller.refresh();
      controller.refresh();

      final target = _FakeTarget();
      controller.attach(target);

      expect(target.refreshCalls, 1);
      controller.dispose();
    });

    test('a pending refresh does not replay again on a later, unrelated '
        'attach after a detach', () {
      final controller = InlineAdController();
      controller.refresh();
      final first = _FakeTarget();
      controller.attach(first);
      expect(first.refreshCalls, 1);

      controller.detach(first);
      final second = _FakeTarget();
      controller.attach(second);

      expect(second.refreshCalls, 0);
      controller.dispose();
    });
  });

  group('InlineAdController — pause()/resume() (command serialization)', () {
    test('pause() before attach applies immediately on attach', () {
      final controller = InlineAdController();
      controller.pause();

      final target = _FakeTarget();
      controller.attach(target);

      expect(target.pauseCalls, [true]);
      expect(controller.status, InlineAdControllerStatus.paused);
      controller.dispose();
    });

    test('pause() then resume() before attach collapse to the final '
        '(unpaused) state — attach never even calls controllerSetPaused',
        () {
      final controller = InlineAdController();
      controller.pause();
      controller.resume();

      final target = _FakeTarget();
      controller.attach(target);

      expect(target.pauseCalls, isEmpty);
      expect(controller.status, InlineAdControllerStatus.active);
      controller.dispose();
    });

    test('resume() then pause() before attach collapse to paused', () {
      final controller = InlineAdController();
      controller.resume(); // already unpaused — no-op
      controller.pause();

      final target = _FakeTarget();
      controller.attach(target);

      expect(target.pauseCalls, [true]);
      expect(controller.status, InlineAdControllerStatus.paused);
      controller.dispose();
    });

    test('pause()/resume() while attached call the target directly, each '
        'exactly once even if called repeatedly', () {
      final controller = InlineAdController();
      final target = _FakeTarget();
      controller.attach(target);

      controller.pause();
      controller.pause(); // already paused — no-op
      controller.resume();
      controller.resume(); // already resumed — no-op

      expect(target.pauseCalls, [true, false]);
      controller.dispose();
    });

    test('pause() survives a detach/reattach to a new target', () {
      final controller = InlineAdController();
      final first = _FakeTarget();
      controller.attach(first);
      controller.pause();
      controller.detach(first);

      final second = _FakeTarget();
      controller.attach(second);

      expect(second.pauseCalls, [true]);
      controller.dispose();
    });
  });

  group('InlineAdController — notifyListeners', () {
    test('pause()/resume()/attach()/detach() each notify listeners', () {
      final controller = InlineAdController();
      var notifications = 0;
      controller.addListener(() => notifications++);
      final target = _FakeTarget();

      controller.attach(target);
      controller.pause();
      controller.resume();
      controller.detach(target);

      expect(notifications, 4);
      controller.dispose();
    });
  });

  group('InlineAdController — dispose() is idempotent', () {
    test('calling dispose() twice does not throw', () {
      final controller = InlineAdController();
      controller.dispose();

      expect(() => controller.dispose(), returnsNormally);
    });

    test('dispose() on a controller that never attached is safe', () {
      final controller = InlineAdController();
      expect(() => controller.dispose(), returnsNormally);
    });

    test('commands after dispose() are silently ignored, not thrown', () {
      final controller = InlineAdController();
      controller.dispose();

      expect(() => controller.refresh(), returnsNormally);
      expect(() => controller.pause(), returnsNormally);
      expect(() => controller.resume(), returnsNormally);
    });
  });
}
