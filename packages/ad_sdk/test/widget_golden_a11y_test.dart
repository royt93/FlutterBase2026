import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_tolerance.dart';

// Goldens: dark/RTL/large-text variants of SDK-owned visuals.
// Accessibility: tap target + contrast + label guidelines on the same widgets.
// Regenerate: flutter test test/widget_golden_a11y_test.dart --update-goldens

// Whole-app boundary: byType(MaterialApp) resolves to the first route's
// boundary and silently omits dialogs/overlays.
const _shot = ValueKey('golden-shot');
const _panelShot = ValueKey('panel-shot');

const _admobCfg = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

Widget _app(
  Widget home, {
  ThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1.0,
}) {
  return RepaintBoundary(
    key: _shot,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Directionality(textDirection: dir, child: child!),
      ),
      home: home,
    ),
  );
}

Future<BuildContext> _pumpHost(
  WidgetTester tester, {
  ThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1.0,
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold(body: Text('Host screen'));
        },
      ),
      theme: theme,
      dir: dir,
      textScale: textScale,
    ),
  );
  return ctx;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(useTolerantGoldens);

  setUp(() => AdManager().debugConfig = _admobCfg);
  tearDown(() {
    AdLoadingDialog.resetState();
    AdManager().debugConfig = null;
  });

  group('AdLoadingDialog goldens', () {
    for (final v in <String, (ThemeData, TextDirection, double)>{
      'dark': (ThemeData.dark(), TextDirection.ltr, 1.0),
      'rtl': (ThemeData.light(), TextDirection.rtl, 1.0),
      'large_text': (ThemeData.light(), TextDirection.ltr, 2.0),
    }.entries) {
      testWidgets(v.key, (tester) async {
        final ctx = await _pumpHost(
          tester,
          theme: v.value.$1,
          dir: v.value.$2,
          textScale: v.value.$3,
        );
        AdLoadingDialog.show(ctx);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Loading…'), findsOneWidget);
        // Platform-independent layout check: tolerant goldens alone let a
        // 50px taller card through (measured 0.6-1.6% diff).
        final card = find
            .ancestor(
              of: find.text('Loading…'),
              matching: find.byType(Container),
            )
            .first;
        final size = tester.getSize(card);
        expect(size.width, inInclusiveRange(120, 200));
        expect(size.height, greaterThanOrEqualTo(120));
        if (v.key != 'large_text') {
          expect(size.height, 120, reason: 'default text keeps 120 height');
          expect(size.width, lessThanOrEqualTo(130));
        }
        await expectLater(
          find.byKey(_shot),
          matchesGoldenFile('goldens/ad_loading_dialog_${v.key}.png'),
        );
        AdLoadingDialog.dismiss();
        await tester.pump();
      });
    }
  });

  group('AdLoadingDialog long message', () {
    testWidgets('card stays bounded and wraps instead of stretching', (
      tester,
    ) async {
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'ca-app-pub-3940256099942544/6300978111',
          interstitialId: 'ca-app-pub-3940256099942544/1033173712',
          appOpenId: 'ca-app-pub-3940256099942544/9257395921',
          rewardedId: 'ca-app-pub-3940256099942544/5224354917',
        ),
        adLoadingMessage:
            'Loading advertisement, please wait a moment while it prepares…',
      );
      final ctx = await _pumpHost(tester);
      AdLoadingDialog.show(ctx);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final card = find.ancestor(
        of: find.textContaining('Loading advertisement'),
        matching: find.byType(Container),
      );
      expect(card, findsWidgets);
      final width = tester.getSize(card.first).width;
      expect(width, lessThanOrEqualTo(200), reason: 'card must not stretch');
      expect(tester.takeException(), isNull);
      AdLoadingDialog.dismiss();
      await tester.pump();
    });
  });

  group('TopToast goldens', () {
    for (final v in <String, (ThemeData, TextDirection, double)>{
      'light': (ThemeData.light(), TextDirection.ltr, 1.0),
      'rtl': (ThemeData.light(), TextDirection.rtl, 1.0),
      'large_text': (ThemeData.light(), TextDirection.ltr, 2.0),
    }.entries) {
      testWidgets(v.key, (tester) async {
        final ctx = await _pumpHost(
          tester,
          theme: v.value.$1,
          dir: v.value.$2,
          textScale: v.value.$3,
        );
        TopToast.show(
          ctx,
          icon: Icons.warning_amber_rounded,
          message: 'Ad not available right now',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Ad not available right now'), findsOneWidget);
        await expectLater(
          find.byKey(_shot),
          matchesGoldenFile('goldens/top_toast_${v.key}.png'),
        );
        // Drain auto-dismiss timer so no pending timer fails the test.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      });
    }
  });

  group('RevenuePanel goldens', () {
    for (final v in <String, (ThemeData, bool)>{
      'light': (ThemeData.light(), false),
      'dark': (ThemeData.dark(), false),
      'compact': (ThemeData.light(), true),
    }.entries) {
      testWidgets(v.key, (tester) async {
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Center(
                // Fixed frame: a bare crop of a 16px-tall panel turns a few
                // anti-aliased text pixels into a double-digit diff percent.
                child: RepaintBoundary(
                  key: _panelShot,
                  child: SizedBox(
                    width: 320,
                    height: 160,
                    child: Center(
                      child: RevenuePanel(
                        compact: v.value.$2,
                        debugModeOverride: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            theme: v.value.$1,
          ),
        );
        await tester.pump();
        await expectLater(
          find.byKey(_panelShot),
          matchesGoldenFile('goldens/revenue_panel_${v.key}.png'),
        );
      });
    }
  });

  group('Accessibility guidelines', () {
    testWidgets('loading dialog: contrast and labels', (tester) async {
      final handle = tester.ensureSemantics();
      final ctx = await _pumpHost(tester);
      AdLoadingDialog.show(ctx);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      AdLoadingDialog.dismiss();
      await tester.pump();
      handle.dispose();
    });

    testWidgets('toast: contrast and tap target', (tester) async {
      final handle = tester.ensureSemantics();
      final ctx = await _pumpHost(tester);
      TopToast.show(
        ctx,
        icon: Icons.warning_amber_rounded,
        message: 'Ad not available right now',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('revenue panel: contrast', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(const Scaffold(body: RevenuePanel(debugModeOverride: true))),
      );
      await tester.pump();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
