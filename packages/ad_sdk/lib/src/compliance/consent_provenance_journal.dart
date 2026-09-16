import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../utils/ad_preferences.dart';

/// T202 — one append-only, tamper-evident record of a consent change.
///
/// Distinct from `ConsentSettings` (current state only, overwritten on every
/// change) and `ComplianceReport` (a point-in-time snapshot) — this is the
/// history neither of those keeps: what changed, from what source, under
/// which policy revision, and when.
class ConsentProvenanceEntry {
  const ConsentProvenanceEntry({
    required this.at,
    required this.source,
    required this.policyRevision,
    required this.hasUserConsent,
    required this.isAgeRestrictedUser,
    required this.doNotSell,
    required this.entryHash,
    this.regionSignal,
  });

  final DateTime at;

  /// Free text by design, same convention as `IncidentEntry.label` — this
  /// SDK's own call sites use `'ump'`, `'host'`, `'manual'`, but a caller
  /// forwarding some other consent mechanism (a server-side sync, a custom
  /// dialog) is not forced into that vocabulary.
  final String source;

  /// Same string convention as `ConsentFallbackState.policyRevision` /
  /// `kUmpPolicyRevision` (e.g. `'ump-v1'`) — NOT an int, to stay consistent
  /// with the rest of the consent subsystem.
  final String policyRevision;

  final bool hasUserConsent;
  final bool isAgeRestrictedUser;
  final bool doNotSell;

  /// Consent-country signal, same caveats as `ConsentSettings.country` —
  /// never a real geolocation.
  final String? regionSignal;

  /// `base64Url(SHA-256(prevHash + jsonEncode(fields)))` — see
  /// [ConsentProvenanceJournal.append]. Empty-string `prevHash` for the
  /// first entry in a journal.
  final String entryHash;

  /// The fields covered by [entryHash] — deliberately excludes [entryHash]
  /// itself. Key order is fixed (Dart map literals preserve insertion
  /// order, and `jsonEncode` walks a `Map` in that order), so this is
  /// reproducible from the same field values every time.
  Map<String, dynamic> hashedFields() => {
        'at': at.toUtc().toIso8601String(),
        'source': source,
        'policyRevision': policyRevision,
        'hasUserConsent': hasUserConsent,
        'isAgeRestrictedUser': isAgeRestrictedUser,
        'doNotSell': doNotSell,
        'regionSignal': regionSignal,
      };

  Map<String, dynamic> toJson() => {
        ...hashedFields(),
        'entryHash': entryHash,
      };

  factory ConsentProvenanceEntry.fromJson(Map<String, dynamic> j) =>
      ConsentProvenanceEntry(
        at: DateTime.parse(j['at'] as String).toUtc(),
        source: j['source'] as String,
        policyRevision: j['policyRevision'] as String,
        hasUserConsent: j['hasUserConsent'] as bool,
        isAgeRestrictedUser: j['isAgeRestrictedUser'] as bool,
        doNotSell: j['doNotSell'] as bool,
        regionSignal: j['regionSignal'] as String?,
        entryHash: j['entryHash'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is ConsentProvenanceEntry && other.entryHash == entryHash;

  @override
  int get hashCode => entryHash.hashCode;
}

/// Append-only history of [ConsentProvenanceEntry], persisted as a single
/// JSON array via [AdPreferences] (same backend as `ConsentSettings`).
///
/// Kept OUT of `AdPreferences.clearSdkData()`'s default sweep — a routine
/// erasure request must not silently destroy the very evidence GDPR Art.
/// 17(3) / CCPA sometimes require keeping ("we can prove what consent state
/// applied and when"). Pass `purgeConsentProvenanceJournal: true` to that
/// method to remove it explicitly — a deliberate, separate decision from
/// erasing entitlements, hence its own flag rather than reuse of
/// `SdkDataErasureScope.allIncludingEntitlements` (that scope is
/// specifically about VIP/paid entitlements, an unrelated concern).
class ConsentProvenanceJournal {
  ConsentProvenanceJournal._(this._prefs, this._entries);

  final AdPreferences _prefs;
  final List<ConsentProvenanceEntry> _entries;

  /// Read-only view, oldest first.
  List<ConsentProvenanceEntry> get entries => List.unmodifiable(_entries);

  static Future<ConsentProvenanceJournal> load(AdPreferences prefs) async {
    final raw = prefs.getConsentProvenanceJournalRaw();
    final entries = _decode(raw);
    return ConsentProvenanceJournal._(prefs, entries);
  }

  /// Test-only: build a journal from entries not necessarily produced by
  /// [append] (e.g. hand-tampered JSON), to exercise [verifyChain].
  static ConsentProvenanceJournal fromEntries(
    AdPreferences prefs,
    List<ConsentProvenanceEntry> entries,
  ) =>
      ConsentProvenanceJournal._(prefs, List.of(entries));

  static List<ConsentProvenanceEntry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .cast<Map<String, dynamic>>()
          .map(ConsentProvenanceEntry.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist() async {
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await _prefs.setConsentProvenanceJournalRaw(json);
  }

  static Future<String> _hash(String prevHash, Map<String, dynamic> fields) async {
    final digest = await Sha256().hash(utf8.encode(prevHash + jsonEncode(fields)));
    return base64Url.encode(digest.bytes);
  }

  /// Appends one entry, chained to the previous entry's [entryHash] (empty
  /// string for the first entry), persists the whole journal, and returns
  /// the new entry.
  Future<ConsentProvenanceEntry> append({
    required String source,
    required String policyRevision,
    required bool hasUserConsent,
    required bool isAgeRestrictedUser,
    required bool doNotSell,
    String? regionSignal,
    DateTime? now,
  }) async {
    final prevHash = _entries.isEmpty ? '' : _entries.last.entryHash;
    final at = (now ?? DateTime.now()).toUtc();
    final draft = ConsentProvenanceEntry(
      at: at,
      source: source,
      policyRevision: policyRevision,
      hasUserConsent: hasUserConsent,
      isAgeRestrictedUser: isAgeRestrictedUser,
      doNotSell: doNotSell,
      regionSignal: regionSignal,
      entryHash: '',
    );
    final hash = await _hash(prevHash, draft.hashedFields());
    final entry = ConsentProvenanceEntry(
      at: at,
      source: source,
      policyRevision: policyRevision,
      hasUserConsent: hasUserConsent,
      isAgeRestrictedUser: isAgeRestrictedUser,
      doNotSell: doNotSell,
      regionSignal: regionSignal,
      entryHash: hash,
    );
    _entries.add(entry);
    await _persist();
    return entry;
  }

  /// Recomputes every entry's hash from its fields and the previous entry's
  /// (persisted) hash, and compares against what's stored. `false` means at
  /// least one entry was modified, reordered, or removed after being
  /// recorded (or the chain was built directly from untrusted JSON, e.g.
  /// [fromEntries]).
  Future<bool> verifyChain() async {
    var prevHash = '';
    for (final entry in _entries) {
      final expected = await _hash(prevHash, entry.hashedFields());
      if (expected != entry.entryHash) return false;
      prevHash = entry.entryHash;
    }
    return true;
  }

  /// Explicit purge — see class doc comment for why this is never called
  /// implicitly by a routine `clearSdkData()` erasure.
  Future<void> clear() async {
    _entries.clear();
    await _prefs.clearConsentProvenanceJournal();
  }
}
