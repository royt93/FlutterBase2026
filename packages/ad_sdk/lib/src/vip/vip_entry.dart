import 'dart:convert';

/// A single VIP grant. Persisted as JSON in `SharedPreferences` under
/// `ad_sdk_vip_entries`.
///
/// Each entry has:
/// - [key] — opaque identifier (the user-supplied code, normalised). Used as
///   primary key for `revokeVip(key)`.
/// - [expiresAt] — wall-clock time after which this entry is no longer valid.
/// - [grantedAt] — when redeemed (informational, surfaced in the demo UI).
class VipEntry {
  const VipEntry({
    required this.key,
    required this.expiresAt,
    required this.grantedAt,
    this.stackedFrom = const <String>{},
  });

  final String key;
  final DateTime expiresAt;
  final DateTime grantedAt;

  /// Keys whose remaining window this entry absorbed when it was created with
  /// `stack: true`, transitively.
  ///
  /// Round-23 QC (reviewer C, MAJOR) — without it, revocation was launderable.
  /// `addVip(stack: true)` extends from the latest expiry across *all* live
  /// entries, so redeeming a 30-day signed key and then watching one rewarded
  /// ad for "+1 day" moves the whole 30 days into a `WATCH_AD` entry.
  /// `VipManager._clampRevokedEntries` matches on `SIGNED_<kid>`, so revoking
  /// that key afterwards — leaked, refunded, resold — clamped an entry that no
  /// longer held the time. One tap, and the CRL cannot reach the window it was
  /// published to take back.
  ///
  /// Transitive on purpose: chaining a second stack onto the laundered entry
  /// would otherwise launder it again.
  final Set<String> stackedFrom;

  /// True if this entry is currently valid, evaluated against [now].
  ///
  /// T17 anti clock-rollback: `grantedAt` is the immutable anchor. If [now]
  /// reads *before* `grantedAt`, the system clock was set backwards after the
  /// grant — the naive `now.isBefore(expiresAt)` check would let an
  /// expired-by-real-time entry "come back to life". Treat a rolled-back
  /// clock as the entry having already been consumed rather than granting
  /// extra time (fail-safe, not fail-open).
  ///
  /// This only catches a rollback to *before* the grant. A rollback to
  /// somewhere *between* `grantedAt` and `expiresAt` — done after the entry
  /// already expired in real time — passes this check undetected, because
  /// from this entry's own point of view that's indistinguishable from a
  /// legitimate still-active window. [VipManager] closes that gap by passing
  /// a `now` that's already been clamped against a persisted high-water
  /// mark, rather than a raw `DateTime.now()`.
  bool isActiveAt(DateTime now) {
    if (now.isBefore(grantedAt)) return false;
    return now.isBefore(expiresAt);
  }

  /// Convenience for callers that don't need the clock-rollback clamp
  /// [VipManager] applies (e.g. tests constructing a bare [VipEntry]).
  bool get isActive => isActiveAt(DateTime.now());

  Duration remainingAt(DateTime now) {
    if (now.isBefore(grantedAt)) return Duration.zero;
    final d = expiresAt.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  Duration get remaining => remainingAt(DateTime.now());

  /// Persists both instants as **UTC** ISO-8601 (with the `Z` suffix).
  ///
  /// Round-23 audit, MAJOR — this used to write the plain
  /// `DateTime.toIso8601String()` of a local DateTime, i.e. `2026-08-25T10:00`
  /// with no zone marker at all. `DateTime.parse` then re-reads such a string
  /// *in whatever zone the device happens to be in at read time*, so the
  /// absolute instant silently moves whenever the zone does: a user who flies
  /// west, or whose region simply leaves DST, loses up to a day of VIP —
  /// and because [VipManager]'s `_purgeExpired()` deletes anything it reads as
  /// expired, and there is no server to restore from, the loss is permanent.
  /// Stamping `Z` pins the instant; [fromJson] converts back to local so every
  /// existing consumer (display, countdowns, `difference`) is unaffected.
  ///
  /// Entries written by <= 2.3.4 have no suffix and are still parsed as local
  /// on read — the same (zone-dependent) reading they had before. Nothing can
  /// recover the original zone from a string that never recorded it; the fix
  /// stops new grants from being ambiguous.
  Map<String, dynamic> toJson() => {
        'key': key,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'grantedAt': grantedAt.toUtc().toIso8601String(),
        // Omitted when empty, which is every non-stacked grant: rows written by
        // this version stay byte-identical to older ones unless there is
        // actually provenance to record.
        if (stackedFrom.isNotEmpty) 'stackedFrom': stackedFrom.toList(),
      };

  /// `.toLocal()` keeps the in-memory contract every caller already relies on
  /// (entries built from `DateTime.now()` are local), while the persisted form
  /// stays zone-independent — see [toJson].
  factory VipEntry.fromJson(Map<String, dynamic> j) => VipEntry(
        key: j['key'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String).toLocal(),
        grantedAt: DateTime.parse(j['grantedAt'] as String).toLocal(),
        // Absent on every row written before this version, and on every
        // non-stacked row since. Missing provenance is not a parse failure —
        // those grants simply have none to record.
        stackedFrom: j['stackedFrom'] is List
            ? (j['stackedFrom'] as List).whereType<String>().toSet()
            : const <String>{},
      );

  static String encodeList(List<VipEntry> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<VipEntry> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    // Skip-and-continue: one corrupt entry should NOT drop the whole list.
    // (E.g. user partially edited prefs by mistake.)
    final out = <VipEntry>[];
    for (final e in decoded) {
      try {
        if (e is Map) {
          out.add(VipEntry.fromJson(Map<String, dynamic>.from(e)));
        }
      } catch (_) {
        // skip this entry
      }
    }
    return out;
  }

  @override
  String toString() =>
      'VipEntry(key=$key, expiresAt=${expiresAt.toIso8601String()})';
}
