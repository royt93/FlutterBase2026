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
  });

  final String key;
  final DateTime expiresAt;
  final DateTime grantedAt;

  bool get isActive => DateTime.now().isBefore(expiresAt);

  Duration get remaining {
    final d = expiresAt.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'expiresAt': expiresAt.toIso8601String(),
        'grantedAt': grantedAt.toIso8601String(),
      };

  factory VipEntry.fromJson(Map<String, dynamic> j) => VipEntry(
        key: j['key'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
        grantedAt: DateTime.parse(j['grantedAt'] as String),
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
