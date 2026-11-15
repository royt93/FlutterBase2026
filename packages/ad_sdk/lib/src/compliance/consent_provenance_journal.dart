import 'dart:async';
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

  Map<String, dynamic> toJson() => {...hashedFields(), 'entryHash': entryHash};

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

/// Append-only consent history. Explicitly purged via
/// `purgeConsentProvenanceJournal`, separate from entitlement erasure.
class ConsentProvenanceJournal {
  ConsentProvenanceJournal._(this._prefs, this._entries, this._onEntryAppended);

  final AdPreferences _prefs;
  final List<ConsentProvenanceEntry> _entries;

  /// Opt-in, at-least-once host anchor. Deduplicate by `entryHash`; a crash
  /// between callback success and cursor persistence can repeat delivery.
  /// Delivery never blocks consent mutation.
  final FutureOr<void> Function(ConsentProvenanceEntry entry)? _onEntryAppended;

  int? _anchorCursor;
  int _baselineEntryCount = 0;
  int _persistedEntryCount = 0;
  bool _deliveryRunning = false;
  bool _deliveryRequested = false;
  bool _deliveryReady = false;
  int _deliveryGeneration = 0;

  Future<void> _writeQueue = Future<void>.value();

  /// Read-only view, oldest first.
  List<ConsentProvenanceEntry> get entries => List.unmodifiable(_entries);

  /// Returns an immutable oldest-first page without changing the journal.
  /// [offset] is zero-based; [limit] defaults to 100 and is capped at 500.
  List<ConsentProvenanceEntry> entriesPage({int offset = 0, int limit = 100}) {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 500');
    }
    if (offset >= _entries.length) return const [];
    final end = (offset + limit).clamp(0, _entries.length);
    return List.unmodifiable(_entries.sublist(offset, end));
  }

  static Future<ConsentProvenanceJournal> load(
    AdPreferences prefs, {
    FutureOr<void> Function(ConsentProvenanceEntry entry)? onEntryAppended,
  }) async {
    final raw = prefs.getConsentProvenanceJournalRaw();
    final entries = _decode(raw);
    final journal = ConsentProvenanceJournal._(prefs, entries, onEntryAppended)
      .._persistedEntryCount = entries.length;
    if (onEntryAppended != null) {
      final state = prefs.getConsentProvenanceAnchorState();
      if (state == null) {
        journal
          .._baselineEntryCount = entries.length
          .._anchorCursor = entries.length;
        try {
          await prefs.setConsentProvenanceAnchorState(
            entries.length,
            entries.length,
          );
          journal._deliveryReady = true;
        } catch (_) {}
      } else if (state.isEmpty || state[0] < 0 || state[0] > entries.length) {
        journal
          .._baselineEntryCount = 0
          .._anchorCursor = 0
          .._deliveryReady = true;
        await prefs.setConsentProvenanceAnchorState(0, 0);
        journal._scheduleDelivery();
      } else if (state[1] < state[0] || state[1] > entries.length) {
        journal
          .._baselineEntryCount = state[0]
          .._anchorCursor = state[0]
          .._deliveryReady = true;
        await prefs.setConsentProvenanceAnchorState(state[0], state[0]);
        journal._scheduleDelivery();
      } else {
        journal
          .._baselineEntryCount = state[0]
          .._anchorCursor = state[1]
          .._deliveryReady = true;
        if (journal._anchorCursor! < entries.length) {
          journal._scheduleDelivery();
        }
      }
    }
    return journal;
  }

  /// Test-only: build a journal from entries not necessarily produced by
  /// [append] (e.g. hand-tampered JSON), to exercise [verifyChain].
  @visibleForTesting
  static ConsentProvenanceJournal fromEntries(
    AdPreferences prefs,
    List<ConsentProvenanceEntry> entries,
  ) => ConsentProvenanceJournal._(prefs, List.of(entries), null);

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
    if (_onEntryAppended != null && !_deliveryReady) {
      throw StateError('external anchor baseline is not durable');
    }
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await _prefs.setConsentProvenanceJournalRaw(json);
    _persistedEntryCount = _entries.length;
  }

  void _scheduleDelivery() {
    if (_onEntryAppended == null || !_deliveryReady) return;
    if (_deliveryRunning) {
      _deliveryRequested = true;
      return;
    }
    _deliveryRunning = true;
    _deliveryRequested = false;
    unawaited(_deliverPending(_deliveryGeneration));
  }

  Future<void> _deliverPending(int generation) async {
    try {
      while (generation == _deliveryGeneration) {
        final nextIndex = _anchorCursor;
        if (nextIndex == null ||
            nextIndex >= _entries.length ||
            nextIndex >= _persistedEntryCount) {
          return;
        }

        if (nextIndex < _baselineEntryCount) {
          _anchorCursor = _baselineEntryCount;
          await _prefs.setConsentProvenanceAnchorState(
            _baselineEntryCount,
            _anchorCursor!,
          );
          continue;
        }
        final entry = _entries[nextIndex];
        await _onEntryAppended!(entry);
        if (generation != _deliveryGeneration) return;
        final nextCursor = nextIndex + 1;
        await _prefs.setConsentProvenanceAnchorState(
          _baselineEntryCount,
          nextCursor,
        );
        _anchorCursor = nextCursor;
      }
    } catch (_) {
      // A later append or reload retries delivery.
    } finally {
      _deliveryRunning = false;
      if (generation != _deliveryGeneration || _deliveryRequested) {
        _scheduleDelivery();
      }
    }
  }

  static Future<String> _hash(
    String prevHash,
    Map<String, dynamic> fields,
  ) async {
    final digest = await Sha256().hash(
      utf8.encode(prevHash + jsonEncode(fields)),
    );
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
    final result = _writeQueue.then(
      (_) => _appendLocked(
        source: source,
        policyRevision: policyRevision,
        hasUserConsent: hasUserConsent,
        isAgeRestrictedUser: isAgeRestrictedUser,
        doNotSell: doNotSell,
        regionSignal: regionSignal,
        now: now,
      ),
    );
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
    try {
      await _persist();
    } catch (_) {
      _entries.removeLast();
      rethrow;
    }
    _scheduleDelivery();
    return entry;
  }

  /// Recomputes each entry hash. Detects edits, not truncation or forged chains;
  /// use [signConsentProvenanceJournal] for verifiable third-party exports.
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
  Future<void> clear() {
    final result = _writeQueue.then((_) async {
      _deliveryGeneration++;
      _entries.clear();
      _anchorCursor = 0;
      _baselineEntryCount = 0;
      await _prefs.clearConsentProvenanceJournal();
    });
    _writeQueue = result.catchError((_) {});
    return result;
  }
}

/// Signs a [ConsentProvenanceJournal] snapshot the same way
/// [signComplianceReport]/[signBypassAuditTrail]/[signIncidentBundle] do —
/// every export on one install verifies against the same public key. See
/// [SignedPayload] and [ConsentProvenanceJournal.verifyChain]'s doc comment
/// for what this does and doesn't prove.
Future<SignedPayload> signConsentProvenanceJournal(
  ConsentProvenanceJournal journal,
) => signJsonPayload(journal.toPayloadJson());
