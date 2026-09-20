// T200 — ClearSdkDataDemoPage's confirmation flow: the dangerous
// "including entitlements" scope must only ever actually run after the
// user confirms a real dialog, never on the tap alone.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => AdManager().disableProviderFailoverAdvisor());

  Widget host() =>
      const MaterialApp(home: ClearSdkDataDemoPage());

  testWidgets('tapping "Clear ALL SDK data" shows a confirmation dialog '
      'first — does not erase on the tap alone', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(
        find.text('Clear ALL SDK data (including entitlements)'));
    await tester.pump();

    expect(find.text('Xoá toàn bộ dữ liệu SDK?'), findsOneWidget);
    expect(find.text('Huỷ'), findsOneWidget);
    expect(find.text('Xoá hết'), findsOneWidget);
  });

  testWidgets('cancelling the dialog logs a cancellation, never calls '
      'clearSdkData', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(
        find.text('Clear ALL SDK data (including entitlements)'));
    await tester.pump();
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();

    expect(find.text('user cancelled — nothing was erased'), findsOneWidget);
  });

  testWidgets('confirming the dialog actually calls clearSdkData with the '
      'entitlements scope and the confirmation flag', (tester) async {
    await tester.pumpWidget(host());

    // Both taps AND the real delay in ONE runAsync block — clearSdkData()
    // reaches real flutter_secure_storage platform-channel calls
    // (VipEntriesStore/RedeemedKeyLedger/FirstInstallGuard's erase()),
    // and flutter_test's fake-async pump loop does not let that kind of
    // real platform-channel round trip (or the awaited continuation
    // after it) actually complete no matter how many times
    // pumpAndSettle() is called on its own.
    await tester.runAsync(() async {
      await tester.tap(
          find.text('Clear ALL SDK data (including entitlements)'));
      await tester.pump();
      await tester.tap(find.text('Xoá hết'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // The dialog itself is gone (would throw a duplicate-dialog error on
    // the next attempt if it were still up) and the log reflects a real
    // completed call, not just the dialog closing.
    expect(find.text('Xoá toàn bộ dữ liệu SDK?'), findsNothing);
    expect(find.textContaining('clearSdkData(allIncludingEntitlements) done'),
        findsOneWidget);
  });

  testWidgets('the "safe" button never shows a confirmation dialog',
      (tester) async {
    await tester.pumpWidget(host());

    await tester.runAsync(() async {
      await tester
          .tap(find.text('Clear SDK data (safe — entitlements kept)'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(find.text('Xoá toàn bộ dữ liệu SDK?'), findsNothing);
    expect(find.textContaining('safe scope done'), findsOneWidget);
  });

  // Round 54 audit fix (MINOR) — the "safe" button's default scope wipes
  // ProviderFailoverAdvisor's persisted keys (they aren't entitlement
  // keys), but a LIVE advisor instance's own in-memory copy used to
  // survive untouched, silently re-persisting the pre-erasure streak on
  // its next ad-load event. This exercises the fix through the real demo
  // UI a host app would actually tap, not just the underlying API.
  testWidgets(
      'the "safe" button also resets a live, tripped ProviderFailoverAdvisor '
      'so its next event does not resurrect the erased streak',
      (tester) async {
    // advisor.ready resolves through AdPreferences.getInstance() ->
    // SharedPreferences.getInstance(), same real-plugin-channel gap this
    // file's own comment above already warns fake-async's pump loop can't
    // service — so this whole setup, not just the tap, runs inside
    // runAsync().
    final advisor = ProviderFailoverAdvisor(consecutiveFailureThreshold: 2);
    await tester.runAsync(() async {
      AdManager().enableProviderFailoverAdvisor(advisor);
      await advisor.ready;
      AdManager().debugEmit(AdLoadEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: false,
      ));
      AdManager().debugEmit(AdLoadEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: false,
      ));
      await Future<void>.delayed(Duration.zero);
    });
    expect(advisor.shouldFailoverNextSession, isTrue,
        reason: 'sanity: tripped before tapping the button');

    await tester.pumpWidget(host());
    await tester.runAsync(() async {
      await tester
          .tap(find.text('Clear SDK data (safe — entitlements kept)'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(advisor.shouldFailoverNextSession, isFalse,
        reason: 'the demo button a host app actually taps must reset the '
            'live advisor too, not just the persisted keys underneath it');
  });
}
