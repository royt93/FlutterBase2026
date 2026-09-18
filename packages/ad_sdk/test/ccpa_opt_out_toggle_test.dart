// Round-31 audit — CCPA/CPRA "Do Not Sell or Share My Personal Information"
// opt-out. AdConsent.doNotSell/ConsentSettings.doNotSell already flowed
// correctly to providers and persistence; what was missing was an end-user
// facing way to actually flip the choice. Covers AdManager.setDoNotSell()/
// .doNotSell and the CcpaOptOutToggle widget.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    // ConsentManager.set() applies to BOTH native SDKs unconditionally
    // (applyConsentToProviders in ad_consent.dart) regardless of which
    // provider is actually active — without these, the real platform
    // channels throw MissingPluginException in this test environment.
    messenger.setMockMethodCallHandler(_alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    ConsentManager.resetForTest();
    final prefs = await AdPreferences.getInstance();
    final mgr = await ConsentManager.bootstrap(prefs: prefs);
    AdManager().debugConsentManager = mgr;
  });

  tearDown(() {
    AdManager().debugConsentManager = null;
    ConsentManager.resetForTest();
    AdPreferences.resetForTest();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
  });

  group('AdManager.setDoNotSell / .doNotSell', () {
    test('false before initialize()/without a ConsentManager', () {
      AdManager().debugConsentManager = null;
      expect(AdManager().doNotSell, isFalse);
    });

    test('setDoNotSell(true) flips .doNotSell and persists through '
        'ConsentManager', () async {
      expect(AdManager().doNotSell, isFalse);
      await AdManager().setDoNotSell(true);
      expect(AdManager().doNotSell, isTrue);
      expect(AdManager().consentManager!.current.doNotSell, isTrue);
    });

    test('setDoNotSell(true) then setDoNotSell(false) round-trips', () async {
      await AdManager().setDoNotSell(true);
      expect(AdManager().doNotSell, isTrue);
      await AdManager().setDoNotSell(false);
      expect(AdManager().doNotSell, isFalse);
    });

    test('setDoNotSell before a ConsentManager exists does not throw',
        () async {
      AdManager().debugConsentManager = null;
      await expectLater(AdManager().setDoNotSell(true), completes);
    });
  });

  group('CcpaOptOutToggle', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('shows the switch off by default and toggling it calls '
        'through to AdManager', (tester) async {
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);
      expect(find.text('Do Not Sell or Share My Personal Information'),
          findsOneWidget);

      await tester.tap(switchFinder);
      await tester.pump();

      expect(AdManager().doNotSell, isTrue,
          reason: 'tapping the toggle must call AdManager().setDoNotSell()');
      expect(tester.widget<Switch>(switchFinder).value, isTrue,
          reason: 'the switch must reflect the new state reactively');
    });

    testWidgets('reflects an already-true doNotSell on first build',
        (tester) async {
      await AdManager().setDoNotSell(true);
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('disabled (not silently broken) when shown before '
        'AdManager has a ConsentManager', (tester) async {
      AdManager().debugConsentManager = null;
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      final s = tester.widget<Switch>(find.byType(Switch));
      expect(s.value, isFalse);
      expect(s.onChanged, isNull,
          reason: 'must be visibly disabled, not silently no-op on tap');
    });

    // T166 — mounted before AdManager().initialize() finishes, then init
    // finishes WHILE the widget is still on screen. Must self-recover
    // without the host having to leave and re-enter the screen.
    testWidgets(
        'auto-recovers once AdManager finishes initialising, without '
        'needing to leave and re-enter the screen', (tester) async {
      final realConsentManager = AdManager().consentManager;
      AdManager().debugConsentManager = null;
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      var s = tester.widget<Switch>(find.byType(Switch));
      expect(s.onChanged, isNull,
          reason: 'sanity: starts disabled, same as before this fix');

      // Simulate the rest of a real initialize() call landing: the
      // ConsentManager becomes available, then initRevision bumps —
      // exactly the order ad_manager.dart's own initialize() does it in.
      AdManager().debugConsentManager = realConsentManager;
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();

      s = tester.widget<Switch>(find.byType(Switch));
      expect(s.onChanged, isNotNull,
          reason: 'T166 — must re-enable itself once init genuinely '
              'finishes, without remounting');

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(AdManager().doNotSell, isTrue,
          reason: 'the recovered toggle must be a REAL, working switch, '
              'not just visually re-enabled');
    });

    testWidgets(
        'an initRevision bump with NO ConsentManager available yet stays '
        'disabled (not a false recovery)', (tester) async {
      AdManager().debugConsentManager = null;
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();

      final s = tester.widget<Switch>(find.byType(Switch));
      expect(s.onChanged, isNull,
          reason: 'T166 — initRevision alone proves nothing; the toggle '
              'must actually re-check consentManager, not assume init '
              'succeeded just because the revision counter moved');
    });

    testWidgets(
        'a LATER initRevision bump, after already having recovered once, '
        'does not re-attach or misbehave', (tester) async {
      final realConsentManager = AdManager().consentManager;
      AdManager().debugConsentManager = null;
      await tester.pumpWidget(host(const CcpaOptOutToggle()));

      AdManager().debugConsentManager = realConsentManager;
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);

      // A further bump (e.g. a later destroy()+reinit cycle) must not
      // throw or double-attach a listener.
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    });

    testWidgets('accepts custom strings (localisation)', (tester) async {
      await tester.pumpWidget(host(const CcpaOptOutToggle(
        strings: CcpaOptOutStrings.vi,
      )));

      expect(find.text('Không bán hoặc chia sẻ thông tin cá nhân của tôi'),
          findsOneWidget);
    });
  });
}
