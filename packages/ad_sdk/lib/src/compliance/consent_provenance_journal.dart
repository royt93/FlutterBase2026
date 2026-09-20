import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/ad_preferences.dart';
import 'compliance_signing.dart';

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
  ConsentProvenanceJournal._(this._prefs, this._entries, this._onEntryAppended);

  final AdPreferences _prefs;
  final List<ConsentProvenanceEntry> _entries;

  /// Opt-in, fire-after-persist hook — lets a host app forward each entry to
  /// its own server as an external anchor. [verifyChain]'s doc comment
  /// explains why this journal alone cannot detect a fully forged chain
  /// (no secret, no external anchor): a host that mirrors entries here as
  /// they happen gets a copy outside device storage before any later
  /// on-device tampering could occur. The SDK stays backend-free itself —
  /// it only calls this synchronously with the entry; any network call is
  /// the host's own to make and await. Errors thrown here are swallowed so
  /// a broken host callback can never fail a real consent change.
  final void Function(ConsentProvenanceEntry entry)? _onEntryAppended;

  /// Serializes [append] calls (audit finding A) — `ConsentManager.set()`/
  /// `.reset()` don't serialize their own calls against each other, so two
  /// overlapping consent changes could otherwise both read the same
  /// `prevHash` before either finished hashing, producing a chain
  /// [verifyChain] would wrongly flag as tampered. A simple Future-chained
  /// mutex: each call waits for the previous one's write to fully land
  /// (read `prevHash` → hash → append → persist) before starting its own.
  Future<void> _writeQueue = Future<void>.value();

  /// Read-only view, oldest first.
  List<ConsentProvenanceEntry> get entries => List.unmodifiable(_entries);

  static Future<ConsentProvenanceJournal> load(
    AdPreferences prefs, {
    void Function(ConsentProvenanceEntry entry)? onEntryAppended,
  }) async {
    final raw = prefs.getConsentProvenanceJournalRaw();
    final entries = _decode(raw);
    return ConsentProvenanceJournal._(prefs, entries, onEntryAppended);
  }

  /// Test-only: build a journal from entries not necessarily produced by
  /// [append] (e.g. hand-tampered JSON), to exercise [verifyChain].
  @visibleForTesting
  static ConsentProvenanceJournal fromEntries(
    AdPreferences prefs,
    List<ConsentProvenanceEntry> entries,
  ) =>
      ConsentProvenanceJournal._(prefs, List.of(entries), null);

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
  }) {
    final result = _writeQueue.then((_) => _appendLocked(
          source: source,
          policyRevision: policyRevision,
          hasUserConsent: hasUserConsent,
          isAgeRestrictedUser: isAgeRestrictedUser,
          doNotSell: doNotSell,
          regionSignal: regionSignal,
          now: now,
        ));
    // Swallow errors here so one failed append doesn't wedge the queue for
    // every append after it — the error still propagates to `result`.
    _writeQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ConsentProvenanceEntry> _appendLocked({
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
    try {
      _onEntryAppended?.call(entry);
    } catch (_) {
      // Swallowed by design — see the field's own doc comment.
    }
    return entry;
  }

  /// Recomputes every entry's hash from its fields and the previous entry's
  /// (persisted) hash, and compares against what's stored.
  ///
  /// **Round 51 audit fix (doc correction, MAJOR finding)**: this only
  /// catches an entry whose stored `entryHash` no longer matches its own
  /// fields plus the chain up to it — e.g. accidental corruption, or a bug
  /// that edited an entry in place without recomputing downstream hashes.
  /// It does **not** detect truncation (dropping the tail of the chain and
  /// re-deriving from what remains still verifies as `true`) or a fully
  /// forged chain (an attacker who can write this journal's storage can
  /// recompute a self-consistent hash chain from scratch). There is no
  /// secret or external anchor here, only a local recomputation — same
  /// "tamper-evidence, not non-repudiation" threat model documented on
  /// [SignedComplianceReport] and [SignedPayload], which this class did
  /// not previously have any signed-export path to actually benefit from.
  /// For evidence handed to a third party, export via
  /// [signConsentProvenanceJournal] and have the recipient verify the
  /// signature — that at least proves the exported bytes weren't edited
  /// after the SDK produced them, which `verifyChain()` alone cannot.
  Future<bool> verifyChain() async {
    var prevHash = '';
    for (final entry in _entries) {
      final expected = await _hash(prevHash, entry.hashedFields());
      if (expected != entry.entryHash) return false;
      prevHash = entry.entryHash;
    }
    return true;
  }

  /// The exact compact JSON this journal persists — the payload
  /// [signConsentProvenanceJournal] signs.
  String toPayloadJson() =>
      jsonEncode(_entries.map((e) => e.toJson()).toList());

  /// Explicit purge — see class doc comment for why this is never called
  /// implicitly by a routine `clearSdkData()` erasure.
  Future<void> clear() async {
    _entries.clear();
    await _prefs.clearConsentProvenanceJournal();
  }
}

/// Signs a [ConsentProvenanceJournal] snapshot the same way
/// [signComplianceReport]/[signBypassAuditTrail]/[signIncidentBundle] do —
/// every export on one install verifies against the same public key. See
/// [SignedPayload] and [ConsentProvenanceJournal.verifyChain]'s doc comment
/// for what this does and doesn't prove.
Future<SignedPayload> signConsentProvenanceJournal(
        ConsentProvenanceJournal journal) =>
    signJsonPayload(journal.toPayloadJson());
