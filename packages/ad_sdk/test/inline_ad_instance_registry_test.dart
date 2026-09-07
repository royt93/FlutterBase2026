// T114 — shared per-key bookkeeping extracted from AdMobAdapter/
// AppLovinAdapter's banner/MREC/native maps (was hand-duplicated 3 formats
// x 2 adapters = 6 near-identical copies — the exact divergence that let
// T104 (tombstone leak) and T105 (missing click guard) exist: a fix in
// one adapter's copy was easy to forget in the other's).
//
// Deliberately does NOT test any load()/callback control flow — this class
// only replaces the map bookkeeping + "already disposed" sentinel pattern
// underneath it; each adapter keeps its own identity-check guards inline.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/inline_ad_instance_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InlineAdInstanceRegistry registry;

  setUp(() {
    registry = InlineAdInstanceRegistry(AdSlotType.banner);
  });

  group('slotByKey', () {
    test('looks up by key without creating, null if not owned', () {
      final created = registry.slotFor('k1');
      expect(identical(registry.slotByKey('k1'), created), isTrue);
      expect(registry.slotByKey('nope'), isNull);
    });
  });

  group('slotFor', () {
    test('returns the same AdSlot instance for the same key', () {
      final a = registry.slotFor('k1');
      final b = registry.slotFor('k1');
      expect(identical(a, b), isTrue);
    });

    test('returns a DIFFERENT AdSlot instance for a different key', () {
      final a = registry.slotFor('k1');
      final b = registry.slotFor('k2');
      expect(identical(a, b), isFalse);
    });

    test('the returned slot has the type passed to the constructor', () {
      final mrecRegistry = InlineAdInstanceRegistry(AdSlotType.mrec);
      expect(mrecRegistry.slotFor('k1').type, AdSlotType.mrec);
    });
  });

  group('listenablesFor', () {
    test('returns the same BannerListenables instance for the same key', () {
      final a = registry.listenablesFor('k1');
      final b = registry.listenablesFor('k1');
      expect(identical(a, b), isTrue);
    });

    test('onCreated fires exactly once, only on first creation', () {
      var calls = 0;
      registry.listenablesFor('k1', onCreated: (_) => calls++);
      registry.listenablesFor('k1', onCreated: (_) => calls++);
      expect(calls, 1);
    });

    test('a fresh instance starts with sane defaults', () {
      final l = registry.listenablesFor('k1');
      expect(l.isLoaded.value, isFalse);
      expect(l.hasError.value, isFalse);
      expect(l.adSize.value, isNull);
      expect(l.autoRefreshEnabled.value, isTrue);
      expect(l.visible.value, isTrue);
    });
  });

  group('isCurrent', () {
    test('true for the slot currently owning this key', () {
      final slot = registry.slotFor('k1');
      expect(registry.isCurrent('k1', slot), isTrue);
    });

    test('false for a slot that no longer owns this key (removed)', () {
      final slot = registry.slotFor('k1');
      registry.removeKey('k1');
      expect(registry.isCurrent('k1', slot), isFalse,
          reason: 'the B-2/M4 guard: a load callback captured this slot '
              'before the widget was disposed mid-load — it must not act '
              'once the key has been reassigned/removed');
    });

    test('false for a key that was never owned', () {
      final slot = registry.slotFor('k1');
      expect(registry.isCurrent('k2', slot), isFalse);
    });
  });

  group('removeKey', () {
    test('disposes the slot and returns the (undisposed) listenables', () {
      final slot = registry.slotFor('k1');
      final listenables = registry.listenablesFor('k1');

      final removed = registry.removeKey('k1');

      expect(slot.debugStateDisposed, isTrue);
      expect(identical(removed, listenables), isTrue);
      // Deliberately NOT disposed by removeKey itself — the caller may
      // need to run its own extra step (e.g. `_inlineVisibility.forget`)
      // on the still-live object first, exactly like
      // disposeBannerInstance's real order today.
      expect(() => removed!.isLoaded.addListener(() {}), returnsNormally);
    });

    test('returns null for a key that was never owned', () {
      expect(registry.removeKey('nope'), isNull);
    });

    test('a later slotFor/listenablesFor for the same key starts fresh',
        () {
      final oldSlot = registry.slotFor('k1');
      registry.removeKey('k1');
      final newSlot = registry.slotFor('k1');
      expect(identical(oldSlot, newSlot), isFalse);
    });
  });

  group('allKeys', () {
    test('union of slot keys and listenables keys — a key created via '
        'only ONE accessor still appears', () {
      registry.slotFor('slot-only');
      registry.listenablesFor('listenables-only');
      registry.slotFor('both');
      registry.listenablesFor('both');

      expect(registry.allKeys,
          {'slot-only', 'listenables-only', 'both'});
    });

    test('empty when nothing has been created', () {
      expect(registry.allKeys, isEmpty);
    });
  });

  group('slots', () {
    test('read-only view of every currently-owned slot', () {
      registry.slotFor('k1');
      registry.slotFor('k2');
      expect(registry.slots, hasLength(2));
    });
  });

  group('listenablesList', () {
    test('read-only view of every currently-owned listenables', () {
      registry.listenablesFor('k1');
      registry.listenablesFor('k2');
      expect(registry.listenablesList, hasLength(2));
    });
  });

  group('slotKeys', () {
    test('narrower than allKeys — listenables-only keys are excluded', () {
      registry.slotFor('has-slot');
      registry.listenablesFor('listenables-only');
      expect(registry.slotKeys, ['has-slot']);
    });
  });

  group('listenablesKeys / listenablesByKey', () {
    test('listenablesKeys is narrower than allKeys — slot-only keys are '
        'excluded', () {
      registry.slotFor('slot-only');
      registry.listenablesFor('has-listenables');
      expect(registry.listenablesKeys, ['has-listenables']);
    });

    test('listenablesByKey looks up by key, null if not owned', () {
      final created = registry.listenablesFor('k1');
      expect(identical(registry.listenablesByKey('k1'), created), isTrue);
      expect(registry.listenablesByKey('nope'), isNull);
    });
  });

  group('markDisposed', () {
    test('after markDisposed, slotFor/listenablesFor return an '
        'already-disposed sentinel instead of a live instance', () {
      registry.markDisposed();

      final slot = registry.slotFor('new-key');
      final listenables = registry.listenablesFor('new-key');

      expect(slot.debugStateDisposed, isTrue);
      expect(() => listenables.isLoaded.addListener(() {}),
          throwsFlutterError);
    });

    test('the SAME sentinel is reused for every key after disposal', () {
      registry.markDisposed();
      final a = registry.slotFor('k1');
      final b = registry.slotFor('k2');
      expect(identical(a, b), isTrue);
    });

    test('does not retroactively dispose keys that were already live',
        () {
      final slot = registry.slotFor('k1');
      registry.markDisposed();
      expect(slot.debugStateDisposed, isFalse,
          reason: 'markDisposed only changes behavior for FUTURE '
              'accessor calls — the adapter\'s own teardown loop is what '
              'disposes every already-live key, via removeKey');
    });
  });
}
