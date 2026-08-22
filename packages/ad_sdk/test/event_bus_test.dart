// m1 — the replay path in `SimpleEventBus.listen` had no guard while `fire`
// did, so a throwing listener escaped through `listen()` into its caller.
//
// That caller is, by the documented integration contract (README step 3), a
// `listen()` line inside the consuming app's splash screen: the SDK tells apps
// to subscribe there so they catch init completion. An unguarded throw there
// takes down the splash — strictly worse than the missed event the replay was
// added to prevent.

import 'package:applovin_admob_sdk/src/core/event_bus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => SimpleEventBus().clearAll());
  tearDown(() => SimpleEventBus().clearAll());

  test('a throwing late subscriber does not blow up listen()', () {
    final bus = SimpleEventBus();
    bus.fire(const BoolEvent(true));

    // Subscribing AFTER the event fired triggers the replay. Revert the
    // try/catch in listen() and this line throws instead of returning.
    expect(() => bus.listen((_) => throw StateError('bad subscriber')),
        returnsNormally);
  });

  test('a throwing late subscriber does not stop the next one from replaying',
      () {
    final bus = SimpleEventBus();
    bus.fire(const BoolEvent(true));

    bus.listen((_) => throw StateError('bad subscriber'));

    BoolEvent? received;
    bus.listen((e) => received = e);
    expect(received?.value, true,
        reason: 'the bad subscriber must not poison the bus for later ones');
  });

  test('a throwing listener still gets its replay attempted, not skipped', () {
    final bus = SimpleEventBus();
    bus.fire(const BoolEvent(false));

    var called = false;
    bus.listen((_) {
      called = true;
      throw StateError('bad subscriber');
    });
    expect(called, true,
        reason: 'swallowing the error must not mean skipping the delivery');
  });

  test('fire still reaches every listener when one throws', () {
    final bus = SimpleEventBus();
    bus.listen((_) => throw StateError('bad subscriber'));

    var secondSaw = false;
    bus.listen((_) => secondSaw = true);

    bus.fire(const BoolEvent(true));
    expect(secondSaw, true);
  });
}
