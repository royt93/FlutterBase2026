// T202 — ConsentManager records every consent change into an (optional)
// ConsentProvenanceJournal. Opt-in via `bootstrap(provenanceJournal: ...)`;
// omitting it is a no-op (no behavior change for existing callers).

import 'package:applovin_admob_sdk/src/compliance/consent_provenance_journal.dart';
import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/consent/consent_fallback.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  late AdPreferences prefs;
  late ConsentProvenanceJournal journal;

  setUp(() async {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    journal = await ConsentProvenanceJournal.load(prefs);
    ConsentManager.resetForTest();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  test('set() with no journal wired is a no-op (backward compatible)',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs, strings: ConsentDialogStrings.vi);
    await m.set(ConsentSettings.accepted);
    expect(journal.entries, isEmpty); // never wired, never touched
  });

  test('set() records an entry with default source/policyRevision',
      () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      strings: ConsentDialogStrings.vi,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.accepted);
    expect(journal.entries, hasLength(1));
    final entry = journal.entries.single;
    expect(entry.source, 'host');
    expect(entry.policyRevision, kUmpPolicyRevision);
    expect(entry.hasUserConsent, isTrue);
  });

  test('set() with an explicit source records that source', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      strings: ConsentDialogStrings.vi,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.rejected, source: 'ump');
    expect(journal.entries.single.source, 'ump');
    expect(journal.entries.single.hasUserConsent, isFalse);
  });

  test('reset() also records an entry', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      strings: ConsentDialogStrings.vi,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.accepted);
    await m.reset();
    expect(journal.entries, hasLength(2));
    expect(journal.entries.last.hasUserConsent, isFalse);
  });

  test('multiple set() calls chain in order', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      strings: ConsentDialogStrings.vi,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.accepted);
    await m.set(ConsentSettings.rejected);
    expect(journal.entries, hasLength(2));
    expect(await journal.verifyChain(), isTrue);
  });
}
