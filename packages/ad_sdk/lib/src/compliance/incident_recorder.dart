import 'dart:convert';

import '../config/ad_config.dart';
import '../state/ad_sdk_state_snapshot.dart';
import '../utils/safe_logger.dart';
import 'compliance_signing.dart';

/// T125 — one state-transition observation: a labeled cause plus the SDK's
/// top-level [AdSdkStateSnapshot] right after it, and how long it had been
/// since the previous entry (a *relative* delta, not a wall-clock
/// timestamp — the recording device's clock and the publisher's replaying
/// this bundle are never the same clock, so the delta is what a replay can
/// actually trust).
class IncidentEntry {
  const IncidentEntry({
    required this.label,
    required this.snapshot,
    required this.deltaMs,
    this.clockRolledBackMs,
  });

  /// What triggered this observation — a short, stable string such as
  /// `'consentChanged'`, `'connectivityRestored'`, `'adapterInitialized'`.
  /// Free text by design (callers own their own label vocabulary); not an
  /// enum so a new call site never needs an SDK release to add one.
  final String label;

  final AdSdkStateSnapshot snapshot;

  /// Milliseconds since the previous entry was recorded (`0` for the first
  /// entry in a buffer/replay, and also whenever [clockRolledBackMs] is
  /// set — see its doc comment for why this is clamped rather than left
  /// negative).
  final int deltaMs;

  /// T199 — non-null (and negative) only when the wall clock read BEHIND
  /// the previous entry's (an NTP sync, a manual clock edit, a timezone
  /// change) — the raw, negative `at.difference(previous)` that would
  /// otherwise have produced a confusing negative [deltaMs]. `null` means
  /// no rollback was observed between this entry and the previous one.
  ///
  /// Deliberately NOT "fixed" by substituting a `Stopwatch`-based
  /// monotonic elapsed time instead (a natural-looking fix, and the first
  /// design considered here): `Stopwatch` pauses while the device is
  /// asleep/suspended, so an incident timeline spanning a real multi-hour
  /// background gap would then under-report a huge legitimate delta as a
  /// tiny one — a worse, silent inaccuracy than the rollback case this
  /// exists to flag, and exactly the class of pitfall `VipManager`'s own
  /// `_effectiveNow`/`resyncSessionClock` needed several audit rounds to
  /// get right for a security-sensitive anti-rollback check. This class
  /// is a lightweight diagnostics aid, not that — clamping to `0` and
  /// flagging the raw rollback amount tells a reader everything they
  /// need (a real clock jump happened here) without risking a worse,
  /// silent misreport of a genuine long background gap.
  final int? clockRolledBackMs;

  Map<String, dynamic> toJson() => {
        'label': label,
        'deltaMs': deltaMs,
        if (clockRolledBackMs != null) 'clockRolledBackMs': clockRolledBackMs,
        'isInitialised': snapshot.isInitialised,
        'canRequestAds': snapshot.canRequestAds,
        'isOffline': snapshot.isOffline,
        'isVipActive': snapshot.isVipActive,
        'fullscreenBusy': snapshot.fullscreenBusy,
      };

  factory IncidentEntry.fromJson(Map<String, dynamic> json) => IncidentEntry(
        label: json['label'] as String,
        deltaMs: json['deltaMs'] as int,
        clockRolledBackMs: json['clockRolledBackMs'] as int?,
        snapshot: AdSdkStateSnapshot(
          isInitialised: json['isInitialised'] as bool,
          canRequestAds: json['canRequestAds'] as bool,
          isOffline: json['isOffline'] as bool,
          isVipActive: json['isVipActive'] as bool,
          fullscreenBusy: json['fullscreenBusy'] as bool,
        ),
      );

  @override
  String toString() => '+${deltaMs}ms'
      '${clockRolledBackMs != null ? " (clock rolled back ${-clockRolledBackMs!}ms)" : ""}'
      ' $label -> $snapshot';
}

/// Small bounded ring buffer of [IncidentEntry] — deliberately NOT the same
/// thing as [AdEventLog] (5000 entries, every [AdEvent] payload, persisted).
/// This exists for a narrower job: a race like "the App Open just didn't
/// show" usually isn't explained by any single event, but by the *sequence*
/// of top-level state right before it — and that sequence is exactly what's
/// impossible to reconstruct on a publisher's machine after the fact from a
/// point-in-time diagnostics snapshot alone. [capacity] is small on purpose:
/// this is a short recent window, not an audit trail.
class IncidentRecorder {
  static const _tag = 'IncidentRecorder';
  static const _defaultCapacity = 200;

  IncidentRecorder({int capacity = _defaultCapacity})
      : capacity = _validCapacity(capacity);

  /// T171 — this class used to have a bare `assert(capacity > 0)`, which
  /// release builds strip (asserts are debug-only): a `<= 0` value that
  /// slipped through in production reached [record]'s `removeRange(0,
  /// _entries.length - capacity)` and threw a `RangeError` on the very
  /// first call (a negative `capacity` makes the end index exceed the
  /// list's length even when it's empty). Substituting the default rather
  /// than throwing/asserting keeps a dev's config typo from crashing the
  /// app in ANY build mode, debug included.
  static int _validCapacity(int value) {
    if (value <= 0) {
      SafeLogger.w(_tag,
          'capacity=$value is <= 0 (would throw on the next record()) — '
          'using default $_defaultCapacity instead');
      return _defaultCapacity;
    }
    return value;
  }

  final int capacity;
  final List<IncidentEntry> _entries = [];
  DateTime? _lastAt;

  /// Read-only view, oldest first.
  List<IncidentEntry> get entries => List.unmodifiable(_entries);

  void record(String label, AdSdkStateSnapshot snapshot, {DateTime? now}) {
    final at = now ?? DateTime.now();
    // T199 — a wall clock that reads BEHIND the previous entry (NTP sync,
    // manual clock edit, timezone change) produced a raw negative delta
    // here before this fix — confusing in a timeline ("+-4500ms"), and
    // silently clamping it to 0 (the obvious quick fix) would hide that a
    // clock jump happened at all. Clamp for [IncidentEntry.deltaMs]'s
    // display sanity, but keep the raw rollback amount in
    // [IncidentEntry.clockRolledBackMs] so nothing is actually hidden.
    int deltaMs = 0;
    int? clockRolledBackMs;
    if (_lastAt != null) {
      final raw = at.difference(_lastAt!).inMilliseconds;
      if (raw < 0) {
        clockRolledBackMs = raw;
      } else {
        deltaMs = raw;
      }
    }
    _lastAt = at;
    _entries.add(IncidentEntry(
      label: label,
      snapshot: snapshot,
      deltaMs: deltaMs,
      clockRolledBackMs: clockRolledBackMs,
    ));
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  void clear() {
    _entries.clear();
    _lastAt = null;
  }
}

/// Redacted structural fingerprint of [config] — provider + which
/// sub-configs are present + the (non-secret, numeric) safety caps. Never
/// includes an SDK key or ad-unit ID: those identify the publisher's
/// account, which a support bundle shared with a third party has no reason
/// to carry.
Map<String, dynamic> redactedConfigFingerprint(AdConfig config) => {
      'provider': config.provider.name,
      'hasAppLovinConfig': config.appLovin != null,
      'hasAdMobConfig': config.admob != null,
      'safety': {
        'minTimeBetweenFullscreenAds':
            config.safety.minTimeBetweenFullscreenAds,
        'maxFullscreenAdsPerSession': config.safety.maxFullscreenAdsPerSession,
        'minTimeAppOpenResume': config.safety.minTimeAppOpenResume,
        'maxClicksPerMinute': config.safety.maxClicksPerMinute,
        'maxFullscreenAdsPerDay': config.safety.maxFullscreenAdsPerDay,
        'maxFullscreenAdsPerHour': config.safety.maxFullscreenAdsPerHour,
        'minSessionDurationBeforeAd': config.safety.minSessionDurationBeforeAd,
        'suspiciousCtrThreshold': config.safety.suspiciousCtrThreshold,
        'maxRapidResumesPerMinute': config.safety.maxRapidResumesPerMinute,
        'dryRun': config.safety.dryRun,
      },
    };

/// Exportable, replayable snapshot of an [IncidentRecorder]'s current
/// buffer, plus a [redactedConfigFingerprint] so a replay knows which safety
/// caps were active without ever seeing a real ad-unit ID or SDK key.
class IncidentBundle {
  const IncidentBundle({
    required this.entries,
    required this.configFingerprint,
    required this.generatedAtMs,
  });

  factory IncidentBundle.capture(
    IncidentRecorder recorder,
    AdConfig config, {
    DateTime? now,
  }) =>
      IncidentBundle(
        entries: recorder.entries,
        configFingerprint: redactedConfigFingerprint(config),
        generatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      );

  final List<IncidentEntry> entries;
  final Map<String, dynamic> configFingerprint;
  final int generatedAtMs;

  Map<String, dynamic> toJson() => {
        'generatedAtMs': generatedAtMs,
        'configFingerprint': configFingerprint,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }

  factory IncidentBundle.fromJsonString(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return IncidentBundle(
      generatedAtMs: decoded['generatedAtMs'] as int,
      configFingerprint: decoded['configFingerprint'] as Map<String, dynamic>,
      entries: (decoded['entries'] as List)
          .cast<Map<String, dynamic>>()
          .map(IncidentEntry.fromJson)
          .toList(),
    );
  }
}

/// Signs an [IncidentBundle] with the SDK's on-device Ed25519 key (same key,
/// same threat model, as `AdManager.exportSignedComplianceReport()` — see
/// [SignedPayload]'s and [signComplianceReport]'s doc comments). The result
/// is what `tool/incident_replay.dart` reads.
Future<SignedPayload> signIncidentBundle(IncidentBundle bundle) =>
    signJsonPayload(bundle.toJsonString());

/// Pure parsing/formatting used by `tool/incident_replay.dart` — split out
/// so replay logic is unit-testable without going through a file/process.
/// Returns the ordered list of entries a replay would print, unchanged from
/// what was recorded — "replay reproduces the exact state sequence" is
/// exactly `IncidentBundle.fromJsonString(bundle.toJsonString()).entries ==
/// bundle.entries`.
List<IncidentEntry> replayIncidentBundleJson(String bundleJson) =>
    IncidentBundle.fromJsonString(bundleJson).entries;
