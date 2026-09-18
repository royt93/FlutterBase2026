// Round-44 audit fix — native ads were the one inline surface never included
// in the "blank everything while a fullscreen ad is up" pass. Banner/MREC
// were fixed at round 23; native's own adapter doc comment openly admitted
// "never hides them the way banner/mrec are hidden" — a live native ad
// stayed mounted and visible underneath an App Open ad on resume, the exact
// ad-over-ad placement Google's App Open guidance prohibits, just reached
// through a format the original fix never covered.
//
// Mirrors r23_appopen_over_banner_test.dart's coverage shape, for `native`
// instead of `banner`/`mrec`.

import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopBridge implements AppLovinBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('AdMobAdapter blanks a native ad while a fullscreen ad is up', () {
    final admob = AdMobAdapter();
    final key = Object();
    final l = admob.native(key);
    expect(l.visible.value, isTrue, reason: 'sanity — native starts visible');

    admob.setInlineAdsHidden(true);
    expect(l.visible.value, isFalse,
        reason: 'THE finding — a live native ad stayed mounted and visible '
            'under an App Open ad, the same placement violation round 23 '
            'fixed for banner/MREC');

    admob.setInlineAdsHidden(false);
    expect(l.visible.value, isTrue,
        reason: 'and it must come back the moment the fullscreen ad is gone');
  });

  test('AppLovinAdapter blanks a native ad while a fullscreen ad is up', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    final key = Object();
    final l = al.native(key);
    expect(l.visible.value, isTrue, reason: 'sanity');

    al.setInlineAdsHidden(true);
    expect(l.visible.value, isFalse);

    al.setInlineAdsHidden(false);
    expect(l.visible.value, isTrue);
  });

  test('a native ad created while the App Open is already up inherits the '
      'hold (AdMob)', () {
    final admob = AdMobAdapter();
    admob.setInlineAdsHidden(true); // no native ads exist yet

    final late_ = admob.native('late');
    expect(late_.visible.value, isFalse,
        reason: 'a native ad mounting under a live App Open must not draw '
            'on top of it — same "late arrival" gap round 30 fixed for '
            'banner');

    admob.setInlineAdsHidden(false);
    expect(late_.visible.value, isTrue);
  });

  test('a native ad created while the App Open is already up inherits the '
      'hold (AppLovin)', () {
    final al = AppLovinAdapter(bridge: _NoopBridge());
    al.setInlineAdsHidden(true);

    final late_ = al.native('late');
    expect(late_.visible.value, isFalse);

    al.setInlineAdsHidden(false);
    expect(late_.visible.value, isTrue);
  });

  test('CONTROL — a native ad hidden for another reason stays hidden '
      '(AdMob)', () {
    final admob = AdMobAdapter();
    final live = admob.native(Object());
    final alreadyHidden = admob.native(Object())..visible.value = false;

    admob.setInlineAdsHidden(true);
    admob.setInlineAdsHidden(false);

    expect(live.visible.value, isTrue);
    expect(alreadyHidden.visible.value, isFalse,
        reason: 'restoring must return what THIS call hid, not switch every '
            'native surface on');
  });

  test('disposing a native instance forgets its fullscreen hold (AdMob)', () {
    // Round-30's own lesson for banner: a hold left dangling on a disposed
    // listenables object is a leak, not a functional bug here (the object is
    // garbage once dropped) — this guards the dispose path exists at all,
    // mirroring disposeBannerInstance/disposeMrecInstance.
    final admob = AdMobAdapter();
    final key = Object();
    admob.native(key);
    admob.setInlineAdsHidden(true);

    expect(() => admob.disposeNativeInstance(key), returnsNormally);
  });
}
