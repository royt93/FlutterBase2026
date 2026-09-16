// T202 — append-only, tamper-evident (SHA-256 hash chain) history of consent
// changes, kept separate from `ConsentSettings` (current state) and
// `ComplianceReport` (point-in-time snapshot). Covers: append/chain,
// verifyChain() detecting tampering, persistence round-trip, clear().

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
}
