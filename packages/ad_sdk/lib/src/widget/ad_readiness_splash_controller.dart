import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../core/ad_manager.dart';
import '../core/event_bus.dart';
import '../utils/safe_logger.dart';
import 'ad_loading_dialog.dart';

/// T94 — officialized version of the splash-screen orchestration the README
/// documents by hand (subscribe-before-init, hard-cap timer,
/// markSplashActive/Inactive, incrementSplashCount, buffered App Open with
/// `bypassSafety: true`). Handles every ordering/race concern; your own
/// splash screen still owns 100% of the UI — this only tells it WHEN it's
/// safe to navigate away, via [onReady].
///
/// ```dart
/// class _SplashScreenState extends State<SplashScreen> {
///   final _controller = AdReadinessSplashController(config: myAdConfig);
///
///   @override
///   void initState() {
///     super.initState();
///     _controller.start(context, onReady: _goHome);
///   }
///
///   @override
///   void dispose() {
///     _controller.dispose();
///     super.dispose();
///   }
///
///   void _goHome() => Navigator.of(context)
///       .pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
///
///   @override
///   Widget build(BuildContext context) => const Scaffold(body: MySplashUi());
/// }
/// ```
///
/// This is a convenience wrapper, not a replacement for the manual flow —
/// if your splash needs steps this doesn't cover (ATT prompt timing, a
/// custom consent flow before `initialize()`, ...), write it by hand
/// following the README's "Integrate the SDK" section instead.
class AdReadinessSplashController {
  AdReadinessSplashController({
    required this.config,
    this.hardCapDuration = const Duration(seconds: 8),
    this.showAppOpenOnReady = true,
  });

  static const String _tag = 'AdReadinessSplashController';

  /// Passed straight through to [AdManager.initialize].
  final AdConfig config;

  /// Force-navigates via [onReady] if SDK init + (optionally) the splash App
  /// Open ad haven't finished by this deadline. Keep in sync with your own
  /// splash timeout expectations.
  final Duration hardCapDuration;

  /// When `true` (default), a successful init attempts to show a buffered
  /// App Open ad (`bypassSafety: true`) before calling [onReady]. Set
  /// `false` to call [onReady] as soon as init completes, with no ad.
  final bool showAppOpenOnReady;

  Timer? _hardCap;
  bool _navigated = false;
  bool _started = false;
  BuildContext? _context;
  VoidCallback? _onReady;
  void Function(BoolEvent)? _busListener;

  /// Starts the orchestration. [onReady] fires exactly once — after the
  /// splash App Open ad is dismissed/skipped/failed, immediately once init
  /// completes if [showAppOpenOnReady] is `false`, or if [hardCapDuration]
  /// elapses first. Safe to call only once per controller instance — a
  /// second call is a caller bug (create a new controller per splash
  /// instead) and is rejected outright, logged, and otherwise ignored; see
  /// [_started].
  void start(
    BuildContext context, {
    required VoidCallback onReady,
    void Function(bool success, String gaid)? onInitComplete,
  }) {
    // T134 — a second start() call on the SAME instance used to silently
    // overwrite _context/_onReady and re-increment splash count
    // unconditionally (both happened on every ordinary sequential
    // double-call, not just a race) — and, in the narrower window where
    // the FIRST call's own flow (a Timer or the event bus) fired before
    // reaching the old `countInitSplashScreen > 1` short-circuit further
    // along, could also restart the hard-cap timer and attach a second
    // SimpleEventBus listener. This guard is deliberately checked and set
    // BEFORE any of those side effects (not just the narrow-window ones),
    // and independent of `countInitSplashScreen` (that check exists for a
    // DIFFERENT scenario — a previous splash INSTANCE still on the stack —
    // not calling `start()` twice on THIS instance).
    if (_started) {
      SafeLogger.w(_tag,
          'start() called more than once on the same AdReadinessSplashController instance — ignoring. Create a new controller per splash screen instead of reusing one.');
      return;
    }
    _started = true;

    _context = context;
    _onReady = onReady;

    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // Re-entered while a previous splash instance is still on the stack
    // (rare race, e.g. the user reopened the app) — short-circuit straight
    // to onReady instead of running the whole flow twice.
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goReady());
      return;
    }

    _hardCap = Timer(hardCapDuration, _goReady);

    // Subscribe before calling initialize(). SimpleEventBus does replay its
    // last-fired event to late subscribers, but registering first keeps the
    // ordering simple to reason about regardless.
    _busListener = (BoolEvent e) {
      if (e.value && showAppOpenOnReady) {
        _showSplashAppOpen();
      } else {
        _goReady();
      }
    };
    SimpleEventBus().listen(_busListener!);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: config,
        onComplete: onInitComplete ?? (success, gaid) {},
      );
    });
  }

  void _showSplashAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated) return;
      final ctx = _context;
      if (!loaded || ctx == null || !ctx.mounted) {
        _goReady();
        return;
      }
      AdLoadingDialog.showAdBuffer(ctx, onComplete: () {
        // Round-31 audit fix (MAJOR) — `onAdLoaded`'s own `_navigated` check
        // above only covers the window before this buffer dialog starts.
        // The hard-cap timer isn't cancelled until just below (deliberately
        // late, per this method's own ordering comment), so it can still
        // fire `_goReady()` — navigating away — WHILE the buffer's own
        // delay is still running. The old splash route can still be
        // `ctx.mounted` during its exit transition, so that check alone
        // isn't enough to stop this callback from calling showAppOpenAd()
        // on a screen the host has already navigated past "ready".
        if (_navigated || !ctx.mounted) {
          _goReady();
          return;
        }
        // Cancel the hard cap BEFORE showAppOpenAd — the ad now owns the
        // splash screen, so nothing should race-fire markSplashInactive.
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          bypassSafety: true,
          onAdDismiss: (_) => _goReady(),
        );
      });
    });
  }

  void _goReady() {
    if (_navigated) return;
    _navigated = true;
    _hardCap?.cancel();
    _hardCap = null;
    AdManager().markSplashInactive();
    _onReady?.call();
  }

  /// Call from your splash `State`'s own `dispose()`. Safe even if
  /// [onReady] already fired — [AdManager.markSplashInactive] is itself
  /// idempotent. If the widget is disposed WITHOUT [onReady] ever firing
  /// (e.g. the app was backgrounded and killed mid-splash), this still
  /// clears the SDK's splash-active state and its own internal budget
  /// timer, rather than leaving them stuck.
  ///
  /// Round-26 audit (MAJOR, claude) — this used to leave [_navigated]
  /// `false`, so a late `loadAppOpenAd`/`AdLoadingDialog` callback firing
  /// after the host had already disposed this controller (app backgrounded
  /// and killed mid-splash, or the splash route popped) still ran `_goReady`
  /// → `onReady`, i.e. a host navigation callback, against a `BuildContext`
  /// that had already deactivated — "Looking up a deactivated widget's
  /// ancestor is unsafe." Marking navigated here makes every check above
  /// (`if (_navigated) return;`) short-circuit any callback that arrives
  /// after dispose, exactly like it already does for one that arrives after
  /// a normal `onReady` fire.
  void dispose() {
    _navigated = true;
    _onReady = null;
    _context = null;
    _hardCap?.cancel();
    _hardCap = null;
    final listener = _busListener;
    if (listener != null) SimpleEventBus().remove(listener);
    AdManager().markSplashInactive();
  }
}
