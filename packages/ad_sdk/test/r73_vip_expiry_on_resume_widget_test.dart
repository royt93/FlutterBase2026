// Round-73 audit — widget layer for the VIP-expiry-on-resume fix. A banner
// mounted while a VIP window is (stale-)active must load once the app resumes
// and the expiry is noticed, instead of waiting for the suspended timer.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show AdSize;
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:shared_preferences/shared_preferences.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;

class _Store extends VipEntriesStore {
  _Store(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

class _DeadTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
  ),
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AdMobAdapter adapter;
  late VipManager vip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') return AdSize.banner;
      return null;
    });
    adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(_config), isTrue);
    vip = VipManager(prefs, vipEntriesStore: _Store(prefs));
    await vip.load();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = vip;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
  });

  tearDown(() async {
    AdManager().debugVipManager = null;
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    vip.dispose();
    await adapter.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Widget host() => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: const Scaffold(body: Center(child: BannerAdWidget())),
      );

  Future<void> grantStale(WidgetTester tester) => tester.runAsync(() => runZoned(
        () => vip.addVip(
            key: 'STALE', duration: const Duration(milliseconds: 200)),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, d, f) => _DeadTimer(),
        ),
      ));

  testWidgets('a banner mounted under a stale VIP loads after resume',
      (tester) async {
    await grantStale(tester);
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.bannerSlots, isEmpty,
        reason: 'sanity — VIP suppresses the request');

    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    expect(vip.isActive, isTrue, reason: 'sanity — expired but stale');

    AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
    // Allow the async resume consent recheck & VIP expiry to complete.
    await tester.pump();
    // What the SDK does when the VIP flag flips: tell mounted widgets to retry.
    // `debugVipManager` does not wire the production listener, so do what
    // `_onVipActiveChanged` does when the flag flips, in the same order.
    if (!vip.isActive) AdManager().initRevision.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(vip.isActive, isFalse);
    expect(adapter.bannerSlots, isNotEmpty,
        reason: 'the banner must be requested once the expiry is noticed');
  });

  testWidgets('a still-valid VIP keeps suppressing after resume',
      (tester) async {
    await tester.runAsync(
        () => vip.addVip(key: 'LIVE', duration: const Duration(hours: 1)));
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));

    AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));

    expect(vip.isActive, isTrue);
    expect(adapter.bannerSlots, isEmpty);
    vip.dispose(); // stop its real expiry timer before the test ends
    await tester.pump();
  });
}
