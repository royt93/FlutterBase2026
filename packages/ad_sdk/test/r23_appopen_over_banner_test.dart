// Round-23 QC (reviewer B, MAJOR) — an App Open ad must not be presented on
// top of a live banner or MREC.
//
// Google's App Open guidance names this placement: do not show an App Open ad
// over other ads, banner content included. The resume path walked straight
// into it. `onAppPaused()` blanks every inline surface when the app leaves the
// foreground; on the way back `onAppResumed()` makes them visible again, and
// only THEN does `showAppOpenAdOnResume()` decide to present. A user returning
// to any monetised screen got a fullscreen ad drawn over a banner that had
// just been switched back on.
//
// Skipping the App Open instead would have been the cheap fix and the wrong
// one: most screens in a real app carry a banner, so the format would be dead
// on arrival. The inline surfaces are blanked for the duration of the
// fullscreen ad and exactly those are restored on dismiss.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/_inline_visibility.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

BannerListenables _listenables() => BannerListenables(
      isLoaded: ValueNotifier<bool>(true),
      hasError: ValueNotifier<bool>(false),
      adSize: ValueNotifier<Size?>(null),
      autoRefreshEnabled: ValueNotifier<bool>(true),
      visible: ValueNotifier<bool>(true),
    );

/// Base fake: shows an App Open immediately and records what the inline
/// surfaces looked like at the moment the ad went up.
class _AppOpenAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  int showAppOpenCalls = 0;
  bool throwOnShow = false;

  /// Set by the subclass at the instant the ad is presented.
  bool? inlineHiddenWhenShown;

  @override
  String get tag => 'fake-appopen';

  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    showAppOpenCalls++;
    if (throwOnShow) throw StateError('native show blew up');
    appOpenSlot.beginShow();
    appOpenSlot.markDismissed();
    onDismiss(true);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The shipped adapters' shape: knows how to blank its inline surfaces.
class _InlineAwareAdapter extends _AppOpenAdapter implements InlineAdVisibility {
  final BannerListenables bannerL = _listenables();
  final BannerListenables mrecL = _listenables();
  final Set<BannerListenables> _hidden = {};

  @override
  void setInlineAdsHidden(bool hidden) {
    if (hidden) {
      for (final l in [bannerL, mrecL]) {
        if (!l.visible.value) continue;
        l.visible.value = false;
        _hidden.add(l);
      }
      return;
    }
    for (final l in _hidden) {
      l.visible.value = true;
    }
    _hidden.clear();
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    inlineHiddenWhenShown = !bannerL.visible.value && !mrecL.visible.value;
    return super.showAppOpen(onDismiss: onDismiss);
  }
}

class _NoopBridge implements AppLovinBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;
  @override
  bool get isActive => _active;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip(false);
    AdManager().markSplashInactive();
    AdScreenRouteLogger.resetState();
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().markSplashActive();
    AdScreenRouteLogger.resetState();
  });

  test('the banner and MREC are blanked while the App Open is on screen',
      () async {
    final adapter = _InlineAwareAdapter();
    AdManager().debugSetAdapter(adapter);

    await AdManager().showAppOpenAd(bypassSafety: true, onAdDismiss: (_) {});

    expect(adapter.showAppOpenCalls, 1, reason: 'sanity — the ad did play');
    expect(adapter.inlineHiddenWhenShown, isTrue,
        reason: 'THE finding: an App Open drawn over a live banner is the '
            'placement Google names as prohibited');
  });

  test('and both come back the moment it is dismissed', () async {
    final adapter = _InlineAwareAdapter();
    AdManager().debugSetAdapter(adapter);

    await AdManager().showAppOpenAd(bypassSafety: true, onAdDismiss: (_) {});

    expect(adapter.bannerL.visible.value, isTrue);
    expect(adapter.mrecL.visible.value, isTrue,
        reason: 'a banner the host paid to load must not stay blank for the '
            'rest of the session');
  });

  test('a show that throws still gives the inline surfaces back', () async {
    final adapter = _InlineAwareAdapter()..throwOnShow = true;
    AdManager().debugSetAdapter(adapter);

    await expectLater(
      AdManager().showAppOpenAd(bypassSafety: true, onAdDismiss: (_) {}),
      throwsA(isA<StateError>()),
    );

    expect(adapter.bannerL.visible.value, isTrue,
        reason: 'no dismiss callback is coming after a throw, so the restore '
            'cannot live only in that callback');
  });

  test('CONTROL — a surface hidden for another reason stays hidden', () async {
    // Route-paused, or the app is in the background: something else already
    // blanked it and owns when it comes back. Run against the real adapter —
    // the tracked-set logic lives there, in two copies.
    final admob = AdMobAdapter();
    final live = admob.banner(Object());
    final alreadyHidden = admob.banner(Object())..visible.value = false;

    admob.setInlineAdsHidden(true);
    admob.setInlineAdsHidden(false);

    expect(live.visible.value, isTrue);
    expect(alreadyHidden.visible.value, isFalse,
        reason: 'restoring must return what this call hid, not switch every '
            'inline surface on');
  });

  test('AppLovinAdapter carries the same behaviour', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final live = al.banner(Object());
    final alreadyHidden = al.banner(Object())..visible.value = false;

    al.setInlineAdsHidden(true);
    expect(live.visible.value, isFalse);

    al.setInlineAdsHidden(false);
    expect(live.visible.value, isTrue);
    expect(alreadyHidden.visible.value, isFalse);
  });

  test('CONTROL — an adapter without the capability still shows the ad',
      () async {
    // `InlineAdVisibility` is deliberately not part of the exported
    // `AdProviderAdapter`, so a host fake that predates it must keep working.
    final adapter = _AppOpenAdapter();
    AdManager().debugSetAdapter(adapter);

    bool? dismissed;
    await AdManager()
        .showAppOpenAd(bypassSafety: true, onAdDismiss: (d) => dismissed = d);

    expect(adapter.showAppOpenCalls, 1);
    expect(dismissed, isTrue);
  });

  // ── Round-26 QC (reviewer A, MINOR) ─────────────────────────────────────
  //
  // The first cut stored a snapshot of "what I hid". That is not the same as
  // "who wants it hidden", and the two stop agreeing the moment a second owner
  // appears while the fullscreen ad is still up: it writes `false` over a
  // `false`, so the snapshot never notices, and the dismiss then switches the
  // surface back on underneath a backgrounded — or route-paused — app.
  //
  // The counting lives in `InlineVisibilityOwners`, which both adapters hold,
  // so that is what these assert. The adapter-level consequence is the CONTROL
  // above ("a surface hidden for another reason stays hidden"), which now holds
  // by construction instead of by snapshot.

  group('inline visibility is owned, not snapshotted', () {
    test('a surface stays hidden until the LAST owner lets go', () {
      final owners = InlineVisibilityOwners();
      final l = _listenables();

      owners.hide(l, InlineHideReason.fullscreen);
      expect(l.visible.value, isFalse);

      // The app is backgrounded while the ad is still on screen. Nothing
      // changes visually — it is already false — which is exactly why a
      // snapshot missed this.
      owners.hide(l, InlineHideReason.background);
      expect(l.visible.value, isFalse);

      owners.show(l, InlineHideReason.fullscreen); // App Open dismissed
      expect(l.visible.value, isFalse,
          reason: 'THE finding — the app is still in the background, so '
              'putting the banner back means drawing an ad nobody is looking '
              'at, on a surface the other owner will never switch on again');

      owners.show(l, InlineHideReason.background);
      expect(l.visible.value, isTrue,
          reason: 'and it must come back once nobody is holding it');
    });

    test('releasing the same owner twice is not the other owner letting go',
        () {
      final owners = InlineVisibilityOwners();
      final l = _listenables();

      owners.hide(l, InlineHideReason.fullscreen);
      owners.hide(l, InlineHideReason.background);

      owners.show(l, InlineHideReason.fullscreen);
      owners.show(l, InlineHideReason.fullscreen); // a duplicate dismiss

      expect(l.visible.value, isFalse,
          reason: 'duplicate dismisses happen; they must not be counted as '
              'the background owner releasing');
    });

    test('CONTROL — ownership is not claimed over a surface someone else hid',
        () {
      final owners = InlineVisibilityOwners();
      final l = _listenables()..visible.value = false;

      owners.hide(l, InlineHideReason.fullscreen);
      owners.show(l, InlineHideReason.fullscreen);

      expect(l.visible.value, isFalse,
          reason: 'a route-paused surface belongs to whoever paused the route '
              '— claiming it would mean revealing it on their behalf');
    });

    test('CONTROL — a fresh fill does not draw itself over a fullscreen ad',
        () {
      final owners = InlineVisibilityOwners();
      final l = _listenables();

      owners.hide(l, InlineHideReason.fullscreen);
      owners.revealUnlessHeld(l); // an ad finishes loading mid-App-Open
      expect(l.visible.value, isFalse);

      owners.show(l, InlineHideReason.fullscreen);
      owners.revealUnlessHeld(l);
      expect(l.visible.value, isTrue,
          reason: 'and once nothing holds it, a fill does show');
    });
  });

  // Round-29 QC (reviewer B, MAJOR) — fix 6 was a NO-OP on AppLovin.
  //
  // `visible` is an AdMob-only flag: only `_buildAdmob()` in BannerAdWidget and
  // MrecAdWidget reads it, and `_buildAppLovin` branches on `hasError` and the
  // ad-view id instead. So flipping `visible` blanked nothing on a MAX build —
  // the banner kept rendering and auto-refreshing underneath the App Open ad,
  // which is exactly the invalid-traffic exposure this fix exists to close, for
  // one of the SDK's two shipped providers.
  //
  // Auto-refresh is the flag AppLovin honours, so that is the one that moves.

  test('AppLovin stops a live ad view refreshing under an App Open', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');
    al.debugSetBannerAdViewIdForTest('k', 1); // a live MAX ad view
    expect(l.autoRefreshEnabled.value, isTrue, reason: 'sanity');

    al.setInlineAdsHidden(true);
    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — a MAX banner that keeps refreshing under a '
            'fullscreen ad accrues impressions nobody can see');

    al.setInlineAdsHidden(false);
    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'and it must start earning again the moment the ad is gone');
  });

  test('CONTROL — AppLovin does not resume a route-paused banner', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');
    al.debugSetBannerAdViewIdForTest('k', 1);

    al.setInlineAdsHidden(true);
    al.setBannerRoutePaused('k', true); // another screen went on top meanwhile
    al.setInlineAdsHidden(false);

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'the route owns this one now — restarting its refresh would '
            'buy impressions on a screen the user has left');
  });

  // Round-30 QC (reviewer A, MAJOR) — the same lesson, a third time: a
  // *condition* cannot be released by name, so whoever writes the flag last
  // wins. Round 29 moved AppLovin's auto-refresh but wrote it directly, so an
  // App Open dismissed while the app was still backgrounded handed refresh back
  // and a MAX banner started refreshing on a screen nobody was looking at.

  test('AppLovin does not restart refresh while the app is still backgrounded',
      () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');
    al.debugSetBannerAdViewIdForTest('k', 1);

    al.setInlineAdsHidden(true); // App Open up
    al.onAppPaused(); // user leaves before the dismiss lands
    al.setInlineAdsHidden(false); // ...and the dismiss arrives

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — the background owner still holds it, and '
            'refreshing an inline ad nobody can see is the invalid-traffic '
            'exposure this whole fix exists to avoid');

    al.onAppResumed();
    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'and it must come back when the last owner lets go');
  });

  test('AppLovin route pause is an owner too, not a condition', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');
    al.debugSetBannerAdViewIdForTest('k', 1);

    al.setBannerRoutePaused('k', true);
    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'a banner under another route must not keep buying '
            'impressions');

    al.onAppPaused();
    al.onAppResumed(); // a full background cycle while the route is still up

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'the resume releases its OWN hold; the route still owns one');

    al.setBannerRoutePaused('k', false);
    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'and the route letting go is what brings it back');
  });

  // Round-31 QC (both reviewers, BLOCKER) — this used to be a CONTROL asserting
  // that a key with no ad view keeps `autoRefreshEnabled == true` under an App
  // Open, on the reasoning that holding it early "would leave refresh off when
  // the ad finally arrives". That reasoning was wrong — the hold is released BY
  // NAME on dismiss, which is the entire point of the ownership model — and the
  // test locked the defect in: it was green while a MAX banner refreshed
  // underneath a fullscreen ad. The assertion is inverted here, which is the
  // honest record of what it was doing.

  test('a MAX ad view that attaches under a live App Open does not refresh',
      () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k'); // mounted; preloadBanner still in flight

    al.setInlineAdsHidden(true); // launch App Open goes up
    al.debugSetBannerAdViewIdForTest('k', 1); // the pending preload lands

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — the commonest real cold start put a refreshing '
            'MAX banner under the launch App Open, which is the invalid-traffic '
            'exposure fix 6 exists to close');

    al.setInlineAdsHidden(false);
    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'and the dismiss releases it by name, so nothing is left off');
  });

  test('a route that pauses before the ad view attaches still holds it', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');

    al.setBannerRoutePaused('k', true); // another screen went on top first
    al.debugSetBannerAdViewIdForTest('k', 1); // then the view attached

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'pass 8 promoted routePaused to an owner but kept the broken '
            'acquire test, so this banner refreshed under the route on top');

    al.setBannerRoutePaused('k', false);
    expect(l.autoRefreshEnabled.value, isTrue);
  });

  // Round-30 QC (reviewer B, MAJOR) — a surface that appears WHILE the App Open
  // is on screen. Ownership fixed "who wants this hidden" for surfaces that
  // already existed; it said nothing about one created afterwards. A launch App
  // Open is up and the tree keeps building underneath it — a deep link
  // resolving, a splash handing off to home, a PageView mounting its next page.

  test('a banner that mounts under a live App Open is hidden too', () {
    final admob = AdMobAdapter();
    admob.setInlineAdsHidden(true); // no banners exist yet

    final late_ = admob.banner('late');
    expect(late_.visible.value, isFalse,
        reason: 'THE finding — a banner created inside the window filled and '
            'drew on top of the fullscreen ad, which is the same Google '
            'placement violation as round 23, through a different door');

    admob.setInlineAdsHidden(false);
    expect(late_.visible.value, isTrue,
        reason: 'and the ordinary dismiss path restores it, with no special '
            'case for late arrivals');
  });

  test('AppLovin carries the same inheritance — on the flag MAX actually reads',
      () {
    // Round-31 QC (reviewer B) — this asserted `visible`, which
    // `_buildAppLovin` never reads. It was green no matter what the MAX banner
    // did on screen, which is how the BLOCKER above survived four passes aimed
    // straight at this area. `autoRefreshEnabled` is the load-bearing flag here.
    final al = AppLovinAdapter(bridge: _NoopBridge());
    al.setInlineAdsHidden(true);

    final late_ = al.banner('late');
    expect(late_.autoRefreshEnabled.value, isFalse,
        reason: 'a banner mounting under a live App Open must not refresh');

    al.setInlineAdsHidden(false);
    expect(late_.autoRefreshEnabled.value, isTrue);
  });

  test('AppLovin releases the background hold even when the gate is shut', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k');
    al.debugSetBannerAdViewIdForTest('k', 1);

    al.onAppPaused(); // ungated: takes the background hold
    expect(l.autoRefreshEnabled.value, isFalse);

    al.canReload = () => false; // offline, or the daily cap was reached
    al.onAppResumed();

    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'pass 8 moved this above the gate in AdMob and did not carry '
            'it here, so a MAX banner never refreshed again for the session');
  });

  // ── Round-32 QC (both reviewers, BLOCKER + MAJOR) ───────────────────────

  test('a banner whose preload is in flight is held when the app backgrounds',
      () {
    // reviewer A — onAppPaused's acquire guard skipped a key with no MAX view
    // yet, so a preload landing while backgrounded attached auto-refreshing.
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k'); // mounted; preload still in flight

    al.onAppPaused();
    al.debugSetBannerAdViewIdForTest('k', 1); // the pending preload lands

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — the background owner must cover every mounted '
            'surface, not only ones that already have a MAX view');

    al.onAppResumed();
    expect(l.autoRefreshEnabled.value, isTrue);
  });

  test(
      'a recovered banner keeps its routePaused hold, not just its fullscreen '
      'one', () {
    // reviewer B — the recovery branch's forget() dropped EVERY owner, and only
    // fullscreen was re-taken. routePaused, taken on an earlier route push, was
    // silently lost.
    final al = AppLovinAdapter(bridge: _NoopBridge());
    al.debugSetBannerAdViewIdForTest('k', 1);
    al.setBannerRoutePaused('k', true); // another screen is on top

    final l = al.banner('k');
    expect(l.autoRefreshEnabled.value, isFalse, reason: 'sanity');

    // The banner no-fills while covered, then the app backgrounds and resumes —
    // onAppResumed's recovery branch discards and recreates the ad view.
    al.banner('k').markError();
    al.onAppResumed();

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — the recreated view must not refresh while route '
            'B is still on top of it, billing impressions nobody can see');

    al.setBannerRoutePaused('k', false);
    expect(l.autoRefreshEnabled.value, isTrue);
  });

  // ── Round-35 QC (reviewer B, MAJOR) ─────────────────────────────────────
  //
  // `_fullscreenOverInline` made a surface created while the App Open is up
  // inherit the hold; `background` had no equivalent. A key first created while
  // the app is already backgrounded — no prior `onAppPaused()` walk could ever
  // have reached it, since it did not exist yet — started with
  // `autoRefreshEnabled == true` and no owner holding it down.

  test('a banner first created while the app is already backgrounded is held',
      () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    al.onAppPaused(); // the app backgrounds with zero banners mounted

    final l = al.banner('newKey'); // a key nothing above could have seen

    expect(l.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — the exact "acquire only reaches pre-existing '
            'keys" shape rounds 28, 30, 31 and 32 each found for a different '
            'owner in this same file');

    al.onAppResumed();
    expect(l.autoRefreshEnabled.value, isTrue);
  });

  // ── Round-33 QC (reviewer A, MAJOR) ─────────────────────────────────────

  test('a resume that beats an in-flight preload still releases the '
      'background hold', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final l = al.banner('k'); // mounted; preload still in flight, no error yet

    al.onAppPaused();
    al.onAppResumed(); // resume lands BEFORE the preload does

    // The preload finally lands, after the resume.
    al.debugSetBannerAdViewIdForTest('k', 1);

    expect(l.autoRefreshEnabled.value, isTrue,
        reason: 'THE finding — neither onAppResumed branch touched a key with '
            'no ad view AND no error, so the background hold survived the '
            'resume and the preload inherited a refresh that never came back');
  });

  test('CONTROL — a banner mounting with no App Open up is not hidden', () {
    final admob = AdMobAdapter();
    expect(admob.banner('k').visible.value, isTrue,
        reason: 'inheriting a hold nobody is holding would blank every banner '
            'in the app');
  });

  test('AdMobAdapter blanks and restores its real listenables', () async {
    final admob = AdMobAdapter();
    final key = Object();
    final l = admob.banner(key);
    expect(l.visible.value, isTrue, reason: 'sanity — banners start visible');

    admob.setInlineAdsHidden(true);
    expect(l.visible.value, isFalse);

    admob.setInlineAdsHidden(false);
    expect(l.visible.value, isTrue);
  });
}
