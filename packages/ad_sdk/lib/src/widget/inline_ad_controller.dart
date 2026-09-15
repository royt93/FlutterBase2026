import 'package:flutter/foundation.dart';

/// T201 — [InlineAdController]'s attach status. Independent of the
/// underlying ad's own load state (loading/ready/no-fill) — this only
/// tracks whether a live widget instance is currently wired up to run
/// commands against, and whether the controller itself currently wants
/// that instance paused.
enum InlineAdControllerStatus {
  /// No `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` is currently
  /// mounted with this controller. [InlineAdController.refresh]/`pause`/
  /// `resume` calls made in this state are remembered (see the class doc
  /// comment) rather than dropped.
  detached,

  /// Attached and not paused — the widget runs its normal automatic
  /// lifecycle (route-aware pause/resume, `VisibilityDetector`, consent
  /// gating) exactly as it would with no controller at all.
  active,

  /// Attached and paused via [InlineAdController.pause] — the widget has
  /// torn down (Banner/MREC) or never loaded (Native) its live ad instance,
  /// through the exact same gate every other pause path in that widget
  /// already goes through.
  paused,
}

/// T201 — implemented privately by `_BannerAdWidgetState`/
/// `_MrecAdWidgetState`/`_NativeAdWidgetState`. Not part of the package's
/// public API — a host never implements this itself, only
/// [InlineAdController].
@internal
abstract class InlineAdControllerTarget {
  /// Re-requests an ad for this one slot, through the exact same
  /// consent/VIP/connectivity/cooldown gate its normal automatic reload
  /// paths already use — a refresh request during cooldown is silently
  /// skipped, never force-loaded.
  void controllerRefresh();

  /// Mirrors the widget's existing automatic pause/resume (Banner/MREC:
  /// the same path `VisibilityDetector`/route-away already uses; Native:
  /// dispose-and-reload, since it has no auto-refresh ticker to pause).
  void controllerSetPaused(bool paused);
}

/// T201 — imperative lifecycle handle for ONE inline ad widget instance
/// (`BannerAdWidget`, `MrecAdWidget`, or `NativeAdWidget`'s `controller`
/// param), so a host can `refresh()`/`pause()`/`resume()` a single
/// placement without reaching for `AdManager`'s singleton methods (which
/// have no notion of "this one slot" and risk touching every other
/// placement using the same format) or juggling its own `active: bool`
/// state variable and forcing a rebuild every time it changes.
///
/// Every command only ever calls into the widget's OWN existing gated
/// methods (`_initBanner`/`_initMrec`/`_initNative`, `_applyVisibility`,
/// `disposeBannerInstance`/... ) — this never bypasses consent, VIP,
/// connectivity, or cooldown policy; a command that policy would refuse
/// today is silently skipped, exactly as it already would be if the same
/// automatic path triggered it.
///
/// A command issued before any widget has attached (or after the attached
/// widget was disposed and a new one hasn't mounted yet) is not lost:
/// [pause]/[resume] just update this controller's own desired-paused
/// state, applied to the next widget that attaches; [refresh] is
/// remembered as one pending refresh, run once on the next attach (extra
/// calls before that first attach coalesce into that same one refresh,
/// not a queue that replays every single call).
///
/// One controller instance attaches to at most one widget at a time —
/// sharing it across two simultaneously-mounted inline ad widgets is a
/// usage error (an assertion fires in debug).
///
/// `dispose()` is idempotent: calling it more than once (or on a
/// controller that never attached to anything) is always safe.
class InlineAdController extends ChangeNotifier {
  InlineAdControllerTarget? _target;
  bool _disposed = false;
  bool _paused = false;
  bool _pendingRefresh = false;

  /// Whether a widget is currently mounted with this controller.
  bool get isAttached => _target != null;

  /// Current attach/pause status — see [InlineAdControllerStatus].
  InlineAdControllerStatus get status {
    if (_target == null) return InlineAdControllerStatus.detached;
    return _paused
        ? InlineAdControllerStatus.paused
        : InlineAdControllerStatus.active;
  }

  /// Re-requests an ad for the attached widget (no-op, remembered for the
  /// next attach, if nothing is attached right now). Skipped by the
  /// widget itself if policy (cooldown/consent/VIP/connectivity) refuses
  /// it — this never forces a load past those gates.
  void refresh() {
    if (_disposed) return;
    final target = _target;
    if (target == null) {
      _pendingRefresh = true;
      return;
    }
    target.controllerRefresh();
  }

  /// Pauses the attached widget (or the next one to attach). Idempotent —
  /// calling it while already paused does nothing.
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _target?.controllerSetPaused(true);
    notifyListeners();
  }

  /// Resumes the attached widget (or clears a pending pause for the next
  /// one to attach). Idempotent — calling it while not paused does
  /// nothing.
  void resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _target?.controllerSetPaused(false);
    notifyListeners();
  }

  /// Called by the widget's `State.initState`/`didUpdateWidget` — not a
  /// public API.
  @internal
  void attach(InlineAdControllerTarget target) {
    if (_disposed) return;
    assert(
      _target == null,
      'InlineAdController is already attached to another inline ad '
      'widget — one controller can only drive one mounted '
      'BannerAdWidget/MrecAdWidget/NativeAdWidget at a time.',
    );
    _target = target;
    if (_paused) target.controllerSetPaused(true);
    if (_pendingRefresh) {
      _pendingRefresh = false;
      target.controllerRefresh();
    }
    notifyListeners();
  }

  /// Called by the widget's `State.dispose`/`didUpdateWidget` — not a
  /// public API. A no-op if `target` isn't the currently-attached one
  /// (e.g. a stale call after the controller already moved to a new
  /// widget instance).
  @internal
  void detach(InlineAdControllerTarget target) {
    if (!identical(_target, target)) return;
    _target = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _target = null;
    super.dispose();
  }
}
