// T202 — ConsentManager records every consent change into an (optional)
// ConsentProvenanceJournal. Opt-in via `bootstrap(provenanceJournal: ...)`;
// omitting it is a no-op (no behavior change for existing callers).

import 'dart:convert';

import 'package:applovin_admob_sdk/src/compliance/consent_provenance_journal.dart';
import 'package:applovin_admob_sdk/src/consent/consent_fallback.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/config/ad_log_level.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/utils/safe_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingJournalStore extends InMemorySharedPreferencesStore {
  _FailingJournalStore() : super.empty();

  static const _journalKey = 'flutter.ad_sdk_consent_provenance_journal_v1';
  static const _settingsKey = 'flutter.ad_sdk_consent_settings_v1';

  bool failJournalWrite = true;
  bool failSettingsWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (failJournalWrite && key == _journalKey) {
      throw StateError('journal write failed');
    }
    if (failSettingsWrite && key == _settingsKey) {
      throw StateError('consent settings write failed');
    }
    return super.setValue(valueType, key, value);
  }
}

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

  test(
    'set() with no journal wired is a no-op (backward compatible)',
    () async {
      final m = await ConsentManager.bootstrap(prefs: prefs);
      await m.set(ConsentSettings.accepted);
      expect(journal.entries, isEmpty); // never wired, never touched
    },
  );

  test('set() records an entry with default source/policyRevision', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
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
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.rejected, source: 'ump');
    expect(journal.entries.single.source, 'ump');
    expect(journal.entries.single.hasUserConsent, isFalse);
  });

  test('reset() also records an entry', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.accepted);
    await m.reset();
    expect(journal.entries, hasLength(2));
    expect(journal.entries.last.hasUserConsent, isFalse);
  });

  group('provenance storage failure is best-effort', () {
    test(
      'set persists consent and applies providers when journal write fails',
      () async {
        final store = _FailingJournalStore();
        SharedPreferencesStorePlatform.instance = store;
        AdPreferences.resetForTest();
        prefs = await AdPreferences.getInstance();
        journal = await ConsentProvenanceJournal.load(prefs);
        final applied = <ConsentSettings>[];
        final warnings = <String>[];
        SafeLogger.configure(
          level: AdLogLevel.warning,
          onLog: (level, tag, message) => warnings.add('$tag: $message'),
        );
        addTearDown(() => SafeLogger.configure());
        final manager = await ConsentManager.bootstrapWithPolicy(
          prefs: prefs,
          provenanceJournal: journal,
          onPolicyMutationApplied: (_, _, current) async =>
              applied.add(current),
        );
        final settings = ConsentSettings.accepted;

        await manager.set(settings);

        expect(manager.current.toJson(), settings.toJson());
        expect(
          ConsentSettings.decode(prefs.getConsentSettingsRaw()).toJson(),
          settings.toJson(),
        );
        expect(applied, hasLength(1));
        expect(applied.single.toJson(), settings.toJson());
        expect(journal.entries, isEmpty);
        expect(warnings, [
          'ConsentManager: consent provenance journal append failed',
        ]);
        expect(
          warnings.single,
          isNot(contains(settings.hasUserConsent.toString())),
        );
        expect(
          (await store.getAll()).containsKey(_FailingJournalStore._journalKey),
          isFalse,
        );
      },
    );

    test('later successful append excludes prior failed entry', () async {
      final store = _FailingJournalStore();
      SharedPreferencesStorePlatform.instance = store;
      AdPreferences.resetForTest();
      prefs = await AdPreferences.getInstance();
      final anchored = <ConsentProvenanceEntry>[];
      journal = await ConsentProvenanceJournal.load(
        prefs,
        onEntryAppended: anchored.add,
      );
      final manager = await ConsentManager.bootstrap(
        prefs: prefs,
        provenanceJournal: journal,
      );

      await manager.set(ConsentSettings.accepted);
      expect(journal.entries, isEmpty);
      expect(
        anchored,
        isEmpty,
        reason: 'failed persistence does not call external anchor',
      );
      expect(
        (await store.getAll()).containsKey(_FailingJournalStore._journalKey),
        isFalse,
      );

      store.failJournalWrite = false;
      await manager.set(ConsentSettings.rejected);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(anchored, hasLength(1));
      expect(anchored.single.hasUserConsent, isFalse);
      expect(journal.entries, hasLength(1));
      final raw =
          (await store.getAll())[_FailingJournalStore._journalKey] as String;
      final persisted = (jsonDecode(raw) as List)
          .map(
            (entry) =>
                ConsentProvenanceEntry.fromJson(entry as Map<String, dynamic>),
          )
          .toList();
      expect(persisted, hasLength(1));
      expect(persisted.single.hasUserConsent, isFalse);
      expect(await journal.verifyChain(), isTrue);
    });

    test(
      'reset persists consent and applies providers when journal write fails',
      () async {
        final store = _FailingJournalStore()..failJournalWrite = false;
        SharedPreferencesStorePlatform.instance = store;
        AdPreferences.resetForTest();
        prefs = await AdPreferences.getInstance();
        journal = await ConsentProvenanceJournal.load(prefs);
        final applied = <ConsentSettings>[];
        final warnings = <String>[];
        SafeLogger.configure(
          level: AdLogLevel.warning,
          onLog: (level, tag, message) => warnings.add('$tag: $message'),
        );
        addTearDown(() => SafeLogger.configure());
        final manager = await ConsentManager.bootstrapWithPolicy(
          prefs: prefs,
          provenanceJournal: journal,
          onPolicyMutationApplied: (_, _, current) async =>
              applied.add(current),
        );
        await manager.set(ConsentSettings.accepted);
        expect(journal.entries, hasLength(1));

        store.failJournalWrite = true;
        applied.clear();
        await manager.reset();

        expect(manager.current.hasUserConsent, isFalse);
        expect(manager.current.hasBeenAsked, isFalse);
        expect(
          ConsentSettings.decode(prefs.getConsentSettingsRaw()).toJson(),
          manager.current.toJson(),
        );
        expect(applied.single.hasUserConsent, isFalse);
        expect(applied.single.hasBeenAsked, isFalse);
        expect(journal.entries, hasLength(1));
        expect(warnings, [
          'ConsentManager: consent provenance journal append failed',
        ]);
        expect(
          (await store.getAll()).containsKey(
            'flutter.ad_sdk_consent_provenance_journal_v1',
          ),
          isTrue,
          reason:
              'first successful entry remains persisted when the second fails',
        );
      },
    );

    test('consent settings storage failure still propagates', () async {
      final store = _FailingJournalStore()..failJournalWrite = false;
      SharedPreferencesStorePlatform.instance = store;
      AdPreferences.resetForTest();
      prefs = await AdPreferences.getInstance();
      journal = await ConsentProvenanceJournal.load(prefs);
      final manager = await ConsentManager.bootstrap(
        prefs: prefs,
        provenanceJournal: journal,
      );
      store.failSettingsWrite = true;

      await expectLater(
        manager.set(ConsentSettings.accepted),
        throwsStateError,
      );
    });
  });

  test('multiple set() calls chain in order', () async {
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      provenanceJournal: journal,
    );
    await m.set(ConsentSettings.accepted);
    await m.set(ConsentSettings.rejected);
    expect(journal.entries, hasLength(2));
    expect(await journal.verifyChain(), isTrue);
  });

  group(
    'round 63 audit fix — disabling the journal on a later bootstrap()',
    () {
      test('a second bootstrap() with provenanceJournal: null stops recording '
          'to the journal wired by the first call — this singleton survives '
          'without destroy(), so a host disabling '
          'enableConsentProvenanceJournal on reinit must not keep writing to '
          'the old journal it can no longer read', () async {
        final first = await ConsentManager.bootstrap(
          prefs: prefs,
          provenanceJournal: journal,
        );
        await first.set(ConsentSettings.accepted);
        expect(journal.entries, hasLength(1));

        // Reinit without destroy() — same singleton, host now passes null
        // (AdConfig.enableConsentProvenanceJournal: false).
        final second = await ConsentManager.bootstrap(prefs: prefs);
        expect(
          identical(first, second),
          isTrue,
          reason:
              'sanity: this singleton really does survive a reinit '
              'without destroy(), which is the whole reason this bug '
              'could happen',
        );

        await second.set(ConsentSettings.rejected);
        expect(
          journal.entries,
          hasLength(1),
          reason:
              'the old journal must not receive any more entries once '
              'a later bootstrap() explicitly passed provenanceJournal: '
              'null — AdManager().consentProvenanceJournal reports null '
              'at this point, so a write here would be silently '
              'unreachable by any public API',
        );
      });

      test('re-enabling on a third bootstrap() resumes recording', () async {
        final m1 = await ConsentManager.bootstrap(
          prefs: prefs,
          provenanceJournal: journal,
        );
        await m1.set(ConsentSettings.accepted);
        await ConsentManager.bootstrap(prefs: prefs); // disable
        final m3 = await ConsentManager.bootstrap(
          prefs: prefs,
          provenanceJournal: journal,
        );
        await m3.set(ConsentSettings.rejected);
        expect(journal.entries, hasLength(2));
      });
    },
  );
}
