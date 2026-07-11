// Coverage was 0% despite ConsentManager being the standalone consent
// singleton every host app talks to — no test file existed for it at all.
// Covers: bootstrap/idempotency, showDialogIfNeeded gating, showDialog
// (Allow/Reject/dismiss), programmatic set/reset, persistence round-trip,
// and the reactive listenable.

import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // applyConsentToProviders (called by every mutator below) fires native
  // calls on these channels — no-op them, same pattern as ad_consent_test.dart.
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
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  test('instance throws before bootstrap', () {
    expect(() => ConsentManager.instance, throwsStateError);
    expect(ConsentManager.isReady, isFalse);
  });

  test('bootstrap loads unset defaults on a fresh install', () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    expect(ConsentManager.isReady, isTrue);
    expect(m.current, ConsentSettings.unset);
    expect(m.hasBeenAsked, isFalse);
  });

  test('bootstrap is idempotent and re-loads persisted settings', () async {
    await prefs.setConsentSettingsRaw(ConsentSettings.encode(
      ConsentSettings.accepted,
    ));
    final m1 = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    expect(m1.current.hasUserConsent, isTrue);

    final m2 = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    expect(identical(m1, m2), isTrue,
        reason: 'second bootstrap call must reuse the singleton');
  });

  test('set() persists, updates listenable, and re-applies to providers',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);

    final seen = <ConsentSettings>[];
    m.listenable.addListener(() => seen.add(m.listenable.value));

    await m.set(ConsentSettings.rejected);

    expect(m.current.hasUserConsent, isFalse);
    expect(m.current.hasBeenAsked, isTrue);
    expect(seen, hasLength(1));
    expect(ConsentSettings.decode(prefs.getConsentSettingsRaw()).hasBeenAsked,
        isTrue,
        reason: 'set() must persist through to SharedPreferences');
  });

  test('reset() wipes back to unset and persists it', () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    await m.set(ConsentSettings.accepted);

    await m.reset();

    expect(m.current, ConsentSettings.unset);
    expect(ConsentSettings.decode(prefs.getConsentSettingsRaw()).toJson(),
        ConsentSettings.unset.toJson());
  });

  test('updateStrings swaps the strings used without touching settings',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    final en = ConsentDialogStrings(
      title: 'Personalized ads',
      message: 'msg',
    );
    m.updateStrings(en);
    expect(m.strings, same(en));
    expect(m.current, ConsentSettings.unset,
        reason: 'updateStrings must not re-load or reset settings');
  });

  testWidgets('showDialogIfNeeded skips once hasBeenAsked is true',
      (tester) async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    await m.set(ConsentSettings.accepted);

    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }),
    ));

    final result = await m.showDialogIfNeeded(capturedContext);

    expect(result, same(m.current));
    expect(find.text(ConsentDialogStrings.vi.title), findsNothing,
        reason: 'dialog must not appear once the user has already been asked');
  });

  testWidgets(
      'showDialogIfNeeded shows and tapping Allow persists hasUserConsent=true',
      (tester) async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);

    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }),
    ));

    final future = m.showDialogIfNeeded(capturedContext);
    await tester.pumpAndSettle();

    expect(find.text(ConsentDialogStrings.vi.title), findsOneWidget);
    await tester.tap(find.text(ConsentDialogStrings.vi.allowButton));
    await tester.pumpAndSettle();

    final result = await future;
    expect(result.hasUserConsent, isTrue);
    expect(result.hasBeenAsked, isTrue);
    expect(m.current.hasUserConsent, isTrue);
  });

  testWidgets('showDialog tapping Reject persists hasUserConsent=false',
      (tester) async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);

    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }),
    ));

    final future = m.showDialog(capturedContext);
    await tester.pumpAndSettle();

    await tester.tap(find.text(ConsentDialogStrings.vi.rejectButton));
    await tester.pumpAndSettle();

    final result = await future;
    expect(result.hasUserConsent, isFalse);
    expect(result.hasBeenAsked, isTrue);
  });

  testWidgets(
      'showDialog dismissed without choice (barrierDismissible) returns '
      'current unchanged', (tester) async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);

    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }),
    ));

    final future = m.showDialog(capturedContext, barrierDismissible: true);
    await tester.pumpAndSettle();

    // Tap the barrier (top-left corner, outside the dialog card) to dismiss.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    final result = await future;
    expect(result, ConsentSettings.unset);
    expect(m.current.hasBeenAsked, isFalse,
        reason: 'dismiss-without-choice must not mark hasBeenAsked');
  });

  test('applyToProviders can be called standalone without changing settings',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    await m.set(ConsentSettings.accepted);

    await expectLater(m.applyToProviders(), completes);
    expect(m.current.hasUserConsent, isTrue);
  });
}
