// On-device repro (Native twin of banner/MREC): a NativeAdWidget mounted on the
// FIRST frame (before AdManager().initialize() finishes) vs one mounted after
// init. Asserts a real AdWidget platform view with a non-zero size exists for
// each.
//
// Run (clear app data first, see README.md):
//   flutter test integration_test/native_mounted_before_init_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show AdWidget;
import 'package:integration_test/integration_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    nativeId: 'ca-app-pub-3940256099942544/2247696110',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool showLate = false;
  void mountLate() => setState(() => showLate = true);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const NativeAdWidget(key: ValueKey('early')),
                if (showLate) const NativeAdWidget(key: ValueKey('late')),
              ],
            ),
          ),
        ),
      );
}

double _adHeightUnder(WidgetTester tester, Key key) {
  final ads = find.descendant(
    of: find.byKey(key),
    matching: find.byType(AdWidget),
  );
  if (ads.evaluate().isEmpty) return 0;
  return tester.getSize(ads.first).height;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // AdManager is a process-wide singleton; reset so each test starts pre-init.
  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets('early-mounted Native paints like a late-mounted one',
      (tester) async {
    final hostKey = GlobalKey<_HostState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _Host(key: hostKey),
      ),
    );
    await tester.pump();

    var done = false;
    await AdManager().initialize(
      config: _config,
      onComplete: (ok, _) => done = ok,
    );
    for (var i = 0; i < 120 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(done, isTrue, reason: 'SDK must finish initialising');
    await AdManager().vip?.revokeAll();
    await tester.pump(const Duration(seconds: 1));

    hostKey.currentState!.mountLate();
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_adHeightUnder(tester, const ValueKey('early')) > 0 &&
          _adHeightUnder(tester, const ValueKey('late')) > 0) {
        break;
      }
    }

    final late = _adHeightUnder(tester, const ValueKey('late'));
    final early = _adHeightUnder(tester, const ValueKey('early'));
    // ignore: avoid_print
    print('NATIVE_REPRO early=$early late=$late');
    expect(late, greaterThan(0), reason: 'control (late-mounted) must paint');
    expect(early, greaterThan(0), reason: 'early-mounted must paint too');
    expect(tester.takeException(), isNull);
  });
}
