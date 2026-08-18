// On-device integration test for the VIP key revocation list (CRL, T95).
//
// Distinct from vip_api_playground_test.dart (which drives the demo UI's
// buttons for a fixed embedded key pair): this calls
// VipManager.refreshRevocationList/redeemSignedKey directly with a
// self-contained, test-generated Ed25519 key pair, exactly like
// test/vip_revocation_test.dart's unit tests — the point here is only to
// confirm the SAME logic behaves correctly against REAL flutter_secure_storage
// / real SharedPreferences on-device, not fakes.
//
// Run with:
//   flutter test integration_test/vip_revocation_list_test.dart -d <device-or-sim-id>

import 'dart:convert';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// On a real device the splash flow can hit BOTH the real ATT system prompt
// AND a real UMP consent form before initialize() ever completes -- each
// has its own internal 20s timeout when nothing dismisses it headlessly (see
// AttConsent's `requestAttIfNeeded` / UmpConsent's dismiss-timeout log line),
// so worst case is ~40s of that alone before init even starts resolving.
// Budget well past that (same fix already applied in
// debug_overlay_doctor_test.dart -- 2026-08-18 fork-review: this file hit the
// tighter 30s window's real failure mode on-device).
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a revoked kid is rejected after refreshRevocationList persists a '
      'real signed CRL to on-device storage, and a clean kid still redeems',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await AdManager().vip!.revokeAll();
    await AdManager().vip!.clearRedeemedKeyLedgerForTest();
    await tester.pump();

    final ed = Ed25519();
    final keyPair = await ed.newKeyPair();
    final pub = base64Url.encode((await keyPair.extractPublicKey()).bytes);

    Future<String> mintVipKey(
        {required int seconds, required String kid}) async {
      final expiresAt = DateTime.now()
              .toUtc()
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch ~/
          1000;
      final payload = utf8.encode('$seconds|$kid|$expiresAt|');
      final sig = await ed.sign(payload, keyPair: keyPair);
      return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
    }

    Future<String> mintCrl(
        {required int issuedAtEpoch, required List<String> kids}) async {
      final payload = utf8.encode('$issuedAtEpoch|${kids.join(',')}');
      // Domain-separated: sign "CRL1|" + payload, not payload alone — see
      // signed_vip_key.dart's _crlSignedMessage doc comment for why.
      final signedMessage = utf8.encode('CRL1|') + payload;
      final sig = await ed.sign(signedMessage, keyPair: keyPair);
      return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
    }

    // Real device: refreshRevocationList persists via AdPreferences
    // (SharedPreferences-backed), the SAME storage every other on-device VIP
    // read/write already uses — this is the on-device write/re-read round
    // trip a unit test's mocked SharedPreferences can't fully stand in for.
    final crl = await mintCrl(
        issuedAtEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kids: ['device-revoked-kid']);
    await AdManager().vip!.refreshRevocationList(
          publicKeyBase64: pub,
          revocationProvider: _FixedCrlProvider(crl),
        );

    final revokedCode =
        await mintVipKey(seconds: 3600, kid: 'device-revoked-kid');
    final revokedResult = await AdManager()
        .vip!
        .redeemSignedKey(revokedCode, publicKeyBase64: pub);
    expect(revokedResult.status, VipRedeemStatus.invalid,
        reason: 'a kid on the just-persisted, real on-device CRL must be '
            'rejected');
    expect(AdManager().vip!.isActive, isFalse);

    final cleanCode = await mintVipKey(seconds: 3600, kid: 'device-clean-kid');
    final cleanResult =
        await AdManager().vip!.redeemSignedKey(cleanCode, publicKeyBase64: pub);
    expect(cleanResult.status, VipRedeemStatus.success,
        reason: 'a kid NOT on the CRL must still redeem normally');
    expect(AdManager().vip!.isActive, isTrue);
  });
}

class _FixedCrlProvider implements VipRevocationProvider {
  _FixedCrlProvider(this._code);
  final String _code;
  @override
  Future<String?> fetchSignedCrl() async => _code;
}
