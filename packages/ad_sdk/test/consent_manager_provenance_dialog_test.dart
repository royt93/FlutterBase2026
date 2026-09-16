// T202 follow-up (audit finding E) — showDialog()'s provenance wiring, in
// its OWN file. Kept separate from consent_manager_provenance_test.dart on
// purpose: a plain test() in the same file that already exercised
// ConsentProvenanceJournal.append()'s real SHA-256 hashing (package:
// cryptography, which uses a background isolate) leaves that file's
// process in a state where a LATER testWidgets() touching the same crypto
// path hangs forever — not a fake-async timing issue `tester.runAsync()`
// fixes (tried, still hung); isolating this single testWidgets test in its
// own file (matching every other passing crypto-triggering widget test in
// this suite) avoids it entirely.

import 'package:applovin_admob_sdk/src/compliance/consent_provenance_journal.dart';
import 'package:applovin_admob_sdk/src/consent/consent_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  testWidgets(
      'audit finding E: showDialog() records a provenance entry, with an '
      'overridable source', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    final journal = await ConsentProvenanceJournal.load(prefs);
    final m = await ConsentManager.bootstrap(
      prefs: prefs,
      strings: ConsentDialogStrings.vi,
      provenanceJournal: journal,
    );

    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }),
    ));

    final future = m.showDialog(capturedContext, source: 'ump');
    await tester.pumpAndSettle();

    await tester.tap(find.text(ConsentDialogStrings.vi.rejectButton));
    await tester.pumpAndSettle();
    await future;

    expect(journal.entries, hasLength(1));
    expect(journal.entries.single.source, 'ump',
        reason: 'showDialog() must forward its own source override to the '
            'journal, not always hardcode "host"');
    expect(journal.entries.single.hasUserConsent, isFalse);
  });
}
