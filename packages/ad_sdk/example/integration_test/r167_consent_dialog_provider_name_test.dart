// On-device integration test for T167 — the consent dialog's "Ad
// partners: …" caption must name the ad network this app is actually
// configured for, not unconditionally both.
//
// Forces the dialog to show directly through the real, live
// AdManager().consentManager instance (rather than relying on the
// auto-show flow's `hasBeenAsked` state, which a device that has already
// run other tests against this same app install may have already set) —
// this still exercises the exact real production path
// (ConsentManager.showDialog → showConsentDialog), with
// `_lastKnownProvider` populated by the SAME real AdManager().initialize()
// call this test run actually made.
//
// Run with:
//   flutter test integration_test/r167_consent_dialog_provider_name_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true
// (omit the dart-define to test the AppLovin-only default instead)

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      "the consent dialog's ad-partners caption names only the network "
      'this build is actually configured for', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final consentManager = AdManager().consentManager;
    expect(consentManager, isNotNull,
        reason: 'a real init must have bootstrapped ConsentManager');

    final navigatorContext =
        tester.state<NavigatorState>(find.byType(Navigator).first).context;
    // Not awaited — the dialog blocks on the user's choice, which this
    // test provides by tapping Reject below. The captured context is
    // still valid: no widget tree change happens between capturing it and
    // this call (a device integration test, not a State — there is no
    // `mounted` to check against).
    // ignore: unawaited_futures, use_build_context_synchronously
    consentManager!.showDialog(navigatorContext);
    await tester.pump(const Duration(milliseconds: 300));

    final expectedProvider =
        const bool.fromEnvironment('AD_PROVIDER_ADMOB')
            ? 'Google AdMob'
            : 'AppLovin';
    final unexpectedProvider =
        expectedProvider == 'Google AdMob' ? 'AppLovin' : 'Google AdMob';

    // find.text requires an EXACT match, not a substring — finding this
    // exact string is already complete proof the caption does NOT ALSO
    // name $unexpectedProvider (the old, unfixed wording named both). A
    // separate screen-wide "must not contain $unexpectedProvider" check
    // was tried and dropped: Home (still in the tree behind the dialog)
    // can legitimately have unrelated tiles mentioning the other
    // provider's name (e.g. a demo comparing AdMob vs AppLovin layouts),
    // which false-positived such a check.
    expect(find.text('Ad partners: $expectedProvider'), findsOneWidget,
        reason: 'T167 — this build is configured for $expectedProvider '
            'only; the caption must say exactly that, not also name '
            '$unexpectedProvider');

    // Dismiss so teardown doesn't leave a dialog blocking the tree.
    await tester.tap(find.text('No thanks'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
