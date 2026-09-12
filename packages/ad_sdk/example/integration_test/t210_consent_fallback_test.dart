import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T210 Android smoke: fallback round-trips on device',
      (tester) async {
    final state = ConsentFallbackState.create(
      policyRevision: 'ump-v1',
      reason: ConsentFallbackReason.offline,
    );
    final decoded = ConsentFallbackState.decode(state.encode());
    expect(decoded.toJson()['canRequestAds'], isFalse);
    expect(decoded.toJson()['personalizedAds'], isFalse);
  });
}
