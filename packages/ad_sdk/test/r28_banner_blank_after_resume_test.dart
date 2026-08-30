// Round-28 QC (both reviewers, MAJOR) — a banner AdMob filled must not render
// blank.
//
// `onAppPaused()` takes the background hold on EVERY listenable: its guard is
// the global `_bannerAdsByKey.isNotEmpty`, not a per-key check. `onAppResumed()`
// used to release that hold only for keys that still had an ad object. A key
// whose load had failed while another key's succeeded went down the
// `needsRecovery` reload branch instead and kept the hold forever — so when its
// retry finally filled, the round-26 `revealUnlessHeld` honoured the stale hold
// and left the surface blank.
//
// That silently undid the "T-visible" fix, whose own comment sits directly above
// the line round 26 changed. The publisher is billed for a request that renders
// nothing, and it recovers only on a LATER background→foreground cycle — or not
// at all, on a connection flaky enough to fail the key again in between.
//
// Two banner placements is all it takes: a home banner and a detail banner.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// ignore: implementation_imports — the real GMA codec, so the mock channel
// speaks the same protocol the adapter does.
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;

import 'admob_behavioral_test.dart' show FakeGmaBridge;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = AdConfig(
    provider: AdProvider.admob,
    admob: AdMobConfig(
      bannerId: 'b',
      interstitialId: 'i',
      appOpenId: 'ao',
      mrecId: 'm',
    ),
  );

  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') return AdSize.banner;
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  BannerAd dummyBanner() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );

  LoadAdError err() => LoadAdError(3, 'domain', 'no fill', null);

  Future<AdMobAdapter> newAdapter() async {
    final adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(config), isTrue);
    addTearDown(adapter.dispose);
    return adapter;
  }

  // The recovery loops call the async loadX paths without awaiting them.
  Future<void> settle() async {
    await Future<void>.value();
    await Future<void>.value();
    await Future<void>.value();
  }

  test('a retry that fills after a resume actually shows the banner', () async {
    final a = await newAdapter();

    // `live` fills, `dead` gets a no-fill. Entirely ordinary on two placements.
    await a.loadBannerIfNeeded('live', 320);
    a.debugBannerListenerFor('live')!.onAdLoaded!(dummyBanner());

    await a.loadBannerIfNeeded('dead', 320);
    a.debugBannerListenerFor('dead')!.onAdFailedToLoad!(dummyBanner(), err());
    expect(a.banner('dead').needsRecovery, isTrue,
        reason: 'sanity — a real no-fill is what creates the retry claim');

    // The user backgrounds the app. `_bannerAdsByKey` is non-empty because of
    // `live`, so BOTH keys are blanked — that global guard is the whole trap.
    a.onAppPaused();
    expect(a.banner('live').visible.value, isFalse);
    expect(a.banner('dead').visible.value, isFalse);

    // The failure backoff (15 s base) has elapsed by the time the user comes
    // back, so the retry is actually issued rather than refused.
    a.bannerSlot('dead').lastErrorAt =
        DateTime.now().subtract(const Duration(seconds: 20));

    // ...and comes back. `live` has an ad and is restored; `dead` takes the
    // reload branch.
    a.onAppResumed();
    await settle();

    expect(a.banner('live').visible.value, isTrue,
        reason: 'sanity — the key that kept its ad must come back');

    final retry = a.debugBannerListenerFor('dead');
    expect(retry, isNotNull, reason: 'sanity — the retry was actually issued');

    // The retry fills. AdMob served an ad; the publisher was billed a request.
    retry!.onAdLoaded!(dummyBanner());

    expect(a.banner('dead').visible.value, isTrue,
        reason: 'THE finding — a stale background hold made this fill render '
            'as nothing, on a live inventory slot, until some later '
            'background→foreground cycle happened to release it');
    expect(a.banner('dead').isLoaded.value, isTrue);
  });

  test('CONTROL — the reload stays blank until its fill actually lands',
      () async {
    final a = await newAdapter();

    await a.loadBannerIfNeeded('live', 320);
    a.debugBannerListenerFor('live')!.onAdLoaded!(dummyBanner());
    await a.loadBannerIfNeeded('dead', 320);
    a.debugBannerListenerFor('dead')!.onAdFailedToLoad!(dummyBanner(), err());

    a.onAppPaused();
    a.onAppResumed();
    await settle();

    expect(a.banner('dead').visible.value, isFalse,
        reason: 'releasing the background owner must not flash an empty '
            'placeholder — the reload holds it under its own name until the '
            'fill arrives');
  });

  // ── Round-29 QC (both reviewers, BLOCKER) ───────────────────────────────
  //
  // `onAppResumed` has THREE cases, not two. Round 28 fixed the reload branch
  // and the has-an-ad branch, and left the third — a key that is registered but
  // has never filled and has never failed — holding forever. Every test above
  // drives its key through a real `onAdFailedToLoad` first, i.e. only ever
  // exercises the branch that was fixed. That is why the miss survived.

  test('a key that never loaded and never failed is released on resume too',
      () async {
    final a = await newAdapter();

    // `live` fills, so the global `_bannerAdsByKey.isNotEmpty` guard is true.
    await a.loadBannerIfNeeded('live', 320);
    a.debugBannerListenerFor('live')!.onAdLoaded!(dummyBanner());

    // `fresh` is registered — a widget mounted and asked for its listenables —
    // but its load never produced an ad object and never errored: offline, a
    // closed consent gate, a daily cap, VIP at the time. None of those set
    // `needsRecovery`.
    final fresh = a.banner('fresh');
    expect(fresh.needsRecovery, isFalse, reason: 'sanity — no recovery debt');

    a.onAppPaused();
    expect(fresh.visible.value, isFalse,
        reason: 'sanity — the pause guard is global, so it blanks this one too');

    a.onAppResumed();
    await settle();

    // The gate reopens and the banner finally fills. AdMob served an ad and
    // counted an impression.
    await a.loadBannerIfNeeded('fresh', 320);
    a.debugBannerListenerFor('fresh')!.onAdLoaded!(dummyBanner());

    expect(fresh.visible.value, isTrue,
        reason: 'THE finding — the third case kept a stale background hold, so '
            'this paid fill rendered as a grey placeholder for the rest of the '
            'session');
  });

  test('same for MREC — the third case is in both loops', () async {
    final a = await newAdapter();

    await a.loadMrecIfNeeded('live', 0);
    a.debugMrecListenerFor('live')!.onAdLoaded!(dummyBanner());

    final fresh = a.mrec('fresh');
    a.onAppPaused();
    expect(fresh.visible.value, isFalse);

    a.onAppResumed();
    await settle();

    await a.loadMrecIfNeeded('fresh', 0);
    a.debugMrecListenerFor('fresh')!.onAdLoaded!(dummyBanner());

    expect(fresh.visible.value, isTrue,
        reason: 'the banner loop and the MREC loop had the identical hole');
  });

  // Round-30 QC (reviewer B, MAJOR) — the release must not sit behind the load
  // gate. `onAppPaused` takes the hold with no gate at all; `onAppResumed`
  // returned early whenever `canReload()` was false — offline in a lift, daily
  // cap reached while backgrounded — and stranded it. AdMob's own auto-refresh
  // then delivered the next fill onto a surface the widget tree had replaced
  // with a SizedBox, and kept recording impressions against it.

  test('a resume with the gate shut still gives the surface back', () async {
    final a = await newAdapter();
    await a.loadBannerIfNeeded('k', 320);
    a.debugBannerListenerFor('k')!.onAdLoaded!(dummyBanner());

    a.onAppPaused();
    expect(a.banner('k').visible.value, isFalse);

    // The user comes back with no connectivity.
    a.canReload = () => false;
    a.onAppResumed();
    await settle();

    expect(a.banner('k').visible.value, isTrue,
        reason: 'THE finding — releasing a display hold requests nothing, so '
            'it does not belong behind the load gate; leaving it held made the '
            'banner a grey gap for the session while still being billed');
  });

  test('CONTROL — an App Open outlives a gate-closed resume', () async {
    final a = await newAdapter();
    await a.loadBannerIfNeeded('k', 320);
    a.debugBannerListenerFor('k')!.onAdLoaded!(dummyBanner());

    a.setInlineAdsHidden(true);
    a.canReload = () => false;
    a.onAppResumed();
    await settle();

    expect(a.banner('k').visible.value, isFalse,
        reason: 'the early return releases the BACKGROUND owner only — a '
            'fullscreen ad is still on screen');
  });

  test('CONTROL — an App Open still wins over a fill that lands under it',
      () async {
    final a = await newAdapter();

    await a.loadBannerIfNeeded('k', 320);
    a.setInlineAdsHidden(true); // App Open goes up
    expect(a.banner('k').visible.value, isFalse);

    a.debugBannerListenerFor('k')!.onAdLoaded!(dummyBanner());
    expect(a.banner('k').visible.value, isFalse,
        reason: 'a fill landing mid-App-Open must not draw over it');

    a.setInlineAdsHidden(false);
    expect(a.banner('k').visible.value, isTrue,
        reason: 'and it appears the moment the fullscreen ad is gone');
  });
}
