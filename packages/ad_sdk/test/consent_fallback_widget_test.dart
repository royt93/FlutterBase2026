// Audit fix (post-T210) — this used to pump a `Text` widget built from a
// hand-typed string interpolation and match that same string, proving
// nothing about ConsentManager itself: `CompatibilityMatrix`'s widget test
// (T215) turned out to be the exact same shape of fake. This SDK ships no
// bundled "privacy status" widget for hosts (grepped example/lib/), but it
// DOES ship a real, public reactive primitive for building one:
// ConsentManager.fallbackListenable. This builds a minimal-but-real status
// widget backed by that listenable and proves it actually reacts to
// recordFallback()/clearFallback() — which, before this fix's
// `_fallbackListenable` addition to consent_manager.dart, it did not: those
// two methods updated `_fallback` with no notification at all.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FallbackStatusBanner extends StatelessWidget {
  const _FallbackStatusBanner({required this.manager});
  final ConsentManager manager;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ConsentFallbackState?>(
        valueListenable: manager.fallbackListenable,
        builder: (_, fallback, _) => Text(fallback == null
            ? 'Consent fallback: none'
            : 'Consent fallback: ${fallback.reason.name} · conservative'),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
  });

  tearDown(() => ConsentManager.resetForTest());

  testWidgets(
      'a host status widget built on fallbackListenable reacts to '
      'recordFallback() and clearFallback()', (tester) async {
    final prefs = await AdPreferences.getInstance();
    final cm = await ConsentManager.bootstrap(prefs: prefs);

    await tester
        .pumpWidget(MaterialApp(home: _FallbackStatusBanner(manager: cm)));
    expect(find.textContaining('Consent fallback: none'), findsOneWidget,
        reason: 'sanity: nothing recorded yet');

    await cm.recordFallback(
      reason: ConsentFallbackReason.timeout,
      policyRevision: kUmpPolicyRevision,
    );
    await tester.pump();
    expect(find.textContaining('timeout'), findsOneWidget);
    expect(find.textContaining('conservative'), findsOneWidget);

    await cm.clearFallback();
    await tester.pump();
    expect(find.textContaining('Consent fallback: none'), findsOneWidget,
        reason: 'the widget must react to clearFallback() too, not just '
            'the initial recordFallback()');
  });
}
