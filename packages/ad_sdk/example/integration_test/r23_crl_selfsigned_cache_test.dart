// On-device integration test for round-23 MAJOR V3 — a cached CRL that nobody
// trustworthy vouched for must not be able to lock out every real CRL.
//
// The finding: `VipManager.load()` has no host public key of its own, so it
// verified the cached revocation list against a key stored beside it in the
// same plaintext preferences record. That is self-attesting. Anyone who can
// write preferences — a rooted device, i.e. exactly the population that redeems
// a leaked, refunded or resold key — mints their own Ed25519 pair, signs an
// empty CRL dated in 2286, writes both, and the "only accept a newer issuedAt"
// rule then rejects every CRL the publisher will ever issue. Revocation is
// permanently dead on that device.
//
// Round-24 QC (reviewer A) asked for this on-device: the whole attack is
// "someone else wrote our preferences", so the claim is only worth what the
// REAL `SharedPreferences` plugin makes of it. The unit test
// (`packages/ad_sdk/test/r23_crl_selfsigned_cache_test.dart`) runs against a
// mock preference map, which is the one place an attacker cannot reach.
//
// Run with:
//   flutter test integration_test/r23_crl_selfsigned_cache_test.dart -d <device-id>

import 'dart:convert';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:cryptography/cryptography.dart';
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

class _StaticCrl implements VipRevocationProvider {
  _StaticCrl(this._crl);
  final String _crl;
  @override
  Future<String?> fetchSignedCrl() async => _crl;
}

final _ed = Ed25519();

Future<String> _pub(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mintCrl(SimpleKeyPair kp,
    {required int issuedAtEpoch, required List<String> kids}) async {
  final payload = utf8.encode('$issuedAtEpoch|${kids.join(',')}');
  final sig = await _ed.sign(utf8.encode('CRL1|') + payload, keyPair: kp);
  return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

Future<String> _mintKey(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(days: 400))
          .millisecondsSinceEpoch ~/
      1000;
  final payload = utf8.encode('$seconds|$kid|$expiresAt|');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a self-signed future-dated cache written into the REAL preferences '
      'cannot wedge revocation off', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final prefs = await AdPreferences.getInstance();

    final publisher = await _ed.newKeyPair();
    final publisherPub = await _pub(publisher);
    final attacker = await _ed.newKeyPair();
    final attackerPub = await _pub(attacker);

    // The attack, written through the real plugin: an empty CRL dated in 2286,
    // signed by a key the attacker made up, stored with its own public key
    // beside it so that it verifies against itself.
    await prefs.setVipRevocationCache(
      raw: await _mintCrl(attacker, issuedAtEpoch: 9999999999, kids: const []),
      publicKey: attackerPub,
    );

    // A fresh session reads that cache at startup — the path with no host key.
    final mgr = VipManager(prefs);
    await mgr.load();
    addTearDown(mgr.dispose);
    await _settle(tester);

    // The publisher then does the one thing this is all for: revokes a key.
    // Its issuedAt is "now", i.e. older than 2286.
    await mgr.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _StaticCrl(await _mintCrl(publisher,
          issuedAtEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kids: const ['DEVICEKID'])),
    );
    await _settle(tester);

    final result = await mgr.redeemSignedKey(
      await _mintKey(publisher, seconds: 86400, kid: 'DEVICEKID'),
      publicKeyBase64: publisherPub,
    );

    expect(result.ok, isFalse,
        reason: 'THE finding — if the forged 2286 cache latched, this revoked '
            'key would be redeemable forever on this device and no CRL the '
            'publisher ever issues could take it back');

    await mgr.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
      'CONTROL — a cache the host key actually verifies still refuses a '
      'replayed older CRL', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final prefs = await AdPreferences.getInstance();
    final publisher = await _ed.newKeyPair();
    final publisherPub = await _pub(publisher);

    // Session 1 caches a genuine CRL through the normal path.
    final first = VipManager(prefs);
    await first.load();
    await first.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _StaticCrl(
          await _mintCrl(publisher, issuedAtEpoch: 1750000000, kids: ['B'])),
    );
    first.dispose();
    await _settle(tester);

    // Session 2 reads it back off the real device store and is then handed a
    // replayed, older, empty CRL. Fail-open must not mean fail-forgetful.
    final second = VipManager(prefs);
    await second.load();
    addTearDown(second.dispose);
    await second.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _StaticCrl(await _mintCrl(publisher,
          issuedAtEpoch: 1700000000, kids: const [])),
    );
    await _settle(tester);

    final result = await second.redeemSignedKey(
      await _mintKey(publisher, seconds: 86400, kid: 'B'),
      publicKeyBase64: publisherPub,
    );
    expect(result.ok, isFalse,
        reason: 'across a real restart, a genuinely cached CRL must still '
            'refuse a replayed older one');

    await second.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
