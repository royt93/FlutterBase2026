import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../utils/safe_logger.dart';
import '../widget/ad_loading_dialog.dart';
import '../widget/banner_ad_widget.dart';
import '../widget/top_toast.dart';

/// Base widget class for screens that use ads.
///
/// Extend this instead of [StatefulWidget]:
/// ```dart
/// class HomeScreen extends AdScreen {
///   const HomeScreen({super.key});
///   @override State<HomeScreen> createState() => _HomeScreenState();
/// }
///
/// class _HomeScreenState extends AdScreenState<HomeScreen> {
///   @override
///   Widget build(BuildContext context) => Column(
///     children: [buildBanner(), ...],
///   );
/// }
/// ```
abstract class AdScreen extends StatefulWidget {
  const AdScreen({super.key});
}

/// Base state for [AdScreen]. Provides [buildBanner], [showInterstitialAd],
/// and [showRewardedAd] helpers with built-in safety checks.
///
/// No dependency on GetX or any particular state management library.
abstract class AdScreenState<T extends AdScreen> extends State<T> {
  static const String _tag = 'AdScreen';

  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState $runtimeType — preloading interstitial');
    AdManager().loadInterstitial();
  }

  /// Returns a [BannerAdWidget] that manages its own lifecycle.
  /// Place this anywhere in your widget tree (typically top or bottom of body).
  Widget buildBanner() {
    SafeLogger.d(_tag, 'buildBanner $runtimeType');
    return const BannerAdWidget();
  }

  // ════════════════════════════════════════════════════
  // INTERSTITIAL
  // ════════════════════════════════════════════════════

  /// Show an interstitial ad with safety checks.
  ///
  /// [onDone] is called with `true` if the ad was shown, `false` otherwise.
  void showInterstitialAd({required void Function(bool) onDone}) {
    SafeLogger.d(
      _tag,
      'showInterstitialAd called from $runtimeType, '
      'isDisposed=$_isDisposed, mounted=$mounted',
    );

    if (_isDisposed || !mounted) {
      SafeLogger.d(_tag, 'showInterstitialAd ⏭️ widget disposed/unmounted');
      onDone(false);
      return;
    }

    final canShow = AdManager().canShowInterstitial();
    SafeLogger.d(_tag, 'showInterstitialAd pre-check result: canShow=$canShow');

    if (!canShow) {
      SafeLogger.d(_tag, 'showInterstitialAd ⏭️ pre-check failed → skip dialog');
      onDone(false);
      return;
    }

    SafeLogger.d(_tag, 'showInterstitialAd ✅ pre-check passed → showing dialog buffer');
    AdLoadingDialog.showAdBuffer(context, onComplete: () {
      if (!mounted || _isDisposed) {
        SafeLogger.d(_tag, 'showInterstitialAd ⏭️ widget gone after dialog buffer');
        onDone(false);
        return;
      }
      SafeLogger.d(_tag, 'showInterstitialAd → calling AdManager.showInterstitial()');
      AdManager().showInterstitial(onDoneFlow: (result) {
        SafeLogger.d(_tag, 'showInterstitialAd onDoneFlow: result=$result');
        onDone(result); // Fix #5: always call — caller must handle unmounted state
      });
    });
  }

  // ════════════════════════════════════════════════════
  // REWARDED
  // ════════════════════════════════════════════════════

  /// Show a rewarded ad with safety checks.
  ///
  /// Behaviour:
  /// - Ad available → show ad → [onEarnedReward] called with `true` when reward earned.
  /// - Ad unavailable/throttled → [onEarnedReward] called with `false`.
  ///   The caller should notify the user (e.g. snackbar: 'Ad not ready, try again').
  /// - Widget disposed/unmounted → [onEarnedReward] called with `false` (unsafe to act).
  void showRewardedAd({required void Function(bool) onEarnedReward}) {
    SafeLogger.d(
      _tag,
      'showRewardedAd called from $runtimeType, '
      'isDisposed=$_isDisposed, mounted=$mounted',
    );

    if (_isDisposed || !mounted) {
      SafeLogger.d(_tag, 'showRewardedAd ⏭️ widget disposed/unmounted → false');
      onEarnedReward(false);
      return;
    }

    // VIP device: auto-grant reward without any ad or dialog
    if (AdManager().isVIPMember()) {
      SafeLogger.d(_tag, 'showRewardedAd ✅ VIP device → auto-reward');
      onEarnedReward(true);
      return;
    }

    final canShow = AdManager().canShowRewardedAd();
    SafeLogger.d(_tag, 'showRewardedAd pre-check result: canShow=$canShow');

    if (!canShow) {
      // No valid ad — show top toast using the configured message, then notify caller.
      SafeLogger.d(_tag, 'showRewardedAd ⏭️ no valid ad → showing TopToast + earned=false');
      TopToast.show(
        context,
        icon: Icons.hourglass_top_rounded,
        message: AdManager().config?.adNotReadyMessage ??
            'Ad not ready — please wait and try again.',
      );
      onEarnedReward(false);
      return;
    }

    SafeLogger.d(_tag, 'showRewardedAd ✅ pre-check passed → showing dialog buffer');
    AdLoadingDialog.showAdBuffer(context, onComplete: () {
      if (!mounted || _isDisposed) {
        SafeLogger.d(_tag, 'showRewardedAd ⏭️ widget gone after dialog buffer');
        onEarnedReward(false);
        return;
      }
      SafeLogger.d(_tag, 'showRewardedAd → calling AdManager.showRewardedAd()');
      AdManager().showRewardedAd(onEarnedReward: (result) {
        SafeLogger.d(_tag, 'showRewardedAd onEarnedReward: result=$result');
        onEarnedReward(result); // Fix #6: always call — caller must handle unmounted state
      });
    });
  }


  @override
  void dispose() {
    SafeLogger.d(_tag, 'dispose() $runtimeType');
    _isDisposed = true;
    super.dispose();
  }
}
