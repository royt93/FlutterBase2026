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

  testWidgets(
      'round-29 audit (MINOR): Reject and Allow buttons get equal width',
      (tester) async {
    await pumpDialog(tester);

    // The Reject/Allow row is the only place in this dialog with two
    // `Expanded` siblings.
    final expandedSizes =
        find.byType(Expanded).evaluate().map((e) {
      final box = e.renderObject as RenderBox;
      return box.size.width;
    }).toList();
    expect(expandedSizes.length, 2);
    expect(expandedSizes[0], closeTo(expandedSizes[1], 0.5),
        reason: 'Reject must get the same Expanded flex as Allow, not half '
            'its width');
  });

  testWidgets(
      'round-37 audit (MAJOR): Reject gets equal visual prominence to '
      'Allow, not just equal width (EDPB Guidelines 03/2022 "equal '
      'prominence" between accept/reject)', (tester) async {
    await pumpDialog(tester);

    final allowText = tester.widget<Text>(find.text('Allow personalized ads'));
    final rejectText = tester.widget<Text>(find.text('No thanks'));
    expect(rejectText.style?.fontWeight, allowText.style?.fontWeight,
        reason: 'Reject reading as a lighter font weight than Allow makes '
            'it look like the secondary/less-important choice');
    expect(rejectText.style?.fontSize, allowText.style?.fontSize);

    final rejectContainer = tester.widget<Container>(find
        .ancestor(
            of: find.text('No thanks'), matching: find.byType(Container))
        .first);
    final rejectDecoration = rejectContainer.decoration as BoxDecoration?;
    // Independent review (round 37 verification) — `color != null` alone
    // would pass even for a near-invisible alpha like 0.02, which is
    // exactly the kind of ghost-button fill this fix exists to replace.
    // Assert a real minimum opacity so a regression back to that fails
    // loudly.
    expect(rejectDecoration?.color?.a, isNotNull);
    expect(rejectDecoration!.color!.a, greaterThanOrEqualTo(0.15),
        reason: 'Reject must have a clearly visible fill like Allow\'s '
            'gradient, not just a thin outline or a barely-there tint — an '
            'outline-only (or near-invisible-fill) "no" next to a solid '
            'filled "yes" is exactly the asymmetry EDPB\'s deceptive-design '
            'guidance calls out');
  });
}
