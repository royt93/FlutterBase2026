import 'dart:async';
import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ad_manager.dart';
import 'signed_vip_key.dart';
import 'vip_entry.dart';
import 'vip_manager.dart';

/// All user-facing strings for [VipRedeemScreen]. Defaults are English; pass a
/// localized instance (e.g. built from your app's i18n) to translate. Mirrors
/// the `ConsentDialogStrings` pattern so the screen carries no i18n dependency.
class VipRedeemStrings {
  const VipRedeemStrings({
    this.sdkNotReady = 'VIP is not ready yet. Please try again in a moment.',
    this.enterKeyFirst = 'Enter a VIP key first.',
    this.successTitle = 'VIP activated 🎉',
    this.keyAlreadyUsed = 'This key has already been used on this device.',
    this.failedMessage = 'The VIP key you entered is invalid or expired.',
    this.watchAdSuccess = '+3 days VIP added 🎉',
    this.watchAdFailed = 'No rewarded ad available. Please try again later.',
    this.revoke = 'Revoke',
    this.revokeConfirm = 'Remove this VIP entry?',
    this.revokeAll = 'Revoke all',
    this.revokeAllConfirm = 'Remove all active VIP entries?',
    this.cancel = 'Cancel',
    this.delete = 'Delete',
    this.error = 'Something went wrong.',
    this.statusActive = 'VIP ACTIVE',
    this.statusInactive = 'VIP NOT ACTIVE',
    this.statusInactiveTagline = 'Enjoy an ad-free experience with VIP.',
    this.redeemTitle = 'Enter VIP key',
    this.redeemSubtitle = 'Enter your activation key to unlock the ad-free '
        'experience.',
    this.keyHint = 'Your activation key',
    this.activateButton = 'Activate',
    this.noEntries = 'No active VIP entries.',
    this.firstInstall = 'Welcome gift',
    this.legacyDevice = 'Legacy device',
    this.rewardEntry = 'Watch-ad reward',
    this.watchAdTitle = 'Watch ad → free VIP',
    this.watchAdBadgeFree = 'FREE',
    this.watchAdSubtitle = 'Watch one short ad to get 3 days of VIP for free.',
    this.watchAdButton = 'Watch ad',
    this.buyTitle = 'Buy VIP',
    this.buy30d = '30 days',
    this.buy90d = '90 days',
    this.buy1y = '1 year',
    this.buyLifetime = 'Lifetime',
    this.buyLocked = 'SOON',
    this.restoreLocked = 'Restore purchase (coming soon)',
    this.privacyPolicy = 'Privacy Policy',
    this.expiresAt = _defaultExpiresAt,
    this.remainingDays = _defaultRemainingDays,
    this.remainingHours = _defaultRemainingHours,
    this.remainingExtraHours = _defaultRemainingExtraHours,
    this.activeEntries = _defaultActiveEntries,
  });

  static String _defaultExpiresAt(String date) => 'Expires: $date';
  static String _defaultRemainingDays(int days) => '$days days left';
  static String _defaultRemainingHours(int hours) => '$hours hours left';
  static String _defaultRemainingExtraHours(int hours) => '$hours h';
  static String _defaultActiveEntries(int count) => 'Active VIP ($count)';

  final String sdkNotReady,
      enterKeyFirst,
      successTitle,
      keyAlreadyUsed,
      failedMessage,
      watchAdSuccess,
      watchAdFailed,
      revoke,
      revokeConfirm,
      revokeAll,
      revokeAllConfirm,
      cancel,
      delete,
      error,
      statusActive,
      statusInactive,
      statusInactiveTagline,
      redeemTitle,
      redeemSubtitle,
      keyHint,
      activateButton,
      noEntries,
      firstInstall,
      legacyDevice,
      rewardEntry,
      watchAdTitle,
      watchAdBadgeFree,
      watchAdSubtitle,
      watchAdButton,
      buyTitle,
      buy30d,
      buy90d,
      buy1y,
      buyLifetime,
      buyLocked,
      restoreLocked,
      privacyPolicy;

  // Parameterized strings — pass closures (e.g. from your i18n) to localize.
  final String Function(String date) expiresAt;
  final String Function(int days) remainingDays;
  final String Function(int hours) remainingHours;
  final String Function(int hours) remainingExtraHours;
  final String Function(int count) activeEntries;
}

/// A full, self-contained VIP redeem screen (T18). Host apps and the SDK example
/// share this exact widget so the experience is identical everywhere. Redeems
/// **offline signed keys** ([VipManager.redeemSignedKey]), supports the watch-ad
/// extend flow, lists active entries, and shows a (placeholder) buy section.
///
/// Provide [publicKeyBase64] (the Ed25519 public key that verifies your keys),
/// optional localized [strings], and an [onPrivacyPolicyTap] to open your policy
/// URL (kept as a callback so the SDK needs no url_launcher dependency).
class VipRedeemScreen extends StatefulWidget {
  const VipRedeemScreen({
    super.key,
    required this.publicKeyBase64,
    this.strings = const VipRedeemStrings(),
    this.rewardWatchAdDuration = const Duration(days: 3),
    this.onPrivacyPolicyTap,
    this.firstInstallKey = '__FIRST_INSTALL__',
    this.rewardKey = 'REWARDED_VIP',
    this.rewardKeyPrefix = 'REWARDED_',
    this.legacyKeyPrefix = 'LEGACY_',
    this.showBuySection = true,
  });

  final String publicKeyBase64;
  final VipRedeemStrings strings;
  final Duration rewardWatchAdDuration;
  final VoidCallback? onPrivacyPolicyTap;
  final String firstInstallKey;
  final String rewardKey;
  final String rewardKeyPrefix;
  final String legacyKeyPrefix;
  final bool showBuySection;

  @override
  State<VipRedeemScreen> createState() => _VipRedeemScreenState();
}

class _VipRedeemScreenState extends State<VipRedeemScreen>
    with TickerProviderStateMixin {
  final TextEditingController _keyController = TextEditingController();
  final FocusNode _keyFocus = FocusNode();
  final ValueNotifier<bool> _isProcessing = ValueNotifier<bool>(false);
  final ValueNotifier<List<VipEntry>> _entriesNotifier =
      ValueNotifier<List<VipEntry>>(const []);

  AnimationController? _shimmerController;
  AnimationController? _entryController;
  AnimationController? _pulseController;
  ConfettiController? _confettiController;
  StreamSubscription<bool>? _activeSubscription;
  Timer? _tickTimer;
  Timer? _countdownTimer;
  final ValueNotifier<DateTime> _now = ValueNotifier(DateTime.now());

  VipRedeemStrings get _s => widget.strings;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _confettiController =
        ConfettiController(duration: const Duration(milliseconds: 1200));

    _refreshEntries();
    final vip = AdManager().vip;
    if (vip != null) {
      _activeSubscription = vip.activeStream.listen((_) => _refreshEntries());
    }
    _tickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _refreshEntries();
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _now.value = DateTime.now();
    });
  }

  @override
  void dispose() {
    _activeSubscription?.cancel();
    _tickTimer?.cancel();
    _countdownTimer?.cancel();
    _shimmerController?.dispose();
    _entryController?.dispose();
    _pulseController?.dispose();
    _confettiController?.dispose();
    _keyController.dispose();
    _keyFocus.dispose();
    _isProcessing.dispose();
    _entriesNotifier.dispose();
    _now.dispose();
    super.dispose();
  }

  void _refreshEntries() {
    if (!mounted) return;
    final vip = AdManager().vip;
    _entriesNotifier.value =
        vip == null ? const [] : List<VipEntry>.from(vip.entries);
  }

  Future<void> _onActivate() async {
    FocusScope.of(context).unfocus();
    final raw = _keyController.text;
    if (raw.trim().isEmpty) {
      _showSnack(_s.enterKeyFirst);
      return;
    }
    final vip = AdManager().vip;
    if (vip == null) {
      _showSnack(_s.sdkNotReady);
      return;
    }
    _isProcessing.value = true;
    try {
      final result = await vip.redeemSignedKey(
        raw,
        publicKeyBase64: widget.publicKeyBase64,
        stack: true,
      );
      if (!mounted) return;
      switch (result.status) {
        case VipRedeemStatus.success:
          _keyController.clear();
          unawaited(HapticFeedback.heavyImpact());
          _confettiController?.play();
          _showSnack(_s.successTitle);
          break;
        case VipRedeemStatus.alreadyUsed:
          _showSnack(_s.keyAlreadyUsed);
          break;
        case VipRedeemStatus.invalid:
          _showSnack(_s.failedMessage);
          break;
      }
      _refreshEntries();
    } finally {
      if (mounted) _isProcessing.value = false;
    }
  }

  Future<void> _onWatchAdForVip() async {
    if (_isProcessing.value) return;
    final vip = AdManager().vip;
    if (vip == null) {
      _showSnack(_s.sdkNotReady);
      return;
    }
    _isProcessing.value = true;
    try {
      final rewardCompleter = Completer<bool>();
      AdManager().showRewardedAd(
        bypassVipGuard: true,
        onEarnedReward: (earned) {
          if (!rewardCompleter.isCompleted) rewardCompleter.complete(earned);
        },
      );
      final earned = await rewardCompleter.future;
      if (!mounted) return;
      if (earned) {
        await vip.addVip(
          key: widget.rewardKey,
          duration: widget.rewardWatchAdDuration,
          stack: true,
        );
        if (!mounted) return;
        _confettiController?.play();
        unawaited(HapticFeedback.heavyImpact());
        _showSnack(_s.watchAdSuccess);
        _refreshEntries();
      } else {
        _showSnack(_s.watchAdFailed);
      }
    } finally {
      if (mounted) _isProcessing.value = false;
    }
  }

  Future<void> _onRevoke(VipEntry entry) async {
    final confirmed = await _confirmDialog(_s.revoke, _s.revokeConfirm);
    if (!mounted || !confirmed) return;
    final vip = AdManager().vip;
    if (vip == null) return;
    await vip.revokeVip(entry.key);
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    _refreshEntries();
  }

  Future<void> _onRevokeAll() async {
    final confirmed = await _confirmDialog(_s.revokeAll, _s.revokeAllConfirm);
    if (!mounted || !confirmed) return;
    final vip = AdManager().vip;
    if (vip == null) return;
    await vip.revokeAll();
    if (!mounted) return;
    unawaited(HapticFeedback.heavyImpact());
    _refreshEntries();
  }

  Future<bool> _confirmDialog(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252540),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text(_s.cancel, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(_s.delete),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vip = AdManager().vip;
    if (vip == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _s.sdkNotReady,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 15,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: vip.activeListenable,
        builder: (context, active, _) {
          return ValueListenableBuilder<List<VipEntry>>(
            valueListenable: _entriesNotifier,
            builder: (context, entries, __) {
              final topInset = MediaQuery.of(context).padding.top;
              final primaryEntry = _pickPrimaryActiveEntry(entries);
              return Stack(
                children: [
                  _buildBackdrop(active),
                  ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                        16, topInset + kToolbarHeight + 8, 16, 32),
                    children: [
                      _staggered(0, _buildHeroCard(active, primaryEntry)),
                      const SizedBox(height: 24),
                      _staggered(1, _buildRedeemSection()),
                      const SizedBox(height: 24),
                      _staggered(2, _buildWatchAdSection()),
                      const SizedBox(height: 24),
                      _staggered(3, _buildEntriesSection(entries)),
                      if (widget.showBuySection) ...[
                        const SizedBox(height: 24),
                        _staggered(4, _buildBuyVipSection()),
                      ],
                      if (widget.onPrivacyPolicyTap != null) ...[
                        const SizedBox(height: 24),
                        _staggered(5, _buildFooter()),
                      ],
                    ],
                  ),
                  _buildConfettiOverlay(),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildBackdrop(bool active) {
    final shimmer = _shimmerController;
    if (!active || shimmer == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: shimmer,
      builder: (context, _) => Positioned(
        top: -120,
        right: -120,
        child: Transform.rotate(
          angle: shimmer.value * 2 * math.pi,
          child: Container(
            width: 360,
            height: 360,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                const Color(0xFFFFB200).withValues(alpha: 0.18),
                const Color(0xFFFFB200).withValues(alpha: 0.0),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroCard(bool active, VipEntry? primaryEntry) {
    final expiresAt = primaryEntry?.expiresAt;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.85, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: active
                ? const [
                    Color(0xFFFFD60A),
                    Color(0xFFFFB200),
                    Color(0xFFFF6B00)
                  ]
                : const [Color(0xFF3A3A5E), Color(0xFF252540)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(28),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: const Color(0xFFFFB200).withValues(alpha: 0.45),
                      blurRadius: 32,
                      offset: const Offset(0, 12))
                ]
              : [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 18,
                      offset: const Offset(0, 6))
                ],
        ),
        child: Column(
          children: [
            _buildCrownIcon(active),
            const SizedBox(height: 18),
            Text(
              active ? _s.statusActive : _s.statusInactive,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4),
            ),
            const SizedBox(height: 8),
            Text(
              active && expiresAt != null
                  ? _s.expiresAt(_fmtDateTime(expiresAt))
                  : _s.statusInactiveTagline,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 13.5,
                  height: 1.4),
            ),
            if (active && primaryEntry != null) ...[
              const SizedBox(height: 18),
              _buildRemainingBadge(primaryEntry.expiresAt),
              const SizedBox(height: 14),
              _buildCountdownText(primaryEntry.expiresAt),
              const SizedBox(height: 14),
              _buildProgressBar(primaryEntry),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtCountdown(Duration remaining) {
    if (remaining.isNegative || remaining == Duration.zero) return '0s';
    final d = remaining.inDays;
    final h = remaining.inHours % 24;
    final m = remaining.inMinutes % 60;
    final s = remaining.inSeconds % 60;
    if (d > 0) return '${d}d ${_pad2(h)}h ${_pad2(m)}m ${_pad2(s)}s';
    if (h > 0) return '${_pad2(h)}h ${_pad2(m)}m ${_pad2(s)}s';
    if (m > 0) return '${_pad2(m)}m ${_pad2(s)}s';
    return '${s}s';
  }

  String _pad2(int v) => v.toString().padLeft(2, '0');

  Widget _buildCountdownText(DateTime expiresAt) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _now,
      builder: (context, now, _) => Text(
        _fmtCountdown(expiresAt.difference(now)),
        style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2),
      ),
    );
  }

  Widget _buildProgressBar(VipEntry entry) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _now,
      builder: (context, now, _) {
        final total = entry.expiresAt.difference(entry.grantedAt);
        final elapsed = now.difference(entry.grantedAt);
        final progress = total.inMilliseconds <= 0
            ? 1.0
            : (elapsed.inMilliseconds / total.inMilliseconds)
                .clamp(0.0, 1.0)
                .toDouble();
        return ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 10,
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.95)),
          ),
        );
      },
    );
  }

  VipEntry? _pickPrimaryActiveEntry(List<VipEntry> entries) {
    VipEntry? primary;
    for (final e in entries) {
      if (!e.isActive) continue;
      if (primary == null || e.expiresAt.isAfter(primary.expiresAt)) {
        primary = e;
      }
    }
    return primary;
  }

  Widget _buildConfettiOverlay() {
    final c = _confettiController;
    if (c == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: ConfettiWidget(
        confettiController: c,
        blastDirectionality: BlastDirectionality.explosive,
        maxBlastForce: 18,
        minBlastForce: 8,
        emissionFrequency: 0.04,
        numberOfParticles: 18,
        gravity: 0.4,
        shouldLoop: false,
        colors: const [
          Color(0xFFFFD60A),
          Color(0xFFFFB200),
          Color(0xFFFF6B00),
          Colors.white
        ],
      ),
    );
  }

  Widget _buildCrownIcon(bool active) {
    final shimmer = _shimmerController;
    if (!active || shimmer == null) {
      return Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.12),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.3), width: 1.5),
        ),
        child:
            const Icon(Icons.workspace_premium, size: 50, color: Colors.white),
      );
    }
    return AnimatedBuilder(
      animation: shimmer,
      builder: (context, _) => SizedBox(
        width: 92,
        height: 92,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(
              angle: shimmer.value * 2 * math.pi,
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: [
                    Colors.white.withValues(alpha: 0.0),
                    Colors.white.withValues(alpha: 0.7),
                    Colors.white.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                    colors: [Color(0xFFFFE066), Color(0xFFFFB200)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 6,
                      offset: const Offset(0, 2))
                ],
              ),
              child: const Icon(Icons.workspace_premium,
                  size: 46, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemainingBadge(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    final days = remaining.inDays;
    final hours = remaining.inHours % 24;
    final label = days > 0
        ? _s.remainingDays(days)
        : _s.remainingHours(remaining.inHours);
    final subLabel =
        days > 0 && hours > 0 ? _s.remainingExtraHours(hours) : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            subLabel == null ? label : '$label · $subLabel',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  Widget _buildRedeemSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.vpn_key_outlined,
                  color: Color(0xFFFFB200), size: 20),
              const SizedBox(width: 8),
              Text(_s.redeemTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          Text(_s.redeemSubtitle,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.35)),
          const SizedBox(height: 16),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _keyController,
            builder: (context, value, _) => TextField(
              controller: _keyController,
              focusNode: _keyFocus,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _onActivate(),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  letterSpacing: 1.6),
              decoration: InputDecoration(
                hintText: _s.keyHint,
                hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    letterSpacing: 1.0),
                filled: true,
                fillColor: Colors.black.withValues(alpha: 0.35),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                prefixIcon: const Icon(Icons.confirmation_number_outlined,
                    color: Color(0xFFFFB200)),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear,
                            color: Colors.white70, size: 20),
                        onPressed: _keyController.clear),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFFFFB200), width: 1.6)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          ValueListenableBuilder<bool>(
            valueListenable: _isProcessing,
            builder: (context, processing, _) =>
                ValueListenableBuilder<TextEditingValue>(
              valueListenable: _keyController,
              builder: (context, value, __) => _buildActivateButton(
                enabled: !processing && value.text.trim().isNotEmpty,
                processing: processing,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivateButton(
      {required bool enabled, required bool processing}) {
    final pulseCtrl = _pulseController;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: AnimatedBuilder(
        animation: pulseCtrl ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) {
          final p = (enabled && !processing && pulseCtrl != null)
              ? pulseCtrl.value
              : 0.0;
          final glowAlpha = enabled ? (0.32 + 0.28 * p) : 0.0;
          final blur = enabled ? (16.0 + 14.0 * p) : 0.0;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: enabled
                    ? const [Color(0xFFFFD60A), Color(0xFFFFB200)]
                    : [
                        Colors.white.withValues(alpha: 0.10),
                        Colors.white.withValues(alpha: 0.04)
                      ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              border: enabled
                  ? null
                  : Border.all(
                      color: Colors.white.withValues(alpha: 0.12), width: 1),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                          color: const Color(0xFFFFB200)
                              .withValues(alpha: glowAlpha),
                          blurRadius: blur,
                          offset: const Offset(0, 6))
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: enabled ? _onActivate : null,
                child: Center(
                  child: processing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.6, color: Colors.black))
                      : Text(
                          _s.activateButton.toUpperCase(),
                          style: TextStyle(
                            color: enabled
                                ? Colors.black
                                : Colors.white.withValues(alpha: 0.4),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.6,
                          ),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEntriesSection(List<VipEntry> entries) {
    final visible = entries.where((e) => e.isActive).toList();
    if (visible.isEmpty) return _buildEmptyEntriesCard();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(_s.activeEntries(visible.length),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
              if (visible.length > 1)
                TextButton.icon(
                  onPressed: _onRevokeAll,
                  icon: const Icon(Icons.delete_sweep_outlined,
                      size: 18, color: Colors.redAccent),
                  label: Text(_s.revokeAll,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
        ),
        for (final e in visible) _buildEntryCard(e),
      ],
    );
  }

  Widget _buildEmptyEntriesCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined,
              color: Colors.white.withValues(alpha: 0.35), size: 42),
          const SizedBox(height: 10),
          Text(_s.noEntries,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildEntryCard(VipEntry entry) {
    final isFirstInstall = entry.key == widget.firstInstallKey;
    final isLegacy = entry.key.startsWith(widget.legacyKeyPrefix);
    final isReward = entry.key.startsWith(widget.rewardKeyPrefix);
    final remaining = entry.remaining;
    final daysLeft = remaining.inDays;
    final hoursLeft = remaining.inHours;

    final IconData icon;
    final String displayName;
    if (isFirstInstall) {
      icon = Icons.celebration_outlined;
      displayName = _s.firstInstall;
    } else if (isLegacy) {
      icon = Icons.devices_other_outlined;
      displayName = _s.legacyDevice;
    } else if (isReward) {
      icon = Icons.play_circle_outline;
      displayName = _s.rewardEntry;
    } else {
      icon = Icons.confirmation_number_outlined;
      displayName = _maskKey(entry.key);
    }

    final remainingLabel = daysLeft > 0
        ? _s.remainingDays(daysLeft)
        : _s.remainingHours(hoursLeft);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFB200).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFFFFB200), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 0.4),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text('$remainingLabel · ${_fmtDateShort(entry.expiresAt)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
            tooltip: _s.revoke,
            onPressed: () => _onRevoke(entry),
          ),
        ],
      ),
    );
  }

  Widget _buildWatchAdSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFFB200).withValues(alpha: 0.18),
            const Color(0xFFFF6B00).withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: const Color(0xFFFFB200).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_outline,
                  color: Color(0xFFFFB200), size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_s.watchAdTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFB200),
                    borderRadius: BorderRadius.circular(999)),
                child: Text(_s.watchAdBadgeFree,
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_s.watchAdSubtitle,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 13,
                  height: 1.4)),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: _isProcessing,
            builder: (context, processing, _) =>
                _buildWatchAdButton(processing: processing),
          ),
        ],
      ),
    );
  }

  Widget _buildWatchAdButton({required bool processing}) {
    final pulseCtrl = _pulseController;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: AnimatedBuilder(
        animation: pulseCtrl ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) {
          final p = (pulseCtrl != null && !processing) ? pulseCtrl.value : 0.0;
          final glowAlpha = processing ? 0.0 : (0.32 + 0.28 * p);
          final blur = processing ? 0.0 : (16.0 + 14.0 * p);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFFFFD60A), Color(0xFFFFB200)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFFFB200).withValues(alpha: glowAlpha),
                    blurRadius: blur,
                    offset: const Offset(0, 6))
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: processing ? null : _onWatchAdForVip,
                child: Center(
                  child: processing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.6, color: Colors.black))
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow_rounded,
                                color: Colors.black, size: 22),
                            const SizedBox(width: 6),
                            Text(_s.watchAdButton.toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.6)),
                          ],
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBuyVipSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shopping_bag_outlined,
                  color: Color(0xFFFFB200), size: 20),
              const SizedBox(width: 8),
              Text(_s.buyTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 14),
          _buildBuyOption(
              icon: Icons.calendar_today_outlined,
              label: _s.buy30d,
              price: '\$0.5'),
          _buildBuyOption(
              icon: Icons.event_outlined, label: _s.buy90d, price: '\$1'),
          _buildBuyOption(
              icon: Icons.event_available_outlined,
              label: _s.buy1y,
              price: '\$2'),
          _buildBuyOption(
              icon: Icons.all_inclusive, label: _s.buyLifetime, price: '\$3'),
          const SizedBox(height: 6),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: null,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.restore,
                        color: Colors.white.withValues(alpha: 0.4), size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_s.restoreLocked,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBuyOption(
      {required IconData icon, required String label, required String price}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFFB200).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon,
                      color: const Color(0xFFFFB200).withValues(alpha: 0.6),
                      size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
                Text(price,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(_s.buyLocked,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Center(
      child: TextButton.icon(
        onPressed: widget.onPrivacyPolicyTap,
        icon: const Icon(Icons.privacy_tip_outlined,
            size: 16, color: Colors.white70),
        label: Text(_s.privacyPolicy,
            style: const TextStyle(
                color: Colors.white70,
                decoration: TextDecoration.underline,
                fontSize: 12.5)),
      ),
    );
  }

  Widget _staggered(int index, Widget child) {
    final ctrl = _entryController;
    if (ctrl == null) return child;
    final start = (index * 0.15).clamp(0.0, 1.0);
    final end = (start + 0.55).clamp(0.0, 1.0);
    final anim = CurvedAnimation(
        parent: ctrl, curve: Interval(start, end, curve: Curves.easeOutCubic));
    return AnimatedBuilder(
      animation: anim,
      builder: (context, c) {
        final t = anim.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 28), child: c),
        );
      },
      child: child,
    );
  }

  String _maskKey(String key) {
    if (key.length <= 3) return key;
    return key.substring(0, 3) + '*' * (key.length - 3);
  }

  String _fmtDateTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    return '$dd/$mm/${dt.year} $h:$m';
  }

  String _fmtDateShort(DateTime dt) {
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    return '$dd/$mm/${dt.year}';
  }
}
