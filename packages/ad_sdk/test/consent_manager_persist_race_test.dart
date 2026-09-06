// Round-39 audit (claude-cli independent review), MAJOR-1 — `_setInternal`'s
// (and `reset()`'s) `await _persist()` call was NOT serialized. `_persist()`
// synchronously captures `ConsentSettings.encode(_current)` as its native-call
// argument, so each call always captures its OWN correct value at the moment
// it starts — but the actual platform-channel write (`setConsentSettingsRaw`)
// is a real async round trip, and two of them left in flight concurrently can
// complete out of order. If an OLDER call's slower native write completes
// AFTER a NEWER overlapping call's faster one, the older's stale value lands
// last on disk — invisible until the next app launch, when `bootstrap()` →
// `_load()` reads back the wrong value and silently reverts the user's real,
// most-recent choice.
//
// The exact same class of bug, same fix, already exists in this codebase:
// `ad_event_log.dart`'s `_persistChain` chains every persist after the
// previous one so concurrent writes can't race and finish out of order.

import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
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

  setUp(() async {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
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
      'an older set() call whose real persist write is slower must never '
      'land on disk after a newer overlapping call\'s faster one', () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);

    // Older call: slow native write (simulates a real platform-channel gap).
    ConsentManager.debugPersistDelay = const Duration(milliseconds: 50);
    final older = m.set(const ConsentSettings(
        hasUserConsent: false, hasBeenAsked: true));
    await Future<void>.delayed(Duration.zero);

    // Newer call fired right behind it — fast native write, no delay.
    ConsentManager.debugPersistDelay = null;
    final newer = m.set(const ConsentSettings(
        hasUserConsent: true, hasBeenAsked: true));
    await newer;

    // Let the older call's delayed write actually land (if it's going to).
    await older;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final reloaded = ConsentSettings.decode(prefs.getConsentSettingsRaw());
    expect(reloaded.hasUserConsent, isTrue,
        reason: 'what actually ends up on disk — read back exactly like the '
            'next app launch\'s bootstrap()/_load() would — must be the '
            'newer call\'s value, never the older, slower call\'s stale one');
  });
}
