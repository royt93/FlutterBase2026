import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _ed = Ed25519();

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mintV2(
  SimpleKeyPair kp, {
  required int seconds,
  required String kid,
  String bundleId = '',
}) async {
  final expiresAt = DateTime.now().toUtc().add(const Duration(days: 1));
  final payload = utf8.encode(
    '$seconds|$kid|'
    '${expiresAt.millisecondsSinceEpoch ~/ 1000}|$bundleId',
  );
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

Future<String> _mintV1(
  SimpleKeyPair kp, {
  required int seconds,
  required String kid,
}) async {
  final payload = utf8.encode('$seconds|$kid');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'T220: verified owner decisions on physical device (AVP2, AVP1 opt-in, offline check, QA fleet, COPPA preview)',
    (tester) async {
      final prefs = await AdPreferences.getInstance();
      final keyPair = await _ed.newKeyPair();
      final pub = await _pubB64(keyPair);

      // 1. QA fleet hashes must remain present and non-empty on device
      expect(kQaTestDeviceHashes, isNotEmpty);
      expect(kQaTestDeviceHashes.length, greaterThanOrEqualTo(17));

      // 2. Pure consent simulation reflects COPPA child-directed without crash
      final childConsent = simulateConsentOutcome(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true),
        config: const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey:
                'test_sdk_key_86_chars_placeholder_123456789012345678901234567890123456789012345678901234',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
      );
      expect(childConsent.appLovinCoppaForwarded, isFalse);
      expect(childConsent.admobTagForChildDirectedTreatment, equals('yes'));

      // 3. Online redemption grants AVP2 on hardware
      final onlineMgr = VipManager(prefs, isConnectedCheck: () => true);
      await onlineMgr.load();
      await onlineMgr.revokeAll();
      await onlineMgr.clearRedeemedKeyLedgerForTest();

      final v2Code = await _mintV2(keyPair, seconds: 120, kid: 'device_v2');
      final v2Result = await onlineMgr.redeemSignedKey(
        v2Code,
        publicKeyBase64: pub,
      );
      expect(v2Result.ok, isTrue);
      expect(v2Result.status, equals(VipRedeemStatus.success));
      expect(onlineMgr.isActive, isTrue);

      // 4. Default rejects AVP1; allowLegacyV1: true accepts it on hardware
      final v1Code = await _mintV1(keyPair, seconds: 120, kid: 'device_v1');
      final v1DefaultResult = await onlineMgr.redeemSignedKey(
        v1Code,
        publicKeyBase64: pub,
      );
      expect(v1DefaultResult.ok, isFalse);
      expect(v1DefaultResult.status, equals(VipRedeemStatus.invalid));

      final v1OptInResult = await onlineMgr.redeemSignedKey(
        v1Code,
        publicKeyBase64: pub,
        allowLegacyV1: true,
      );
      expect(v1OptInResult.ok, isTrue);
      expect(v1OptInResult.status, equals(VipRedeemStatus.success));

      // 5. Offline redemption is rejected before key verify
      final offlineMgr = VipManager(prefs, isConnectedCheck: () => false);
      await offlineMgr.load();

      final freshV2 = await _mintV2(
        keyPair,
        seconds: 120,
        kid: 'device_v2_offline',
      );
      final offlineResult = await offlineMgr.redeemSignedKey(
        freshV2,
        publicKeyBase64: pub,
      );
      expect(offlineResult.ok, isFalse);
      expect(offlineResult.isOffline, isTrue);

      onlineMgr.dispose();
      offlineMgr.dispose();
    },
  );
}
