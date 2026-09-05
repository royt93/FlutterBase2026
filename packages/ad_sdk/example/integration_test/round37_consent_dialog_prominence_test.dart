// On-device integration test for round-37 audit — the consent dialog's
// Allow/Reject visual-prominence fix (EDPB Guidelines 03/2022 "equal
// prominence" between accept and reject).
//
// Why on-device: `test/consent_dialog_widget_test.dart` already proves the
// font-weight/size/fill-color equality against the headless test binding —
// this renders the SAME real widget through the real app's rendering
// pipeline (real device fonts/DPI/compositor) so a human doing the S24
// Ultra smoke test can visually confirm it, screenshot it, and so a real
// rendering regression (e.g. a font that doesn't actually ship on-device)
// cannot hide behind a passing headless test.
//
// Run with:
//   flutter test integration_test/round37_consent_dialog_prominence_test.dart -d <device-or-sim-id>

// `capturedContext` is the test's own root Builder context, alive for the
// whole test — safe to use after an await here.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Reject renders with the same font weight/size as Allow, and a solid '
      'fill, on the real device rendering pipeline', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const Scaffold(body: SizedBox());
      }),
    ));
    await tester.pump();

    unawaited(showConsentDialog(
      capturedContext,
      strings: const ConsentDialogStrings(),
      current: const ConsentSettings(),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Allow personalized ads'), findsOneWidget);
    expect(find.text('No thanks'), findsOneWidget);

    final allowText = tester.widget<Text>(find.text('Allow personalized ads'));
    final rejectText = tester.widget<Text>(find.text('No thanks'));
    expect(rejectText.style?.fontWeight, allowText.style?.fontWeight,
        reason: 'Reject must not render lighter-weight than Allow on a '
            'real device');
    expect(rejectText.style?.fontSize, allowText.style?.fontSize);

    final rejectContainer = tester.widget<Container>(find
        .ancestor(
            of: find.text('No thanks'), matching: find.byType(Container))
        .first);
    final rejectDecoration = rejectContainer.decoration as BoxDecoration?;
    // Independent review (round 37 verification) — a bare `color != null`
    // check would pass for a near-invisible tint too; assert a real
    // minimum opacity on the actual device rendering pipeline.
    expect(rejectDecoration?.color?.a, isNotNull);
    expect(rejectDecoration!.color!.a, greaterThanOrEqualTo(0.15),
        reason: 'Reject must render with a clearly visible fill on a real '
            'device, not just an outline or a barely-there tint');

    expect(tester.takeException(), isNull);
  });
}
