// T147 — `canShowRewardedAd()` gated itself on the WRONG format's remote
// kill switch (T137): it read `AdSlotType.rewardedInterstitial`'s
// disabledFormats entry instead of `AdSlotType.rewarded`'s (copy-paste from
// `canShowRewardedInterstitialAd()` right above it). A host disabling one
// format remotely got the other format's button gated instead — either a
// button that shows but does nothing when tapped, or a button hidden while
// the real ad path still shows fine.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  @override
  void resyncSessionClock() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AdMobAdapter> setUpAdapter(
      {required Set<String> disabledFormats}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs,
        params:
            AdSafetyParams.debug.copyWith(disabledFormats: disabledFormats));
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip(false);
    final admob = AdMobAdapter();
    AdManager().debugSetAdapter(admob);
    return admob;
  }

  test(
      'remote kill switch disabling ONLY rewardedInterstitial must not hide '
      'the rewarded button', () async {
    final admob =
        await setUpAdapter(disabledFormats: {'rewardedInterstitial'});
    admob.rewardedSlot.beginLoad();
    admob.rewardedSlot.markReady();

    expect(AdManager().canShowRewardedAd(), isTrue,
        reason: 'only rewardedInterstitial is disabled remotely — the '
            'rewarded button must stay showable');
  });

  test(
      'remote kill switch disabling ONLY rewarded must hide the rewarded '
      'button, not leave it showable', () async {
    final admob = await setUpAdapter(disabledFormats: {'rewarded'});
    admob.rewardedSlot.beginLoad();
    admob.rewardedSlot.markReady();

    expect(AdManager().canShowRewardedAd(), isFalse,
        reason: 'rewarded is disabled remotely — the button must not claim '
            'showable when showRewardedAd() would actually be blocked, '
            'leaving the user with a tap that does nothing');
  });

  test(
      'remote kill switch disabling rewardedInterstitial must still gate '
      'canShowRewardedInterstitialAd() itself (sanity, unaffected by T147)',
      () async {
    final admob =
        await setUpAdapter(disabledFormats: {'rewardedInterstitial'});
    admob.rewardedInterstitialSlot.beginLoad();
    admob.rewardedInterstitialSlot.markReady();

    expect(AdManager().canShowRewardedInterstitialAd(), isFalse,
        reason: 'the sibling method was never buggy — this is a regression '
            'guard, not new behaviour');
  });
}
