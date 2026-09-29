import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import 'compliance_signing.dart';

const String _tag = 'AdFlightRecorder';
final Sha256 _sha256 = Sha256();

/// T231 — one hash-chained evidence entry: a single ad-display state
/// transition (banner became visible/hidden, a click landed, consent
/// changed), not a raw per-frame sample. See [AdFlightRecorder]'s own doc
/// comment for why continuous polling was rejected.
///
/// [previousHash] links this entry to the one before it and [hash] commits
/// to every field below PLUS [previousHash] — mutating any field, or
/// reordering/deleting an entry, breaks the chain at that point. Verify
/// with [verifyFlightRecorderChain].
class FlightRecorderEntry {
  const FlightRecorderEntry({
    required this.timestampMs,
    required this.label,
    required this.slotType,
    required this.placement,
    required this.providerTag,
    required this.viewabilityFraction,
    required this.screenX,
    required this.screenY,
    required this.widthPx,
    required this.heightPx,
    required this.tcfConsentString,
    required this.touchActive,
    required this.interactionDurationMs,
    required this.previousHash,
    required this.hash,
  });

  final int timestampMs;

  /// e.g. `'bannerVisible'`, `'bannerHidden'`, `'clicked'`,
  /// `'consentChanged'`. Free text, same convention as
  /// [IncidentEntry.label] — not an enum, so a new call site never needs an
  /// SDK release to add one.
  final String label;

  /// `AdSlotType.name`, or `'global'` for an entry not tied to one slot
  /// (e.g. a consent change).
  final String slotType;

  /// `AdPlacement.id`, or `'-'` for a [slotType] `'global'` entry.
  final String placement;

  /// `'[AdMob]'` / `'[AppLovin]'` / `'[SDK]'` (before an adapter exists).
  final String providerTag;

  /// 0..1, from `VisibilityInfo.visibleFraction` at the moment of capture.
  final double viewabilityFraction;

  /// Global screen pixel position — `RenderBox.localToGlobal(Offset.zero)`.
  final double screenX;
  final double screenY;
  final double widthPx;
  final double heightPx;

  /// Active IAB TCF v2 consent string at the moment of this entry, or
  /// `null` if no CMP session has ever run (see `IabStorage.keyTcfString`).
  final String? tcfConsentString;

  /// Whether this entry represents (or coincides with) a user interaction,
  /// e.g. a click. This is a flag at the moment of capture, not a measured
  /// press duration — Flutter has no touch signal at all for a native
  /// platform-view ad (AdMob/AppLovin banners render outside the widget
  /// tree), so "how long the finger was down" isn't obtainable here. An
  /// interaction *duration* for a dispute can still be derived downstream
  /// from the timestamp delta between a `'bannerVisible'` entry and the
  /// following `'clicked'` entry in the chain.
  final bool touchActive;

  /// Milliseconds between the most recent `'*Visible'` entry for this same
  /// (slotType, placement) and this entry, when [touchActive] is true — i.e.
  /// "how long the ad had been on screen before this interaction". `0` when
  /// there is no prior visible entry to measure from, or for a non-touch
  /// entry (visibility/consent transitions carry `0` here; they are not an
  /// interaction).
  final int interactionDurationMs;

  /// Hex SHA-256 of the previous entry's [hash], or `''` for the first
  /// entry ever recorded (or the first entry still retained after the ring
  /// buffer trimmed older ones — see [AdFlightRecorder]'s doc comment).
  final String previousHash;

  /// Hex SHA-256 over [previousHash] plus every other field above, in a
  /// fixed order (see `_canonicalPayload`).
  final String hash;

  Map<String, dynamic> toJson() => {
        'timestampMs': timestampMs,
        'label': label,
        'slotType': slotType,
        'placement': placement,
        'providerTag': providerTag,
        'viewabilityFraction': viewabilityFraction,
        'screenX': screenX,
        'screenY': screenY,
        'widthPx': widthPx,
        'heightPx': heightPx,
        'tcfConsentString': tcfConsentString,
        'touchActive': touchActive,
        'interactionDurationMs': interactionDurationMs,
        'previousHash': previousHash,
        'hash': hash,
      };

  factory FlightRecorderEntry.fromJson(Map<String, dynamic> json) =>
      FlightRecorderEntry(
        timestampMs: json['timestampMs'] as int,
        label: json['label'] as String,
        slotType: json['slotType'] as String,
        placement: json['placement'] as String,
        providerTag: json['providerTag'] as String,
        viewabilityFraction: (json['viewabilityFraction'] as num).toDouble(),
        screenX: (json['screenX'] as num).toDouble(),
        screenY: (json['screenY'] as num).toDouble(),
        widthPx: (json['widthPx'] as num).toDouble(),
        heightPx: (json['heightPx'] as num).toDouble(),
        tcfConsentString: json['tcfConsentString'] as String?,
        touchActive: json['touchActive'] as bool,
        interactionDurationMs: json['interactionDurationMs'] as int? ?? 0,
        previousHash: json['previousHash'] as String,
        hash: json['hash'] as String,
      );
}

/// Canonical, order-fixed JSON array hashed for one entry — a free function
/// (not a method) so [AdFlightRecorder.record] and
/// [verifyFlightRecorderChain] recompute the exact same bytes.
String _canonicalPayload({
  required String previousHash,
  required int timestampMs,
  required String label,
  required String slotType,
  required String placement,
  required String providerTag,
  required double viewabilityFraction,
  required double screenX,
  required double screenY,
  required double widthPx,
  required double heightPx,
  required String? tcfConsentString,
  required bool touchActive,
  required int interactionDurationMs,
}) =>
    jsonEncode([
      previousHash,
      timestampMs,
      label,
      slotType,
      placement,
      providerTag,
      viewabilityFraction,
      screenX,
      screenY,
      widthPx,
      heightPx,
      tcfConsentString,
      touchActive,
      interactionDurationMs,
    ]);

Future<String> _hashOf(String canonicalPayload) async {
  final digest = await _sha256.hash(utf8.encode(canonicalPayload));
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// T231 — flagship "Flight Recorder": a hash-chained, Ed25519-signable log
/// of ad-display evidence (on-screen pixel position, viewability %, active
/// TCF consent string, click occurrence) for disputing an ad-network
/// penalty/account suspension ("your ad covered the UI" / "invalid
/// traffic").
///
/// **Opt-in, default OFF** — `null` on [AdManager] unless the host calls
/// `AdManager().enableFlightRecorder(...)`, matching every other
/// monetization/compliance observer in this codebase (`WaterfallTuner`,
/// `FillRateMonitor`, ...). Disabled, every call site checks
/// `AdManager().flightRecorder == null` and returns before doing any work —
/// zero entries, zero overhead.
///
/// **Not per-frame.** A new entry is appended on a meaningful STATE
/// TRANSITION (a banner becomes visible/hidden, a click lands, consent
/// changes) — never on a timer. Continuous per-frame sampling would be
/// wasteful and would bloat the exported bundle for no dispute-relevant
/// gain; see the call sites in `BannerAdWidget`/`AdManager` for exactly
/// which transitions are wired up today.
///
/// **Bounded, like every other ring buffer in this package**
/// (`AdEventLog` 5000/`IncidentRecorder` 200/`BypassAuditTrail` 200):
/// capped at [capacity], oldest dropped first. Trimming intentionally
/// breaks the chain's link to entries older than the retained window —
/// [verifyFlightRecorderChain] proves the RETAINED window is untampered,
/// not full history back to install. That's an accepted trade-off, not a
/// bug: an unbounded per-install evidence log is exactly the kind of
/// "expensive, no ceiling" design this SDK avoids elsewhere.
///
/// **Threat model** — identical to [SignedComplianceReport]'s: on-device
/// Ed25519 signing proves the exported bytes weren't hand-edited after the
/// SDK produced them, not non-repudiation (the signing key lives on the
/// same device). The hash chain adds a SECOND, independent property on top
/// of that: even someone who can re-sign a forged copy cannot silently
/// swap or drop ONE entry in the middle without every entry after it
/// failing verification.
class AdFlightRecorder {
  AdFlightRecorder({int capacity = 2000}) : capacity = _validCapacity(capacity);

  static int _validCapacity(int value) {
    if (value <= 0) {
      SafeLogger.w(_tag,
          'capacity=$value is <= 0 — using default 2000 instead (round-72 '
          'pattern: a config typo must not crash the app in any build mode)');
      return 2000;
    }
    return value;
  }

  final int capacity;
  final List<FlightRecorderEntry> _entries = [];
  String _lastHash = '';

  // T233 — every real call site (Banner/MREC visibility, click) fires
  // `record()` via `unawaited(...)`, so two calls can be in flight at once.
  // `record()`'s body reads `_lastHash` then `await`s a real async hash
  // computation before appending + updating `_lastHash` — without
  // serializing that, two overlapping calls can both read the same
  // `_lastHash` and fork the chain. `_writeChain` forces each call's
  // read-hash-append sequence to run to completion before the next one
  // starts, same pattern as `_persistChain` below for persistence writes.
  // `_doRecord` never throws (it has its own try/catch), so chaining here
  // cannot poison this future the way an unguarded `.then` would.
  Future<void> _writeChain = Future.value();

  /// Read-only view, oldest first.
  List<FlightRecorderEntry> get entries => List.unmodifiable(_entries);

  // ─── Persistence (T231 — same debounced pattern as BypassAuditTrail/T155,
  // so evidence survives a cold start, not just the process that recorded
  // it) ───────────────────────────────────────────────────────────────────

  AdPreferences? _prefs;
  bool _loaded = false;
  Future<void> _persistChain = Future.value();
  static const Duration _debounceWindow = Duration(seconds: 1);
  Timer? _debounceTimer;

  /// Wires persistence once [AdPreferences] becomes available: loads
  /// whatever a PRIOR process already persisted (restoring [_lastHash] from
  /// the newest loaded entry so the chain continues rather than silently
  /// restarting), then enables persist-on-[record] from here on. Safe to
  /// call again — the disk load only ever happens once per process, same
  /// guard shape as `BypassAuditTrail.attach`.
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
      _lastHash = _entries.last.hash;
    }
  }

  void _load() {
    final raw = _prefs?.getFlightRecorderRaw();
    if (raw == null || raw.isEmpty) return;
    try {
      final bundle = FlightRecorderBundle.fromJsonString(raw);
      _entries.insertAll(0, bundle.entries);
      if (_entries.length > capacity) {
        _entries.removeRange(0, _entries.length - capacity);
      }
    } catch (e) {
      SafeLogger.w(_tag, 'discarding corrupt persisted flight-recorder log: $e');
    }
  }

  void _schedulePersist() {
    if (_prefs == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, () {
      _debounceTimer = null;
      _persistChain = _persistChain.then((_) => _persistNow()).catchError((e) {
        SafeLogger.w(_tag, 'flight-recorder persist failed: $e');
      });
    });
  }

  Future<void> _persistNow() async {
    final bundle = FlightRecorderBundle(
      entries: entries,
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _prefs?.setFlightRecorderRaw(bundle.toJsonString());
  }

  /// Forces an immediate write, skipping any pending debounce window — same
  /// contract as `AdEventLog.flush`.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _persistChain = _persistChain.then((_) => _persistNow());
    await _persistChain;
  }

  /// Appends one hash-chained entry. Never throws — a hashing failure
  /// (should not happen with a stdlib-backed SHA-256) is logged and
  /// swallowed rather than crashing a caller mid ad-display callback.
  ///
  /// [interactionDurationMs] is computed automatically when [touchActive]
  /// is true: milliseconds since the most recent `'*Visible'` entry for the
  /// same `(slotType, placement)`, or `0` if there is none — see
  /// [FlightRecorderEntry.interactionDurationMs]'s doc comment.
  // T233 — public entry point now only enqueues onto `_writeChain`, so
  // concurrent unawaited callers still run their read-hash-append
  // sequence one at a time, in call order, instead of interleaving across
  // the `await _hashOf(...)` yield point below.
  Future<void> record({
    required String label,
    required String slotType,
    required String placement,
    required String providerTag,
    double viewabilityFraction = 0,
    double screenX = 0,
    double screenY = 0,
    double widthPx = 0,
    double heightPx = 0,
    String? tcfConsentString,
    bool touchActive = false,
    int? timestampMs,
  }) {
    final result = _writeChain.then((_) => _doRecord(
          label: label,
          slotType: slotType,
          placement: placement,
          providerTag: providerTag,
          viewabilityFraction: viewabilityFraction,
          screenX: screenX,
          screenY: screenY,
          widthPx: widthPx,
          heightPx: heightPx,
          tcfConsentString: tcfConsentString,
          touchActive: touchActive,
          timestampMs: timestampMs,
        ));
    _writeChain = result;
    return result;
  }

  Future<void> _doRecord({
    required String label,
    required String slotType,
    required String placement,
    required String providerTag,
    required double viewabilityFraction,
    required double screenX,
    required double screenY,
    required double widthPx,
    required double heightPx,
    required String? tcfConsentString,
    required bool touchActive,
    required int? timestampMs,
  }) async {
    try {
      final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
      final previousHash = _lastHash;
      final interactionDurationMs = touchActive
          ? _msSinceLastVisible(slotType: slotType, placement: placement, ts: ts)
          : 0;
      final payload = _canonicalPayload(
        previousHash: previousHash,
        timestampMs: ts,
        label: label,
        slotType: slotType,
        placement: placement,
        providerTag: providerTag,
        viewabilityFraction: viewabilityFraction,
        screenX: screenX,
        screenY: screenY,
        widthPx: widthPx,
        heightPx: heightPx,
        tcfConsentString: tcfConsentString,
        touchActive: touchActive,
        interactionDurationMs: interactionDurationMs,
      );
      final hash = await _hashOf(payload);
      _entries.add(FlightRecorderEntry(
        timestampMs: ts,
        label: label,
        slotType: slotType,
        placement: placement,
        providerTag: providerTag,
        viewabilityFraction: viewabilityFraction,
        screenX: screenX,
        screenY: screenY,
        widthPx: widthPx,
        heightPx: heightPx,
        tcfConsentString: tcfConsentString,
        touchActive: touchActive,
        interactionDurationMs: interactionDurationMs,
        previousHash: previousHash,
        hash: hash,
      ));
      if (_entries.length > capacity) {
        _entries.removeRange(0, _entries.length - capacity);
      }
      _lastHash = hash;
      // Lifecycle only — never the evidence content itself (pixel
      // position/viewability/TCF string/touch state), so this debug log
      // never duplicates what the signed export exists to carry.
      SafeLogger.d(_tag, () => '$label recorded (chain length ${_entries.length})');
      _schedulePersist();
    } catch (e) {
      SafeLogger.w(_tag, 'record($label) failed — evidence entry dropped: $e');
    }
  }

  int _msSinceLastVisible(
      {required String slotType, required String placement, required int ts}) {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final e = _entries[i];
      if (e.slotType == slotType &&
          e.placement == placement &&
          e.label.toLowerCase().endsWith('visible')) {
        return (ts - e.timestampMs).clamp(0, 1 << 31);
      }
    }
    return 0;
  }

  /// Clears the chain and resets the hash anchor, so the next [record] call
  /// starts a fresh chain with `previousHash == ''`.
  void clear() {
    _entries.clear();
    _lastHash = '';
  }
}

/// Recomputes every entry's hash from its own fields and checks the
/// previous-hash linkage between consecutive entries — this is what
/// actually detects tampering (a mutated field, a swapped/reordered entry,
/// or a fabricated appended entry), not just eyeballing [FlightRecorderEntry.hash]
/// strings. Returns `true` for an empty list (nothing to disprove).
Future<bool> verifyFlightRecorderChain(List<FlightRecorderEntry> entries) async {
  String expectedPrevious =
      entries.isEmpty ? '' : entries.first.previousHash;
  for (final e in entries) {
    if (e.previousHash != expectedPrevious) return false;
    final payload = _canonicalPayload(
      previousHash: e.previousHash,
      timestampMs: e.timestampMs,
      label: e.label,
      slotType: e.slotType,
      placement: e.placement,
      providerTag: e.providerTag,
      viewabilityFraction: e.viewabilityFraction,
      screenX: e.screenX,
      screenY: e.screenY,
      widthPx: e.widthPx,
      heightPx: e.heightPx,
      tcfConsentString: e.tcfConsentString,
      touchActive: e.touchActive,
      interactionDurationMs: e.interactionDurationMs,
    );
    final recomputed = await _hashOf(payload);
    if (recomputed != e.hash) return false;
    expectedPrevious = e.hash;
  }
  return true;
}

/// Exportable snapshot of an [AdFlightRecorder]'s current buffer — the
/// payload signed by [signFlightRecorderBundle], same shape convention as
/// `IncidentBundle`.
class FlightRecorderBundle {
  const FlightRecorderBundle({
    required this.entries,
    required this.generatedAtMs,
  });

  final List<FlightRecorderEntry> entries;
  final int generatedAtMs;

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
        'generatedAtMs': generatedAtMs,
      };

  String toJsonString() => jsonEncode(toJson());

  factory FlightRecorderBundle.fromJsonString(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return FlightRecorderBundle(
      entries: (decoded['entries'] as List)
          .cast<Map<String, dynamic>>()
          .map(FlightRecorderEntry.fromJson)
          .toList(),
      generatedAtMs: decoded['generatedAtMs'] as int,
    );
  }
}

/// Signs a [FlightRecorderBundle] with the same on-device Ed25519 key as
/// every other compliance export (see `compliance_signing.dart`). Verify
/// with `verifySignedJsonPayload`.
Future<SignedPayload> signFlightRecorderBundle(FlightRecorderBundle bundle) =>
    signJsonPayload(bundle.toJsonString());

/// Parses+verifies a signed flight-recorder bundle then checks its hash
/// chain — the full "is this `.adproof` bundle trustworthy" check a
/// dispute-review tool would run. `.adproof` here means this SDK's own
/// signed JSON evidence-bundle format, not an external/industry standard.
Future<bool> verifySignedFlightRecorderBundle(String bundleJson) async {
  final payloadJson = _extractPayloadJson(bundleJson);
  if (payloadJson == null) return false;
  if (!await verifySignedJsonPayload(bundleJson)) return false;
  try {
    final bundle = FlightRecorderBundle.fromJsonString(payloadJson);
    return verifyFlightRecorderChain(bundle.entries);
  } catch (_) {
    return false;
  }
}

String? _extractPayloadJson(String bundleJson) {
  try {
    final decoded = jsonDecode(bundleJson) as Map<String, dynamic>;
    return decoded['payloadJson'] as String?;
  } catch (_) {
    return null;
  }
}
