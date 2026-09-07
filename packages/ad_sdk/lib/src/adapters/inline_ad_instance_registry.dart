import 'package:flutter/widgets.dart';

import '../core/ad_provider_adapter.dart' show BannerListenables;
import '../state/ad_slot.dart';

/// T114 — shared per-key bookkeeping for banner/MREC/native inline ad
/// instances (one [AdSlot] + one [BannerListenables] per widget instance,
/// keyed by an opaque `Object` the widget owns). Extracted because
/// `AdMobAdapter`/`AppLovinAdapter` each hand-rolled an almost identical
/// copy of this per format — 3 formats x 2 adapters = 6 near-duplicate
/// blocks — exactly the kind of divergence that let T104 (a tombstone
/// leak) and T105 (a missing click guard) exist: a fix applied to one
/// adapter's copy was easy to forget in the other's.
///
/// Deliberately does NOT own the actual load()/callback control flow. Each
/// adapter keeps its own load method and its own `isCurrent` guard inside
/// async ad-network callbacks (`onAdLoaded`/`onAdFailedToLoad`/...) —
/// those are format- and provider-specific and have been independently
/// tuned across 26+ audit rounds (see admob_adapter.dart's B-2/M4/T105
/// comments). Collapsing THAT into a shared abstraction would risk
/// silently dropping one of those hard-won fixes; this class only
/// replaces the map bookkeeping + "already disposed" sentinel pattern
/// underneath it.
class InlineAdInstanceRegistry {
  InlineAdInstanceRegistry(this._slotType);

  final AdSlotType _slotType;

  final Map<Object, AdSlot> _slotsByKey = {};
  final Map<Object, BannerListenables> _listenablesByKey = {};

  bool _disposed = false;
  AdSlot? _disposedSlot;
  BannerListenables? _disposedListenables;

  /// Read-only view of every currently-owned slot — for a resume-scan
  /// loop that needs to touch every live instance of this format.
  Iterable<AdSlot> get slots => _slotsByKey.values;

  /// Read-only view of every currently-owned [BannerListenables] — for an
  /// adapter's own `dispose()` to reset every live instance's VALUES (not
  /// dispose them) as its own separate step from the per-key teardown
  /// loop over [allKeys]/[removeKey].
  Iterable<BannerListenables> get listenablesList => _listenablesByKey.values;

  /// Read-only view of every key that currently owns a [BannerListenables]
  /// — narrower than [allKeys] (which also includes slot-only keys) for a
  /// caller that specifically needs "every key with a listenables to look
  /// up", e.g. a resume scan retrying every known instance in error state.
  Iterable<Object> get listenablesKeys => _listenablesByKey.keys;

  /// `null` if [key] has no owned [BannerListenables] (was never created,
  /// or already [removeKey]'d).
  BannerListenables? listenablesByKey(Object key) => _listenablesByKey[key];

  /// Union of both maps' keys. A key can exist in one map without the
  /// other — a caller that only ever asked for [listenablesFor] (never
  /// [slotFor]) for a given key, or vice versa, still needs that key
  /// counted when snapshotting for a full teardown loop.
  Set<Object> get allKeys => {..._slotsByKey.keys, ..._listenablesByKey.keys};

  /// Read-only view of every key that currently owns an [AdSlot] —
  /// narrower than [allKeys], for a caller that specifically needs
  /// "every key with a slot to check", e.g. marking every still-loading
  /// slot failed after a batch load error with no per-key correlation id.
  Iterable<Object> get slotKeys => _slotsByKey.keys;

  /// `null` if [key] has no owned [AdSlot] (was never created, or already
  /// [removeKey]'d) — unlike [slotFor], never creates one.
  AdSlot? slotByKey(Object key) => _slotsByKey[key];

  AdSlot slotFor(Object key) {
    if (_disposed) {
      return _disposedSlot ??= (AdSlot(type: _slotType)..dispose());
    }
    return _slotsByKey.putIfAbsent(key, () => AdSlot(type: _slotType));
  }

  /// [onCreated] lets a caller run its own extra first-time setup (e.g.
  /// inheriting an active fullscreen/background hold) exactly once, right
  /// after this key's [BannerListenables] is created — without this class
  /// needing to know what that setup is.
  BannerListenables listenablesFor(
    Object key, {
    void Function(BannerListenables)? onCreated,
  }) {
    if (_disposed) {
      return _disposedListenables ??= (_freshListenables()..dispose());
    }
    final existing = _listenablesByKey[key];
    if (existing != null) return existing;
    final created = _freshListenables();
    _listenablesByKey[key] = created;
    onCreated?.call(created);
    return created;
  }

  static BannerListenables _freshListenables() => BannerListenables(
        isLoaded: ValueNotifier<bool>(false),
        hasError: ValueNotifier<bool>(false),
        adSize: ValueNotifier<Size?>(null),
        autoRefreshEnabled: ValueNotifier<bool>(true),
        visible: ValueNotifier<bool>(true),
      );

  /// "Is this still the load I started?" — the identity-check guard every
  /// async ad-network callback in both adapters uses to detect a widget
  /// disposed mid-load (see admob_adapter.dart's B-2/M4 comments for why
  /// this, not a permanent tombstone set, is the correct check — the key
  /// IS legitimately reused across a dispose+re-init of the same widget).
  bool isCurrent(Object key, AdSlot slot) => identical(_slotsByKey[key], slot);

  /// Drops this key's slot (disposing it) and listenables. Returns the
  /// removed [BannerListenables] UNDISPOSED — mirrors
  /// `disposeBannerInstance`'s real order today: a caller often needs to
  /// run one more step on the still-live object first (e.g.
  /// `_inlineVisibility.forget(gone)`) before disposing it itself.
  /// `null` if [key] wasn't owned.
  BannerListenables? removeKey(Object key) {
    _slotsByKey.remove(key)?.dispose();
    return _listenablesByKey.remove(key);
  }

  /// Marks every FUTURE [slotFor]/[listenablesFor] call as "already
  /// disposed" (returns a shared, already-disposed sentinel instead of
  /// creating a new live instance). Does NOT retroactively dispose any
  /// already-live key — [slots]/[listenablesList]/[allKeys]/[removeKey]
  /// keep working on whatever is currently owned regardless of this flag,
  /// so a teardown loop can still run right after this call.
  ///
  /// T114 round-1 review (BLOCKER) — call this FIRST, synchronously, at
  /// the very top of an adapter's `dispose()` (same moment as its own
  /// `_xDisposed = true` flag, if it has a separate one for other state
  /// like AppLovin's adViewId map) — NOT after the teardown loop. An
  /// adapter's `dispose()` often `await`s native SDK calls (e.g.
  /// destroying a platform view) before ever reaching that loop; a stale
  /// ad-network callback resuming during that gap must see the disposed
  /// sentinel immediately, or it mutates a real slot/listenables object
  /// moments before the teardown loop below would have disposed it anyway
  /// — silently reopening the exact race the disposed-flag pattern exists
  /// to close in the first place.
  void markDisposed() {
    _disposed = true;
  }
}
