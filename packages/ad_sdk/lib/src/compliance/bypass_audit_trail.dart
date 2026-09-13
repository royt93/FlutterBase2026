import 'dart:async';
import 'dart:convert';

import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import 'compliance_signing.dart';

/// T128 — one record of a safety-layer "back door" actually being exercised.
class BypassAuditEntry {
  const BypassAuditEntry({
    required this.timestampMs,
    required this.kind,
    required this.callSiteTag,
    required this.type,
  });

  /// `DateTime.now().millisecondsSinceEpoch` when the bypass was exercised.
  final int timestampMs;

  /// Which back door: `'bypassSafety'` (splash App Open) or
  /// `'bypassVipGuard'` (VIP watching a rewarded ad to extend their window).
  final String kind;

  /// Free-text tag the HOST passed in at the call site (e.g.
  /// `'splash_app_open'`, `'vip_extend_screen'`) — untrusted, human-supplied
  /// context for a later audit, not verified against anything.
  final String callSiteTag;

  /// `AdSlotType.name` this bypass applied to.
  final String type;

  Map<String, dynamic> toJson() => {
        'timestampMs': timestampMs,
        'kind': kind,
        'callSiteTag': callSiteTag,
        'type': type,
      };

  factory BypassAuditEntry.fromJson(Map<String, dynamic> json) =>
      BypassAuditEntry(
        timestampMs: json['timestampMs'] as int,
        kind: json['kind'] as String,
        callSiteTag: json['callSiteTag'] as String,
        type: json['type'] as String,
      );
}

/// T128 — flagship proof-of-compliance: a bounded, in-memory ring buffer of
/// every time a legitimate safety-layer "back door" (`bypassSafety`,
/// `bypassVipGuard`) was actually exercised, exportable as an Ed25519-signed
/// bundle via [signBypassAuditTrail].
///
/// This is evidence, not enforcement — it doesn't change whether a bypass is
/// allowed (that's still each call site's own documented contract, e.g.
/// "splash App Open only"). It answers a DIFFERENT question after the fact:
/// "can we show these back doors were only ever exercised at the call sites
/// we shipped, not patched in somewhere else to farm impressions?".
///
/// Always on (like `AdEventLog`) — recording a bypass is cheap and the whole
/// point is that a host cannot selectively turn off the one signal that
/// would catch misuse.
///
/// T155 — persisted via [AdPreferences], same debounced-write pattern as
/// `AdEventLog`. Before this fix the ring buffer lived in RAM only: a killed
/// process (routine on mobile) silently erased every prior bypass, leaving
/// only the current cold start's own — worthless as "flagship
/// proof-of-compliance" if a real dispute needed history older than the
/// app's current run. [AdManager] calls [attach] once [AdPreferences]
/// becomes available (asynchronously, during `initialize()`) — this class
/// is constructed synchronously at field-declaration time (it must survive
/// even a `destroy()`+re-initialize() cycle, see the field's own doc
/// comment), before any storage handle exists, so persistence is opt-in via
/// [attach] rather than a constructor parameter.
class BypassAuditTrail {
  BypassAuditTrail({this.maxEntries = 200}) {
    // T197 — a real runtime check, not just `assert` (compiled out of
    // release builds). Worse than the other opt-in monitors' matching
    // check: an unvalidated NEGATIVE maxEntries doesn't just make this
    // trail silently useless — [record]'s
    // `removeRange(0, _entries.length - maxEntries)` computes an END
    // index LARGER than the list's own length (subtracting a negative
    // adds), which throws a RangeError the very first time the ring
    // buffer would trim — a real crash in production, not just a
    // mistuned monitor.
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
  }

  static const String _tag = 'BypassAuditTrail';

  /// Ring buffer cap — oldest entries drop first. 200 is generous for a
  /// signal that should fire rarely (splash-once-per-cold-start, VIP-extend
  /// on demand), not a high-frequency counter.
  final int maxEntries;

  final List<BypassAuditEntry> _entries = [];

  AdPreferences? _prefs;

  /// Chains every persist after the previous one, mirroring `AdEventLog`'s
  /// `_persistChain` — otherwise concurrent writes could finish out of
  /// order and leave a stale snapshot on disk.
  Future<void> _persistChain = Future.value();

  static const Duration _debounceWindow = Duration(seconds: 1);
  Timer? _debounceTimer;

  /// Newest-last, same order as [record] was called.
  List<BypassAuditEntry> get entries => List.unmodifiable(_entries);

  /// Wires persistence once [AdPreferences] becomes available: loads
  /// whatever a PRIOR process already persisted, then enables
  /// persist-on-[record] from here on. Safe to call again (e.g. on every
  /// `initialize()`, including a re-init after `destroy()`) — the actual
  /// disk load only ever happens once per process (see [_loaded]); a later
  /// call just re-confirms [_prefs] without re-inserting the same
  /// persisted snapshot on top of everything recorded since. Deliberately
  /// does not clear [_entries] first either way, since this trail must
  /// survive a provider switch mid-session.
  /// T155 (codex round 1, P2) — [_load] must only ever run once per process.
  /// Without this guard, every `destroy()`+re-`initialize()` cycle called
  /// [attach] again, and [_load] unconditionally re-inserted the ENTIRE
  /// persisted snapshot in front of whatever [_entries] already held
  /// (itself already containing that same snapshot from the first attach,
  /// plus anything recorded since) — duplicating every prior entry on each
  /// reinitialization, eventually evicting genuine newer history past
  /// [maxEntries] with copies of stale duplicates.
  bool _loaded = false;

  void attach(AdPreferences prefs) {
    _prefs = prefs;
    if (_loaded) return;
    _loaded = true;
    final before = _entries.length;
    _load();
    final loaded = _entries.length - before;
    if (loaded > 0) {
      SafeLogger.d(_tag,
          'attach() reloaded $loaded persisted entr${loaded == 1 ? 'y' : 'ies'}');
    }
    // T155 (codex round 1, P1) — an entry recorded before attach() ran
    // (e.g. a pre-init bypass) never actually persisted: _schedulePersist
    // no-ops while _prefs is null. Without this, it would stay memory-only
    // until the NEXT record() call happened to schedule a write — lost if
    // the process were killed before that ever happened.
    if (before > 0) _schedulePersist();
  }

  void _load() {
    final raw = _prefs?.getBypassAuditTrailRaw();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      // T155 (codex round 2, P2) — .toList() here, INSIDE the try, forces
      // every entry to decode before any of them reach _entries. Without
      // it, `.map(...)` is lazy: insertAll(0, loaded) would insert
      // whichever entries came before a bad one, then throw — leaving a
      // PARTIAL, unvalidated prefix of the corrupt list actually retained
      // in memory (and later re-persisted) even though the catch block
      // below claims the whole thing was discarded.
      final loaded = decoded
          .cast<Map<String, dynamic>>()
          .map(BypassAuditEntry.fromJson)
          .toList();
      // Persisted entries predate anything this process may have already
      // recorded before attach() ran (in practice attach() runs first, so
      // _entries is normally empty here) — insert at the front to keep
      // newest-last order.
      _entries.insertAll(0, loaded);
      if (_entries.length > maxEntries) {
        _entries.removeRange(0, _entries.length - maxEntries);
      }
    } catch (e) {
      SafeLogger.w(_tag, 'discarding corrupt persisted bypass audit trail: $e');
    }
  }

  void record({
    required String kind,
    required String callSiteTag,
    required AdSlotType type,
  }) {
    _entries.add(BypassAuditEntry(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      callSiteTag: callSiteTag,
      type: type.name,
    ));
    if (_entries.length > maxEntries) _entries.removeAt(0);
    SafeLogger.w(_tag, '🔓 $kind recorded ($callSiteTag, ${type.name})');
    _schedulePersist();
  }

  void _schedulePersist() {
    if (_prefs == null) return; // not attached yet — in-memory only for now
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, () {
      _debounceTimer = null;
      _persistChain = _persistChain.then((_) => _persist()).catchError((e) {
        SafeLogger.w(_tag, 'bypass audit trail persist failed: $e');
      });
    });
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setBypassAuditTrailRaw(
        jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  /// Forces an immediate write, skipping (and cancelling) any pending
  /// debounce window — mirrors `AdEventLog.flush()`.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_prefs != null) {
      // T155 (codex round 3, P1) — mirrors _schedulePersist()'s own
      // .catchError(). Without it, a genuine write failure (e.g. a
      // transient platform-channel error) left _persistChain permanently
      // rejected: every later flush()/record() built its own .then() on
      // top of that same rejected future, so ALL persistence silently
      // stopped working for the rest of the process — and since the
      // lifecycle caller uses unawaited(), the error also went unhandled.
      _persistChain = _persistChain.then((_) => _persist()).catchError((e) {
        SafeLogger.w(_tag, 'bypass audit trail flush failed: $e');
      });
    }
    await _persistChain;
  }

  Future<void> clear() async {
    _entries.clear();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_prefs != null) {
      _persistChain = _persistChain.then((_) => _persist());
    }
    await _persistChain;
  }

  String toPayloadJson() => jsonEncode({
        'generatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'entries': _entries.map((e) => e.toJson()).toList(),
      });
}

/// Signs [trail]'s current contents with the SAME on-device Ed25519 key as
/// [signComplianceReport]/[signIncidentBundle] — every export from one
/// install verifies against the same public key.
Future<SignedPayload> signBypassAuditTrail(BypassAuditTrail trail) =>
    signJsonPayload(trail.toPayloadJson());
