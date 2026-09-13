// T96 — Flagship: cryptographically-signed compliance report export.
//
// signComplianceReport signs the report's exact exported JSON with an
// on-device Ed25519 key (minted + persisted on first use), and
// verifySignedComplianceReportJson checks that signature. This is
// tamper-evidence for a dispute appeal (the exported bytes weren't hand-
// edited after the SDK produced them), not non-repudiation — see the class
// doc comment in compliance_signing.dart for the exact threat model.

import 'dart:convert';

import 'package:applovin_admob_sdk/src/compliance/compliance_report.dart';
import 'package:applovin_admob_sdk/src/compliance/compliance_signing.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/core/ad_safety_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory fake so tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel — mirrors this suite's existing
/// `_FakeVipEntriesStore`/`_FakeRedeemedKeyLedger` pattern.
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
}

void main() {
  const snapshot = AdSafetySnapshot(
    fullscreenAdsShownInSession: 2,
    maxFullscreenAdsPerSession: 6,
    hourlyAdCount: 1,
    maxFullscreenAdsPerHour: 3,
    dailyAdCount: 4,
    maxFullscreenAdsPerDay: 5,
    clickThroughRate: 0.1,
    fullscreenClickThroughRate: 0.1,
    suspiciousCtrThreshold: 0.3,
    clicksLastMinute: 0,
    suspiciousViolationCount: 0,
    isSuspended: false,
    dryRun: false,
  );

  ComplianceReport report({int eventCount = 1}) => ComplianceReport.generate(
        events: List.generate(
            eventCount, (i) => {'kind': 'ad_event', 'timestampMs': i}),
        safety: snapshot,
        consent: ConsentSettings.accepted,
        vipActive: false,
        now: DateTime.utc(2026, 1, 1),
      );

  test('signs a report and the signature verifies', () async {
    final signed = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());
    final ok = await verifySignedComplianceReportJson(signed.toJsonString());
    expect(ok, isTrue);
  });

  test('reportJson round-trips to the exact same ComplianceReport JSON',
      () async {
    final r = report(eventCount: 3);
    final signed =
        await signComplianceReport(r, secureStorage: _FakeSecureStorage());
    expect(signed.reportJson, r.toJsonString());
  });

  test('two signs on the same storage reuse the same key (stable public key)',
      () async {
    final storage = _FakeSecureStorage();
    final first = await signComplianceReport(report(), secureStorage: storage);
    final second =
        await signComplianceReport(report(eventCount: 2), secureStorage: storage);
    expect(second.publicKeyBase64, first.publicKeyBase64);
  });

  // Round-23 audit, MINOR (independent review) — the missing `await` in
  // `_loadOrCreateKeyPair` had no test behind it, so the claim "every fix was
  // proven by reverting it" did not hold for that one. This is the test that
  // makes it hold: a stored seed that is valid base64 but the WRONG LENGTH is
  // rejected *asynchronously* by `newKeyPairFromSeed`, which is exactly the
  // failure an un-awaited return lets escape the surrounding try/catch. Revert
  // the `await` and this test throws instead of falling back to a fresh mint.
  test('a corrupt stored seed falls back to a freshly minted key', () async {
    final storage = _FakeSecureStorage();
    // 5 bytes — decodes fine, but Ed25519 seeds are 32.
    await storage.write(
        key: 'ad_sdk_compliance_signing_key_v1',
        value: base64Url.encode(List<int>.filled(5, 7)));

    final signed =
        await signComplianceReport(report(), secureStorage: storage);

    expect(await verifySignedComplianceReportJson(signed.toJsonString()),
        isTrue);
    // The bad seed was replaced, so a second export is stable rather than
    // re-minting on every call.
    final again = await signComplianceReport(report(), secureStorage: storage);
    expect(again.publicKeyBase64, signed.publicKeyBase64);
  });

  test('a fresh storage (simulated different device/install) mints a '
      'different key', () async {
    final a = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());
    final b = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());
    expect(a.publicKeyBase64, isNot(b.publicKeyBase64));
  });

  test('editing reportJson after export invalidates the signature',
      () async {
    final signed = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());
    final tampered = jsonDecode(signed.toJsonString()) as Map<String, dynamic>;
    tampered['reportJson'] =
        (tampered['reportJson'] as String).replaceFirst('"eventCount":1', '"eventCount":999');

    final ok = await verifySignedComplianceReportJson(jsonEncode(tampered));
    expect(ok, isFalse);
  });

  test('swapping in an attacker-controlled key pair + re-signature is '
      'the only way tampering could verify — a mismatched public key '
      'alone fails', () async {
    final signed = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());
    final other = await signComplianceReport(report(),
        secureStorage: _FakeSecureStorage());

    final swapped = jsonDecode(signed.toJsonString()) as Map<String, dynamic>;
    swapped['publicKeyBase64'] = other.publicKeyBase64;

    final ok = await verifySignedComplianceReportJson(jsonEncode(swapped));
    expect(ok, isFalse);
  });

  test('malformed bundle never throws, just fails to verify', () async {
    for (final bad in <String>[
      '{}',
      'not json',
      '{"reportJson": "x"}',
      '{"reportJson": "x", "publicKeyBase64": "AA==", "signatureBase64": "AA=="}',
    ]) {
      final ok = await verifySignedComplianceReportJson(bad);
      expect(ok, isFalse, reason: 'should reject "$bad"');
    }
  });
}
