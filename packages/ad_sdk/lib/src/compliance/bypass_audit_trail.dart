import 'dart:convert';

import '../state/ad_slot.dart';
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
class BypassAuditTrail {
  BypassAuditTrail({this.maxEntries = 200});

  /// Ring buffer cap — oldest entries drop first. 200 is generous for a
  /// signal that should fire rarely (splash-once-per-cold-start, VIP-extend
  /// on demand), not a high-frequency counter.
  final int maxEntries;

  final List<BypassAuditEntry> _entries = [];

  /// Newest-last, same order as [record] was called.
  List<BypassAuditEntry> get entries => List.unmodifiable(_entries);

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
  }

  void clear() => _entries.clear();

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
