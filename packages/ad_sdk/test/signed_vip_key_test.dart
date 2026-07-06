// T18 — offline signed VIP keys (Ed25519).
//
// Unit: verifySignedVipKey accepts genuine keys, rejects tampered / wrong-key /
// malformed ones. Integration: VipManager.redeemSignedKey grants VIP, enforces
// per-device one-time-use, stacks distinct keys. Widget: a redeem button drives
// the VIP state. Keys are minted in-test with an ephemeral key pair, so no
// private key is committed.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ed = Ed25519();

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mint(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final payload = utf8.encode('$seconds|$kid');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;
  late String pub;

  setUp(() async {
    keyPair = await _ed.newKeyPair();
    pub = await _pubB64(keyPair);
  });

  group('verifySignedVipKey', () {
    test('accepts a genuine key and decodes duration + kid', () async {
      final code = await _mint(keyPair, seconds: 3600, kid: 'abc123');
      final r = await verifySignedVipKey(code, publicKeyBase64: pub);
      expect(r.duration, const Duration(seconds: 3600));
      expect(r.keyId, 'abc123');
    });

    test('rejects a tampered payload', () async {
      final code = await _mint(keyPair, seconds: 3600, kid: 'abc123');
      final parts = code.split('.');
      // Re-encode a DIFFERENT payload (7200s) but keep the original signature.
      final forged =
          'AVP1.${base64Url.encode(utf8.encode('7200|abc123'))}.${parts[2]}';
      expect(
        () => verifySignedVipKey(forged, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('rejects a key signed by a different private key', () async {
      final other = await _ed.newKeyPair();
      final code = await _mint(other, seconds: 3600, kid: 'x');
      expect(
        () => verifySignedVipKey(code, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('rejects when verified against the wrong public key', () async {
      final code = await _mint(keyPair, seconds: 3600, kid: 'x');
      final otherPub = await _pubB64(await _ed.newKeyPair());
      expect(
        () => verifySignedVipKey(code, publicKeyBase64: otherPub),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('rejects malformed / wrong-prefix / garbage', () async {
      for (final bad in <String>[
        'not-a-key',
        'AVP1.only-two',
        'BADP.${base64Url.encode(utf8.encode('60|k'))}.AAAA',
        '',
      ]) {
        expect(
          () => verifySignedVipKey(bad, publicKeyBase64: pub),
          throwsA(isA<VipKeyException>()),
          reason: 'should reject "$bad"',
        );
      }
    });

    test('rejects non-positive duration', () async {
      final code = await _mint(keyPair, seconds: 0, kid: 'zero');
      expect(
        () => verifySignedVipKey(code, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
      );
    });
  });

  group('VipManager.redeemSignedKey', () {
    late AdPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      await VipManager(prefs).revokeAll();
    });

    test('valid key grants VIP', () async {
      final mgr = VipManager(prefs);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await _mint(keyPair, seconds: 7200, kid: 'grant1');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(r.ok, isTrue);
      expect(r.status, VipRedeemStatus.success);
      expect(mgr.isActive, isTrue);
      expect(r.entry, isNotNull);
    });

    test('same key id cannot be redeemed twice on this device', () async {
      final mgr = VipManager(prefs);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await _mint(keyPair, seconds: 3600, kid: 'once');
      final first = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      final second = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(first.ok, isTrue);
      expect(second.status, VipRedeemStatus.alreadyUsed);
    });

    test('distinct keys stack the VIP window', () async {
      final mgr = VipManager(prefs);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.redeemSignedKey(await _mint(keyPair, seconds: 3600, kid: 'a'),
          publicKeyBase64: pub);
      final afterFirst = mgr.expiresAt!;
      await mgr.redeemSignedKey(await _mint(keyPair, seconds: 3600, kid: 'b'),
          publicKeyBase64: pub, stack: true);
      final afterSecond = mgr.expiresAt!;

      expect(afterSecond.isAfter(afterFirst), isTrue,
          reason: 'second distinct key stacks onto the window');
    });

    test('concurrent double-redeem of the same key grants only once', () async {
      final mgr = VipManager(prefs);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await _mint(keyPair, seconds: 3600, kid: 'concurrent');
      // Fire both without awaiting the first (simulates a double-tap).
      final results = await Future.wait([
        mgr.redeemSignedKey(code, publicKeyBase64: pub),
        mgr.redeemSignedKey(code, publicKeyBase64: pub),
      ]);

      final successes = results.where((r) => r.ok).length;
      expect(successes, 1, reason: 'exactly one concurrent redeem may grant');
      expect(
          results.any((r) => r.status == VipRedeemStatus.alreadyUsed), isTrue,
          reason: 'the loser is rejected as already used');
    });

    test('invalid key does not grant VIP', () async {
      final mgr = VipManager(prefs);
      await mgr.load();
      addTearDown(mgr.dispose);

      final r = await mgr.redeemSignedKey('garbage', publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.invalid);
      expect(mgr.isActive, isFalse);
    });
  });

  group('widget: redeem button drives VIP state', () {
    testWidgets('tapping redeem with a valid key activates VIP',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await VipManager(prefs).revokeAll();
      final mgr = VipManager(prefs);
      await mgr.load();

      final code = await _mint(keyPair, seconds: 3600, kid: 'widget1');
      String status = 'none';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  Text('status:$status'),
                  ElevatedButton(
                    onPressed: () async {
                      final r =
                          await mgr.redeemSignedKey(code, publicKeyBase64: pub);
                      setState(() => status = r.status.name);
                    },
                    child: const Text('Redeem'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Redeem'));
      await tester.pumpAndSettle();

      expect(find.text('status:success'), findsOneWidget);
      expect(mgr.isActive, isTrue);

      // Cancel the entry-expiry Timer before the widget-binding invariant check.
      mgr.dispose();
    });
  });
}
