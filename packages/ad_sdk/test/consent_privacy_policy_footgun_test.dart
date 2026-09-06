// Round-39 audit (claude-cli independent review), MINOR-1 — a host that wires
// neither `ConsentDialogStrings.privacyPolicyUrl` nor `onPrivacyPolicyTap`
// ships a GDPR consent dialog with no way for the user to reach the privacy
// policy, and gets zero signal from the SDK about it (debug or release) —
// unlike every other release-footgun this package already warns loudly
// about (test ad-unit IDs, disabled trial, empty AppLovin key, ...).

import 'package:applovin_admob_sdk/src/config/ad_log_level.dart';
import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/utils/safe_logger.dart';
import 'package:flutter/material.dart';
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
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));
    return ctx;
  }

  testWidgets(
      'showDialog with neither privacyPolicyUrl nor onPrivacyPolicyTap warns',
      (tester) async {
    final warnings = <String>[];
    SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => warnings.add('$tag: $message'));
    addTearDown(() => SafeLogger.configure());

    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    final context = await pumpContext(tester);

    final future = m.showDialog(context, barrierDismissible: true);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await future;

    expect(
        warnings.any((w) => w.toLowerCase().contains('privacy')), isTrue,
        reason: 'no way for the user to reach a privacy policy from this '
            'consent dialog, and no signal at all today');
  });

  testWidgets('showDialog with privacyPolicyUrl set does not warn',
      (tester) async {
    final warnings = <String>[];
    SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => warnings.add('$tag: $message'));
    addTearDown(() => SafeLogger.configure());

    final m = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: const ConsentDialogStrings(
            privacyPolicyUrl: 'https://example.com/privacy'));
    final context = await pumpContext(tester);

    final future = m.showDialog(context, barrierDismissible: true);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await future;

    expect(warnings.any((w) => w.toLowerCase().contains('privacy')), isFalse);
  });

  testWidgets('showDialog with onPrivacyPolicyTap set does not warn',
      (tester) async {
    final warnings = <String>[];
    SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => warnings.add('$tag: $message'));
    addTearDown(() => SafeLogger.configure());

    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    final context = await pumpContext(tester);

    final future = m.showDialog(context,
        barrierDismissible: true, onPrivacyPolicyTap: (_) {});
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await future;

    expect(warnings.any((w) => w.toLowerCase().contains('privacy')), isFalse);
  });
}
