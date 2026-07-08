import 'package:applovin_admob_sdk/src/consent/consent_dialog.dart';
import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    ConsentDialogStrings strings = const ConsentDialogStrings(),
    void Function(String url)? onPrivacyPolicyTap,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showConsentDialog(
            context,
            strings: strings,
            current: ConsentSettings.unset,
            onPrivacyPolicyTap: onPrivacyPolicyTap,
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows ad-partners disclosure and Allow/Reject buttons',
      (tester) async {
    await pumpDialog(tester);

    expect(find.text('Ad partners: Google AdMob, AppLovin'), findsOneWidget);
    expect(find.text('Allow personalized ads'), findsOneWidget);
    expect(find.text('No thanks'), findsOneWidget);
  });

  testWidgets('hides ad-partners disclosure when set to null', (tester) async {
    await pumpDialog(
      tester,
      strings: const ConsentDialogStrings(adPartnersLabel: null),
    );

    expect(find.textContaining('Ad partners'), findsNothing);
  });

  testWidgets(
      'tapping the privacy-policy link invokes onPrivacyPolicyTap '
      'with the configured URL (regression: the auto-show path used to '
      'have no way to wire this callback at all)', (tester) async {
    String? tapped;
    await pumpDialog(
      tester,
      strings: const ConsentDialogStrings(
        privacyPolicyUrl: 'https://example.com/privacy',
      ),
      onPrivacyPolicyTap: (url) => tapped = url,
    );

    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(tapped, 'https://example.com/privacy');
  });

  testWidgets('Allow button reports hasUserConsent=true', (tester) async {
    ConsentSettings? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showConsentDialog(
              context,
              strings: const ConsentDialogStrings(),
              current: ConsentSettings.unset,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Allow personalized ads'));
    await tester.pumpAndSettle();

    expect(result?.hasUserConsent, true);
    expect(result?.hasBeenAsked, true);
  });
}
