// On-device integration test for round-23 MAJOR V2 — a stacked grant must carry
// its provenance through the REAL store, not just through a Map.
//
// The finding: `addVip(stack: true)` extends the latest expiry across all live
// entries (documented, deliberate), so redeeming a signed 30-day key and then
// watching one rewarded ad for "+1 day" moved the whole 30 days into the
// `WATCH_AD` entry — out of reach of `_clampRevokedEntries`, which matches on
// `SIGNED_<kid>`. Publishing a CRL for a leaked or refunded key then did
// nothing.
//
// The clamp arithmetic is pure Dart and is proven by
// `packages/ad_sdk/test/r23_stack_launder_test.dart`. What that unit test
// CANNOT prove is the part this file exists for: `stackedFrom` is a `Set<String>`
// that has to survive `toJson` → `flutter_secure_storage` (Keychain /
// EncryptedSharedPreferences) → `fromJson` on a real device. A provenance that
// is correct in memory and lost on the next launch closes nothing — the launder
// just takes one extra app restart.
//
// Run with:
//   flutter test integration_test/r23_stack_provenance_test.dart -d <device-id>

import 'dart:convert';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:cryptography/cryptography.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised && AdManager().vip != null) return;
  }
  fail('SDK must finish initialising on device');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _kid = 'R23DEVICEKID';
const _signedKey = 'SIGNED_$_kid';
const _rewardKey = 'WATCH_AD';

/// Hands back one CRL, so the test owns exactly what the publisher published.
class _StaticCrl implements VipRevocationProvider {
  _StaticCrl(this._crl);
  final String _crl;
  @override
  Future<String?> fetchSignedCrl() async => _crl;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a rewarded-ad stack records what it absorbed, and that survives '
      'a real round-trip through secure storage', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();
    final store = VipEntriesStore(prefs);

    await vip.revokeAll();
    await _settle(tester);

    await vip.addVip(key: _signedKey, duration: const Duration(days: 30));
    await _settle(tester);

    // The one tap. No root, no clock tampering, no tooling — the SDK's own
    // reward button, extending VIP by a day.
    await vip.addVip(
        key: _rewardKey, duration: const Duration(days: 1), stack: true);
    await _settle(tester);

    // On disk, in the format the real store actually wrote.
    final raw = await store.getRaw();
    expect(raw, isNotNull);
    final rows = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
    final laundered =
        rows.firstWhere((r) => r['key'] == _rewardKey, orElse: () => {});
    expect(laundered, isNotEmpty,
        reason: 'sanity — the stacked reward entry must exist');
    expect(laundered['stackedFrom'], isNotNull,
        reason: 'THE finding — a stacked grant that does not record what it '
            'absorbed puts the window out of the CRL\'s reach');
    expect((laundered['stackedFrom'] as List).cast<String>(),
        contains(_signedKey),
        reason: 'and it must name the signed key whose 30 days it took');

    // The launch after. This is the half a unit test with a Map store cannot
    // make a claim about.
    await vip.load();
    await _settle(tester);

    final reloaded =
        vip.entries.firstWhere((e) => e.key == _rewardKey, orElse: () {
      fail('the reward entry must survive a reload from the real store');
    });
    expect(reloaded.stackedFrom, contains(_signedKey),
        reason: 'provenance lost on reload would mean the launder only costs '
            'the attacker one app restart');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
      'and a CRL published afterwards actually takes the laundered window '
      'back, on the real store', (tester) async {
    // Round-24 QC (reviewer A): the provenance assertions above stop one layer
    // short of the outcome the finding is about. This one runs the whole thing
    // — mint a real CRL, hand it to the real `refreshRevocationList`, and check
    // the clamp reaches the window that was moved into `WATCH_AD`.
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    await vip.revokeAll();
    await _settle(tester);

    final ed = Ed25519();
    final kp = await ed.newKeyPair();
    final pub =
        base64Url.encode((await kp.extractPublicKey()).bytes);

    await vip.addVip(key: _signedKey, duration: const Duration(days: 30));
    await _settle(tester);
    await vip.addVip(
        key: _rewardKey, duration: const Duration(days: 1), stack: true);
    await _settle(tester);

    final laundered = vip.expiresAt!;
    expect(laundered.difference(DateTime.now()).inDays, greaterThan(25),
        reason: 'sanity — the reward entry is holding the signed key\'s month');

    // The publisher revokes the signed key: leaked, refunded, or resold.
    final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = utf8.encode('$issuedAt|$_kid');
    final sig = await ed.sign(utf8.encode('CRL1|') + payload, keyPair: kp);
    final crl = 'CRL1.${base64Url.encode(payload)}.'
        '${base64Url.encode(sig.bytes)}';

    await vip.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _StaticCrl(crl),
    );
    await _settle(tester);

    final after = vip.expiresAt;
    expect(after == null || after.difference(DateTime.now()).inDays < 25, isTrue,
        reason: 'THE finding, end to end — one tap on "watch an ad" must not '
            'put a revoked key\'s month beyond the CRL\'s reach. Remaining: '
            '${after?.difference(DateTime.now())}');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('CONTROL — a non-stacked grant carries no provenance',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final store = VipEntriesStore(await AdPreferences.getInstance());

    await vip.revokeAll();
    await _settle(tester);

    await vip.addVip(key: _signedKey, duration: const Duration(days: 30));
    await _settle(tester);

    final rows = (jsonDecode((await store.getRaw())!) as List)
        .cast<Map<String, dynamic>>();
    final plain = rows.firstWhere((r) => r['key'] == _signedKey);
    expect(plain.containsKey('stackedFrom'), isFalse,
        reason: 'an ordinary grant absorbed nothing, and writing an empty set '
            'on every row would bloat the record for no reason');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
