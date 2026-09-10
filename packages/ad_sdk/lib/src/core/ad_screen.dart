import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../state/ad_placement.dart';
import '../utils/safe_logger.dart';
import '../widget/ad_loading_dialog.dart';
import '../widget/banner_ad_widget.dart';
import '../widget/mrec_ad_widget.dart';
import '../widget/native_ad_widget.dart';
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
  ///
  /// T107 follow-up — [placement] forwards through to [BannerAdWidget];
  /// without this, the widget's own `placement` param (added for T107) was
  /// unreachable from the documented `AdScreen`/`buildBanner()` integration
  /// path, so every per-placement cap/stat host apps actually use this
  /// helper for silently stayed on `AdPlacement.unspecified`.
  ///
  /// T153 — [active] forwards through the same way. `null` (the default)
  /// defers entirely to [BannerAdWidget]'s own automatic `VisibilityDetector`
  /// signal, exactly like constructing `BannerAdWidget` directly — pass
  /// `active: selectedIndex == myIndex` for a bare `IndexedStack` tab (see
  /// [BannerAdWidget]'s own doc comment for why the automatic signal cannot
  /// see a hidden `IndexedStack` child at all). Before this, a host using
  /// this documented helper (rather than constructing `BannerAdWidget`
  /// directly) had no way to reach that param — the exact `IndexedStack`
  /// use-case `active` exists for was unreachable through the recommended
  /// integration path.
  Widget buildBanner({
    AdPlacement placement = AdPlacement.unspecified,
    bool? active,
  }) {
    SafeLogger.d(_tag, 'buildBanner $runtimeType');
    return BannerAdWidget(placement: placement, active: active);
  }

  /// Returns a [MrecAdWidget] that manages its own lifecycle.
  /// Place this anywhere in your widget tree.
  ///
  /// T153 — [active] forwards through the same way as [buildBanner]'s.
  Widget buildMrec({
    AdPlacement placement = AdPlacement.unspecified,
    bool? active,
  }) {
    SafeLogger.d(_tag, 'buildMrec $runtimeType');
    return MrecAdWidget(placement: placement, active: active);
  }

  /// Returns a [NativeAdWidget] that manages its own lifecycle.
  /// Place this anywhere in your widget tree.
  ///
  /// T153 — [active] forwards through too. Unlike [buildBanner]/[buildMrec],
  /// [NativeAdWidget.active] has no automatic fallback (see its own class
  /// doc comment for why) — it defaults to `true`, matching
  /// [NativeAdWidget]'s own default.
  Widget buildNative({
    AdPlacement placement = AdPlacement.unspecified,
    bool active = true,
  }) {
    SafeLogger.d(_tag, 'buildNative $runtimeType');
    return NativeAdWidget(placement: placement, active: active);
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

  /// Shows a rewarded **interstitial** ad, with the intro screen AdMob's
  /// policy requires in front of it.
  ///
  /// Round-23 QC (reviewer B, BLOCKER) — the rewarded-interstitial format is
  /// the one fullscreen format Google mandates an announcement for: the user
  /// must be told an ad is coming, what the reward is, and be given a way out,
  /// *before* it plays. The SDK shipped the format with no such screen and no
  /// mention of the obligation in the README, so every host that adopted it was
  /// out of policy by default — with the publisher's own AdMob account, not the
  /// SDK's, on the hook.
  ///
  /// The disclosure is on by default for that reason. A host that renders its
  /// own intro screen (and it should — localised, branded, naming the actual
  /// reward) passes `showDisclosure: false` and takes the obligation on.
  /// Set [disclosureTitle]/[disclosureSubtitle]/[disclosureButtonLabel]/
  /// [disclosureCancelLabel] to localise the built-in one; the fallbacks are
  /// English, so a non-English host must pass its own strings.
  ///
  /// [onDone] reports `(shown, earned)` — `shown` is true whenever the ad was
  /// displayed, whether or not the user stayed to the reward point. Declining
  /// the intro screen reports `(false, false)` and costs no ad budget.
  Future<void> showRewardedInterstitialAd({
    required void Function(bool shown, bool earned) onDone,
    AdPlacement placement = AdPlacement.unspecified,
    bool showDisclosure = true,
    String? disclosureTitle,
    String? disclosureSubtitle,
    String? disclosureButtonLabel,
    String? disclosureCancelLabel,
  }) async {
    if (_isDisposed || !mounted) {
      SafeLogger.d(_tag,
          'showRewardedInterstitialAd ⏭️ widget disposed/unmounted → false');
      onDone(false, false);
      return;
    }
    // VIP suppression, the not-ready toast and every safety gate live in
    // AdManager — deliberately not duplicated here. The only thing checked
    // before the intro screen is whether an ad exists at all, because showing
    // an announcement for an ad that cannot play is worse than showing nothing.
    if (!AdManager().canShowRewardedInterstitialAd()) {
      SafeLogger.d(_tag, 'showRewardedInterstitialAd ⏭️ no valid ad');
      TopToast.show(
        context,
        icon: Icons.hourglass_top_rounded,
        message: AdManager().config?.adNotReadyMessage ??
            'Ad not ready — please wait and try again.',
      );
      onDone(false, false);
      return;
    }

    if (showDisclosure) {
      final proceed = await _showRewardDisclosure(
        title: disclosureTitle ?? 'Watch an ad for your reward',
        subtitle: disclosureSubtitle ??
            'A short ad will play. You can claim your reward once it '
                'finishes.',
        buttonLabel: disclosureButtonLabel,
        cancelLabel: disclosureCancelLabel,
      );
      if (!proceed) {
        SafeLogger.d(
            _tag, 'showRewardedInterstitialAd ⏭️ disclosure declined');
        onDone(false, false);
        return;
      }
      if (!mounted || _isDisposed) {
        SafeLogger.d(
            _tag, 'showRewardedInterstitialAd ⏭️ widget gone after disclosure');
        onDone(false, false);
        return;
      }
    }

    AdLoadingDialog.showAdBuffer(context, onComplete: () {
      if (!mounted || _isDisposed) {
        SafeLogger.d(_tag,
            'showRewardedInterstitialAd ⏭️ widget gone after dialog buffer');
        onDone(false, false);
        return;
      }
      AdManager().showRewardedInterstitialAd(
        placement: placement,
        onDone: onDone,
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
