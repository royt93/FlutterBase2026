// T202 — append-only, tamper-evident (SHA-256 hash chain) history of consent
// changes, kept separate from `ConsentSettings` (current state) and
// `ComplianceReport` (point-in-time snapshot). Covers: append/chain,
// verifyChain() detecting tampering, persistence round-trip, clear().

import 'package:applovin_admob_sdk/src/compliance/compliance_signing.dart';
import 'package:applovin_admob_sdk/src/compliance/consent_provenance_journal.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  test('starts empty', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    expect(journal.entries, isEmpty);
  });

  test('append records one entry with the given fields', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    final entry = await journal.append(
      source: 'ump',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
      regionSignal: 'DE',
    );
    expect(journal.entries, [entry]);
    expect(entry.source, 'ump');
    expect(entry.policyRevision, 'ump-v1');
    expect(entry.hasUserConsent, isTrue);
    expect(entry.regionSignal, 'DE');
    expect(entry.entryHash, isNotEmpty);
  });

  test('second entry hash depends on the first entry (chained)', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    final first = await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: false,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    final second = await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    expect(second.entryHash, isNot(first.entryHash));
    expect(await journal.verifyChain(), isTrue);
  });

  test('verifyChain detects a tampered entry', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: false,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    expect(await journal.verifyChain(), isTrue);

    // Simulate a hand-edited entry (e.g. someone rewriting the persisted
    // JSON directly) by rebuilding a journal from tampered JSON.
    final tamperedJson = journal.entries.map((e) => e.toJson()).toList();
    tamperedJson[0]['hasUserConsent'] = true; // flip a field post-hash
    final tampered = ConsentProvenanceJournal.fromEntries(
      prefs,
      tamperedJson.map(ConsentProvenanceEntry.fromJson).toList(),
    );
    expect(await tampered.verifyChain(), isFalse);
  });

  test('persists across reload from the same AdPreferences', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'manual',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: true,
    );

    final reloaded = await ConsentProvenanceJournal.load(prefs);
    expect(reloaded.entries.length, 1);
    expect(reloaded.entries.single.source, 'manual');
    expect(reloaded.entries.single.doNotSell, isTrue);
    expect(await reloaded.verifyChain(), isTrue);
  });

  test('clear() wipes in-memory and persisted entries', () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    await journal.clear();
    expect(journal.entries, isEmpty);

    final reloaded = await ConsentProvenanceJournal.load(prefs);
    expect(reloaded.entries, isEmpty);
  });

  test(
      'clearSdkData() leaves the journal alone by default, both erasure scopes',
      () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );

    await prefs.clearSdkData();
    expect((await ConsentProvenanceJournal.load(prefs)).entries, hasLength(1));

    await prefs.clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );
    expect((await ConsentProvenanceJournal.load(prefs)).entries, hasLength(1));
  });

  test('clearSdkData(purgeConsentProvenanceJournal: true) removes it',
      () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );

    await prefs.clearSdkData(purgeConsentProvenanceJournal: true);
    expect((await ConsentProvenanceJournal.load(prefs)).entries, isEmpty);
  });

  test(
      'two overlapping append() calls never corrupt the chain (audit finding A)',
      () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    // Fired without awaiting between them — both start, both read
    // `prevHash` before either finishes hashing/persisting, exactly the
    // interleaving `ConsentManager.set()`/`.reset()` can produce (neither
    // call is serialized against the other at that layer).
    final a = journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    final b = journal.append(
      source: 'ump',
      policyRevision: 'ump-v1',
      hasUserConsent: false,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    await Future.wait([a, b]);

    expect(journal.entries, hasLength(2));
    expect(await journal.verifyChain(), isTrue,
        reason: 'two legitimate, un-tampered concurrent writes must never '
            'produce a chain verifyChain() flags as tampered');
  });

  test('load() degrades gracefully on corrupted persisted JSON', () async {
    await prefs.setConsentProvenanceJournalRaw('not valid json{{{');
    final journal = await ConsentProvenanceJournal.load(prefs);
    expect(journal.entries, isEmpty);

    // And appending after a corrupt load still works normally.
    await journal.append(
      source: 'host',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    expect(journal.entries, hasLength(1));
  });

  // Round 51 audit fix (MAJOR, doc correction) — verifyChain()'s own doc
  // comment used to claim it detects an entry "removed after being
  // recorded". It doesn't: dropping the tail and recomputing from what
  // remains is still a self-consistent chain. This test documents the
  // real, narrower guarantee instead of asserting a false one.
  test(
      'verifyChain() does NOT detect truncation — dropping the tail still '
      'verifies true (known limitation, not a false-positive to "fix")',
      () async {
    final journal = await ConsentProvenanceJournal.load(prefs);
    await journal.append(
      source: 'ump',
      policyRevision: 'ump-v1',
      hasUserConsent: true,
      isAgeRestrictedUser: false,
      doNotSell: false,
    );
    await journal.append(
      source: 'ump',
      policyRevision: 'ump-v1',
      hasUserConsent: false,
      isAgeRestrictedUser: false,
      doNotSell: true,
    );
    expect(journal.entries, hasLength(2));

    final truncated = ConsentProvenanceJournal.fromEntries(
        prefs, [journal.entries.first]);
    expect(await truncated.verifyChain(), isTrue,
        reason: 'documents the known gap — see verifyChain()\'s doc '
            'comment for the actual guarantee (local self-consistency, '
            'not tamper-proof against whoever controls this storage)');
  });

  group('signConsentProvenanceJournal (round 51 audit fix — MAJOR)', () {
    test('a signed export verifies via verifySignedJsonPayload', () async {
      final journal = await ConsentProvenanceJournal.load(prefs);
      await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
        regionSignal: 'DE',
      );
      final signed = await signConsentProvenanceJournal(journal);

      expect(await verifySignedJsonPayload(signed.toJsonString()), isTrue);
    });

    test('a tampered exported payload fails verification', () async {
      final journal = await ConsentProvenanceJournal.load(prefs);
      await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
        regionSignal: 'DE',
      );
      final signed = await signConsentProvenanceJournal(journal);

      final tampered = SignedPayload(
        payloadJson: signed.payloadJson.replaceFirst('"DE"', '"forged"'),
        publicKeyBase64: signed.publicKeyBase64,
        signatureBase64: signed.signatureBase64,
      );

      expect(await verifySignedJsonPayload(tampered.toJsonString()), isFalse);
    });
  });

  group('onEntryAppended hook (external-anchor opt-in)', () {
    test('fires with the appended entry after each append', () async {
      final seen = <ConsentProvenanceEntry>[];
      final journal = await ConsentProvenanceJournal.load(
        prefs,
        onEntryAppended: seen.add,
      );

      final first = await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
      );
      final second = await journal.append(
        source: 'host',
        policyRevision: 'ump-v1',
        hasUserConsent: false,
        isAgeRestrictedUser: false,
        doNotSell: false,
      );

      expect(seen, [first, second]);
    });

    test('a throwing callback does not fail the append', () async {
      final journal = await ConsentProvenanceJournal.load(
        prefs,
        onEntryAppended: (_) => throw StateError('host callback exploded'),
      );

      final entry = await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
      );

      expect(entry.source, 'ump');
      expect(journal.entries, [entry]);
    });

    test('an async-throwing callback does not escape as an unhandled error',
        () async {
      final journal = await ConsentProvenanceJournal.load(
        prefs,
        onEntryAppended: (_) async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('async host callback exploded');
        },
      );

      final entry = await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
      );

      // Give the callback's Future a chance to reject. If it escapes as an
      // unhandled zone error, flutter_test's own zone fails this test even
      // though every assertion below passes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(journal.entries, [entry]);
    });

    test('omitting it is a no-op, same as before this hook existed', () async {
      final journal = await ConsentProvenanceJournal.load(prefs);
      final entry = await journal.append(
        source: 'ump',
        policyRevision: 'ump-v1',
        hasUserConsent: true,
        isAgeRestrictedUser: false,
        doNotSell: false,
      );
      expect(journal.entries, [entry]);
    });
  });
}
