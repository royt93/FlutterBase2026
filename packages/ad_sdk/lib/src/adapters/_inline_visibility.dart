import 'package:flutter/foundation.dart';

import '../core/ad_provider_adapter.dart';

/// Why an inline surface (banner / MREC) is currently blanked.
///
/// Round-26 QC (reviewer A, MINOR) — the first cut of the App Open fix stored a
/// one-time snapshot: the set of surfaces that were visible when the fullscreen
/// ad went up. That models "what I hid", not "who wants it hidden", and the two
/// stop agreeing the moment a second owner appears mid-ad:
///
/// * App Open blanks a banner and remembers it;
/// * the app is backgrounded while the ad is still up, so `onAppPaused` also
///   wants it blanked (and writes `false` over a `false`, so nothing notices);
/// * the App Open is dismissed, the snapshot says "I hid this one", and the
///   banner is switched back on — on a backgrounded, or route-paused, surface.
///
/// Reviewer A reproduced exactly that transition against the real `AdMobAdapter`.
/// Ownership is counted now: a surface is visible only when **nobody** is
/// holding it down.
enum InlineHideReason {
  /// A fullscreen ad (App Open) is on screen over it.
  fullscreen,

  /// The app is in the background.
  background,

  /// Another route sits on top of the one carrying this surface.
  ///
  /// Round-30 QC (reviewer A) — this used to be a *condition* read inside
  /// `onAppResumed` (`!bannerRoutePaused(key)`) rather than an owner. That is
  /// the shape every finding in this area has had: a condition cannot be
  /// released by name, so whoever writes the flag last wins.
  routePaused,

  /// The surface was blanked by the background owner, came back to the
  /// foreground with no ad, and is waiting on a reload to fill.
  ///
  /// Round-28 QC (both reviewers, MAJOR) — `onAppPaused` takes the background
  /// hold on every key (its guard is global, not per-key), but `onAppResumed`
  /// only released it for keys that still had an ad object. A key whose load
  /// had failed took the reload branch instead and kept the hold forever, so
  /// when its retry finally filled, the fill rendered blank: a banner AdMob
  /// billed a request for, showing nothing. This owner exists so the reload
  /// branch can keep the surface blank *for its own reason* — released by the
  /// fill — instead of squatting on the background owner's hold.
  pendingFill,
}

/// Tracks which owners want each inline surface blanked, and derives
/// `visible` from that rather than from a snapshot.
///
/// Deliberately NOT exported: this is adapter bookkeeping, and both shipped
/// adapters hold one. Every write goes through here so the answer stays one
/// question — "does anyone still want this hidden?" — instead of three call
/// sites each guessing.
class InlineVisibilityOwners {
  /// Which notifier this instance governs. Defaults to `visible`, the AdMob
  /// render flag.
  ///
  /// Round-30 QC (reviewer A, MAJOR) — AppLovin needs the identical bookkeeping
  /// for `autoRefreshEnabled`, because `visible` is an AdMob-only flag that
  /// `_buildAppLovin` never reads. Round 29 moved auto-refresh but wrote it
  /// directly, so `setInlineAdsHidden(false)` overwrote the pause
  /// `onAppPaused()` still owned and restarted a MAX banner refreshing while
  /// the app was in the background. Two flags, one set of rules.
  InlineVisibilityOwners(
      [ValueNotifier<bool> Function(BannerListenables)? flag])
      : _flag = flag ?? _visibleFlag;

  static ValueNotifier<bool> _visibleFlag(BannerListenables l) => l.visible;

  final ValueNotifier<bool> Function(BannerListenables) _flag;

  final Map<BannerListenables, Set<InlineHideReason>> _held = {};

  /// Blank [l] on behalf of [reason].
  ///
  /// A surface that is already invisible and that nobody here is holding was
  /// hidden by something outside this bookkeeping (a route pause, a host
  /// widget). Ownership is deliberately not claimed over it: claiming would
  /// mean revealing it later on someone else's behalf.
  void hide(BannerListenables l, InlineHideReason reason) {
    try {
      final reasons = _held.putIfAbsent(l, () => <InlineHideReason>{});
      if (reasons.isEmpty && !_flag(l).value) {
        _held.remove(l);
        return;
      }
      reasons.add(reason);
      _flag(l).value = false;
    } catch (_) {
      // The owning widget unmounted and disposed its notifiers between the map
      // read and the write. Nothing to hide, nothing to restore.
      _held.remove(l);
    }
  }

  /// Release [reason]'s hold on [l]. The surface comes back only once every
  /// other owner has let go too.
  void show(BannerListenables l, InlineHideReason reason) {
    final reasons = _held[l];
    if (reasons == null || !reasons.remove(reason)) return;
    if (reasons.isNotEmpty) return;
    _held.remove(l);
    try {
      _flag(l).value = true;
    } catch (_) {
      // Same race, other direction — the widget is gone, so is its banner.
    }
  }

  /// True when some owner still wants [l] blanked.
  ///
  /// A freshly loaded ad calls this before making itself visible: an ad that
  /// finishes loading while an App Open is on screen must not draw over it.
  bool isHeld(BannerListenables l) => _held[l]?.isNotEmpty ?? false;

  /// Make [l] visible unless an owner is still holding it down.
  void revealUnlessHeld(BannerListenables l) {
    if (isHeld(l)) return;
    try {
      _flag(l).value = true;
    } catch (_) {
      // Widget gone.
    }
  }

  /// Drop every hold on [l] without touching the flag — for a surface being
  /// destroyed and recreated, where no owner's claim survives the swap.
  void forget(BannerListenables l) => _held.remove(l);

  /// Everything this instance was holding, released without touching the
  /// listenables — for a teardown that resets them itself.
  void forgetAll() => _held.clear();

  /// Every surface [reason] is currently holding down.
  Iterable<BannerListenables> heldBy(InlineHideReason reason) =>
      _held.entries.where((e) => e.value.contains(reason)).map((e) => e.key);
}
