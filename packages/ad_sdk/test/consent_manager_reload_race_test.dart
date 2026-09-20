// Round-67 audit, MAJOR — `_load()` (run by every `bootstrap()` call,
// including a reinit-without-destroy() on the SAME singleton, per this
// file's own documented design) used to read disk with no regard for a
// `set()`/`reset()` call already in flight on this very instance. A real
// platform-channel write has a real async gap (see the round-39
// `_persistLock` fix above `_load()`); reading disk inside that gap returns
// the PRE-write value, and `_load()` then overwrote `_current` /
// `_settingsListenable` with it. The in-flight call's own epoch guard
// doesn't catch this — it only detects a newer `set()`/`reset()` call, not
// a `_load()` racing in from outside that machinery entirely.
//
// Net effect: an app's own `set(hasUserConsent: true)` landed on disk
// correctly, but the in-memory `current` AND the value actually applied to
// AppLovin/AdMob both silently reverted to the stale `false` for the rest
// of the running session — a real compliance-relevant regression, not just
// a display glitch.
//
// Fix: `_load()` now awaits any in-flight `_persistLock` before reading
// disk, reusing the existing persist-serialization mechanism rather than
// adding a new one.

import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  late AdPreferences prefs;
  bool? appliedHasUserConsent;

  setUp(() async {
    appliedHasUserConsent = null;
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      if (call.method == 'setHasUserConsent') {
        appliedHasUserConsent = call.arguments['value'] as bool?;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    ConsentManager.resetForTest();
  });

  tearDown(() {
    ConsentManager.debugPersistDelay = null;
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  test(
      'a bootstrap() reinit racing an in-flight set() must not overwrite '
      'current with the pre-write disk value', () async {
    final m = await ConsentManager.bootstrap(prefs: prefs);
    expect(m.current.hasUserConsent, isFalse);

    ConsentManager.debugPersistDelay = const Duration(milliseconds: 150);
    final setFuture = m.set(
      const ConsentSettings(hasUserConsent: true, hasBeenAsked: true),
    );

    // Let set()'s synchronous prefix run and enter the persist delay.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A reinit (e.g. AdManager.initialize() called again without destroy())
    // reusing the same singleton, racing the still-in-flight set() above.
    final m2 = await ConsentManager.bootstrap(prefs: prefs);
    expect(identical(m, m2), isTrue);

    await setFuture;
    ConsentManager.debugPersistDelay = null;

    expect(m.current.hasUserConsent, isTrue,
        reason: 'the set() call the app actually made must win, not a '
            'stale value read mid-write by a racing reinit');
    expect(appliedHasUserConsent, isTrue,
        reason: 'providers must receive the value the app actually set(), '
            'never a transiently-stale reload');
  });
}
