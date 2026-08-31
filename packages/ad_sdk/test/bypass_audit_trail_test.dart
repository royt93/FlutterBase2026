// T128 — flagship proof-of-compliance: a bounded ring buffer of every real
// bypassSafety/bypassVipGuard call, exportable as a signed bundle,
// replayable entirely locally via tool/bypass_audit_replay.dart. This file
// tests the same pure logic that tool exercises, without going through a
// file/process, plus the AdManager wiring that records real calls.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BypassAuditTrail ring buffer', () {
    test('records kind/callSiteTag/type, newest last', () {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassVipGuard',
          callSiteTag: 'vip_extend_screen',
          type: AdSlotType.rewarded);

      expect(trail.entries, hasLength(2));
      expect(trail.entries.first.kind, 'bypassSafety');
      expect(trail.entries.first.callSiteTag, 'splash_app_open');
      expect(trail.entries.first.type, 'appOpen');
      expect(trail.entries.last.kind, 'bypassVipGuard');
    });

    test('drops the oldest entry past maxEntries', () {
      final trail = BypassAuditTrail(maxEntries: 2);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'b', type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'c', type: AdSlotType.appOpen);

      expect(trail.entries, hasLength(2));
      expect(trail.entries.map((e) => e.callSiteTag), ['b', 'c']);
    });

    test('clear() empties the buffer', () {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      trail.clear();
      expect(trail.entries, isEmpty);
    });
  });

  group('signBypassAuditTrail (Ed25519, reuses compliance-signing infra)',
      () {
    test('a signed trail verifies via verifySignedJsonPayload', () async {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);

      final signed = await signBypassAuditTrail(trail);
      final envelopeJson = signed.toJsonString();

      expect(await verifySignedJsonPayload(envelopeJson), isTrue);
      expect(signed.payloadJson, contains('splash_app_open'));
    });

    test('a tampered payload fails verification', () async {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);
      final signed = await signBypassAuditTrail(trail);

      final tampered = SignedPayload(
        payloadJson:
            signed.payloadJson.replaceFirst('splash_app_open', 'forged_site'),
        publicKeyBase64: signed.publicKeyBase64,
        signatureBase64: signed.signatureBase64,
      );

      expect(await verifySignedJsonPayload(tampered.toJsonString()), isFalse);
    });
  });

  group('AdManager wiring', () {
    tearDown(() => AdManager().bypassAuditTrail.clear());

    test('showAppOpenAd(bypassSafety: true) records a bypassSafety entry',
        () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showAppOpenAd(
        onAdDismiss: (_) {},
        bypassSafety: true,
        callSiteTag: 'test_splash',
      );

      final entries = AdManager()
          .bypassAuditTrail
          .entries
          .where((e) => e.callSiteTag == 'test_splash');
      expect(entries, hasLength(1));
      expect(entries.single.kind, 'bypassSafety');
      expect(entries.single.type, 'appOpen');
    });

    test('showAppOpenAd(bypassSafety: false) records nothing', () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showAppOpenAd(onAdDismiss: (_) {});
      expect(AdManager().bypassAuditTrail.entries, isEmpty);
    });

    test(
        'showRewardedAd(bypassVipGuard: true) records a bypassVipGuard entry',
        () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showRewardedAd(
        onEarnedReward: (_) {},
        bypassVipGuard: true,
        callSiteTag: 'test_vip_extend',
      );

      final entries = AdManager()
          .bypassAuditTrail
          .entries
          .where((e) => e.callSiteTag == 'test_vip_extend');
      expect(entries, hasLength(1));
      expect(entries.single.kind, 'bypassVipGuard');
      expect(entries.single.type, 'rewarded');
    });
  });
}
