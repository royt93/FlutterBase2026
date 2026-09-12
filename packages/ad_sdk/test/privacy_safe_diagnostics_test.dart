import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('safe export redacts secrets, includes schema/checksum, and verifies',
      () async {
    final diagnostics = AdDiagnostics(
      lastWaterfallBySlot: {
        AdSlotType.interstitial: const [
          'provider=admob vip_key=AVP1.secret idfa=ABC123',
        ],
      },
      fillRateBySlot: const {AdSlotType.interstitial: 0.5},
    );
    final encoded = await diagnostics.toSafeJsonString();
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(json['schemaVersion'], 1);
    expect(json['sha256'], isA<String>());
    expect(encoded, isNot(contains('AVP1.secret')));
    expect(encoded, isNot(contains('ABC123')));
    expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
  });

  test('tampering fails verification and large payloads stay bounded',
      () async {
    final diagnostics = AdDiagnostics(
      lastWaterfallBySlot: {
        AdSlotType.rewarded: List.filled(200, 'adapter-${'x' * 300}'),
      },
      fillRateBySlot: const {},
    );
    final encoded = await diagnostics.toSafeJsonString(maxBytes: 2048);
    expect(utf8.encode(encoded).length, lessThanOrEqualTo(2048));
    expect(jsonDecode(encoded)['truncated'], isTrue);
    expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
    final tampered = encoded.replaceFirst('"sha256":"', '"sha256":"tampered');
    expect(await AdDiagnostics.verifySafeJsonString(tampered), isFalse);
  });

  test('AdManager facade exports a valid empty snapshot', () async {
    final encoded = await AdManager().exportSafeDiagnostics(maxBytes: 1024);
    expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
  });
}
