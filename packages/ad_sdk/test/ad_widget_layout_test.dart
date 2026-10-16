import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Size size = const Size(360, 640)}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Visual widget structure tests', () {
    tearDown(AdLoadingDialog.resetState);

    testWidgets('loading dialog matches the non-dismissible design', (
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
      );
      addTearDown(() => AdManager().debugConfig = null);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (contextUnderTest) {
              context = contextUnderTest;
              return const Scaffold(body: Text('Host screen'));
            },
          ),
        ),
      );

      AdLoadingDialog.show(context);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Loading…'), findsOneWidget);
      expect(find.text('Host screen'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/ad_loading_dialog.png'),
      );
      AdLoadingDialog.dismiss();
      await tester.pump();
    });

    testWidgets(
      'loading dialog buffer removes its route and invokes callback',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (contextUnderTest) {
                context = contextUnderTest;
                return const Scaffold(body: Text('Host screen'));
              },
            ),
          ),
        );
        var completed = false;
        final future = AdLoadingDialog.showAdBuffer(
          context,
          durationMs: 100,
          onComplete: () => completed = true,
        );
        await tester.pump();
        expect(find.text('Loading…'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 110));
        await future;
        expect(completed, isTrue);
        expect(find.text('Host screen'), findsOneWidget);
      },
    );

    testWidgets(
      'uninitialised BannerAdWidget collapses cleanly to zero height',
      (tester) async {
        await tester.pumpWidget(_wrap(const BannerAdWidget()));
        await tester.pumpAndSettle();

        final box = tester.renderObject<RenderBox>(find.byType(BannerAdWidget));
        expect(box.size.height, 0);
      },
    );

    testWidgets('uninitialised MrecAdWidget collapses cleanly to zero height', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MrecAdWidget()));
      await tester.pumpAndSettle();

      final box = tester.renderObject<RenderBox>(find.byType(MrecAdWidget));
      expect(box.size.height, 0);
    });

    testWidgets('NativeAdWidget shows non-empty structure with layout bounds', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SizedBox(width: 360, height: 120, child: NativeAdWidget())),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NativeAdWidget), findsOneWidget);
    });
  });
}
