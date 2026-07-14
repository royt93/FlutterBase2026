import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../state/ad_placement.dart';
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
  /// [placement] tags this call for analytics — used by `AdShowEvent`.
  void showInterstitialAd({
    required void Function(bool) onDone,
    AdPlacement placement = AdPlacement.unspecified,
  }) {
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
      SafeLogger.d(
          _tag, 'showInterstitialAd ⏭️ pre-check failed → skip dialog');
      onDone(false);
      return;
    }

    SafeLogger.d(
        _tag, 'showInterstitialAd ✅ pre-check passed → showing dialog buffer');
    AdLoadingDialog.showAdBuffer(context, onComplete: () {
      if (!mounted || _isDisposed) {
        SafeLogger.d(
            _tag, 'showInterstitialAd ⏭️ widget gone after dialog buffer');
        onDone(false);
        return;
      }
      SafeLogger.d(
          _tag, 'showInterstitialAd → calling AdManager.showInterstitial()');
      AdManager().showInterstitial(
        placement: placement,
        onDoneFlow: (result) {
          SafeLogger.d(_tag, 'showInterstitialAd onDoneFlow: result=$result');
          onDone(result);
        },
      );
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
  ///
  /// VIP behaviour (Q12B — caller must opt in): when the device is VIP and
  /// [vipAutoGrant] is `true`, the reward is auto-granted without showing an
  /// ad. When [vipAutoGrant] is `false` (default), the SDK behaves like
  /// "no ad available" — caller decides reward outcome.
  ///
  /// [disclosureTitle] (optional): when set, a confirm dialog naming the
  /// reward is shown right before the ad plays, so the user explicitly opts
  /// in instead of an ad appearing unannounced. Omitted (default): unchanged
  /// behaviour — straight to the ad after the ready/throttle pre-check.
  ///
  /// [ssvUserId]/[ssvCustomData] (optional) are forwarded to
  /// [AdManager.showRewardedAd] for server-side reward verification (SSV) —
  /// see that method's doc for details.
  /// [disclosureButtonLabel]/[disclosureCancelLabel] localize the two dialog
  /// actions; both default to English so non-English callers should pass
  /// their own (e.g. a `vi_VN` host should not rely on the fallback).
  Future<void> showRewardedAd({
    required void Function(bool) onEarnedReward,
    bool vipAutoGrant = false,
    AdPlacement placement = AdPlacement.unspecified,
    String? disclosureTitle,
    String? disclosureSubtitle,
    String? disclosureButtonLabel,
    String? disclosureCancelLabel,
    String? ssvUserId,
    String? ssvCustomData,
  }) async {
    SafeLogger.d(
      _tag,
      'showRewardedAd called from $runtimeType, '
      'isDisposed=$_isDisposed, mounted=$mounted, vipAutoGrant=$vipAutoGrant',
    );

    if (_isDisposed || !mounted) {
      SafeLogger.d(_tag, 'showRewardedAd ⏭️ widget disposed/unmounted → false');
      onEarnedReward(false);
      return;
    }

    // VIP device: caller opt-in required (Q12B)
    if (AdManager().isVIPMember()) {
      if (vipAutoGrant) {
        SafeLogger.d(_tag, 'showRewardedAd ✅ VIP + opt-in → auto-reward');
        onEarnedReward(true);
      } else {
        SafeLogger.d(_tag,
            'showRewardedAd ⏭️ VIP without opt-in → false (caller chooses)');
        onEarnedReward(false);
      }
      return;
    }

    final canShow = AdManager().canShowRewardedAd();
    SafeLogger.d(_tag, 'showRewardedAd pre-check result: canShow=$canShow');

    if (!canShow) {
      // No valid ad — show top toast using the configured message, then notify caller.
      SafeLogger.d(_tag,
          'showRewardedAd ⏭️ no valid ad → showing TopToast + earned=false');
      TopToast.show(
        context,
        icon: Icons.hourglass_top_rounded,
        message: AdManager().config?.adNotReadyMessage ??
            'Ad not ready — please wait and try again.',
      );
      onEarnedReward(false);
      return;
    }

    if (disclosureTitle != null) {
      final proceed = await _showRewardDisclosure(
        title: disclosureTitle,
        subtitle: disclosureSubtitle,
        buttonLabel: disclosureButtonLabel,
        cancelLabel: disclosureCancelLabel,
      );
      if (!proceed) {
        SafeLogger.d(_tag, 'showRewardedAd ⏭️ disclosure declined → false');
        onEarnedReward(false);
        return;
      }
      if (!mounted || _isDisposed) {
        SafeLogger.d(_tag, 'showRewardedAd ⏭️ widget gone after disclosure');
        onEarnedReward(false);
        return;
      }
    }

    SafeLogger.d(
        _tag, 'showRewardedAd ✅ pre-check passed → showing dialog buffer');
    AdLoadingDialog.showAdBuffer(context, onComplete: () {
      if (!mounted || _isDisposed) {
        SafeLogger.d(_tag, 'showRewardedAd ⏭️ widget gone after dialog buffer');
        onEarnedReward(false);
        return;
      }
      SafeLogger.d(_tag, 'showRewardedAd → calling AdManager.showRewardedAd()');
      AdManager().showRewardedAd(
        vipAutoGrant: vipAutoGrant,
        placement: placement,
        ssvUserId: ssvUserId,
        ssvCustomData: ssvCustomData,
        onEarnedReward: (result) {
          SafeLogger.d(_tag, 'showRewardedAd onEarnedReward: result=$result');
          onEarnedReward(result);
        },
      );
    });
  }

  /// Small confirm dialog shown before a rewarded ad plays when the caller
  /// passes a [disclosureTitle] to [showRewardedAd] — explicit opt-in instead
  /// of an ad appearing with no warning. Returns `true` if the user tapped
  /// the confirm action, `false` on Cancel or dismissal.
  Future<bool> _showRewardDisclosure({
    required String title,
    String? subtitle,
    String? buttonLabel,
    String? cancelLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: subtitle == null ? null : Text(subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(buttonLabel ?? 'Watch ad'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  void dispose() {
    SafeLogger.d(_tag, 'dispose() $runtimeType');
    _isDisposed = true;
    super.dispose();
  }
}
