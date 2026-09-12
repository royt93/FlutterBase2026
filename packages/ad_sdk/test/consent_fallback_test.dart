import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fallback is versioned and always conservative', () {
    final state = ConsentFallbackState.create(
      policyRevision: 'ump-v7',
      reason: ConsentFallbackReason.offline,
      now: DateTime.utc(2026, 1, 2),
    );
    final decoded = ConsentFallbackState.decode(state.encode());
    expect(decoded.policyRevision, 'ump-v7');
    expect(decoded.reason, ConsentFallbackReason.offline);
    expect(decoded.toJson()['schemaVersion'], 2);
    expect(decoded.toJson()['canRequestAds'], isFalse);
    expect(decoded.toJson()['personalizedAds'], isFalse);
  });

  test('legacy or unknown reason migrates safely', () {
    final state = ConsentFallbackState.decode(
        '{"policyRevision":"legacy","reason":"removed"}');
    expect(state.reason, ConsentFallbackReason.platformError);
    expect(
        state.recordedAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  });

  test('invalid fallback payload is rejected', () {
    expect(() => ConsentFallbackState.decode('[]'), throwsFormatException);
  });
}
