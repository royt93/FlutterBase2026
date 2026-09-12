import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T214 Android smoke: invalid flags fail closed', (tester) async {
    final accepted = await AdManager().applySignedFeatureFlags(
      SignedFeatureFlags(
        revision: 1,
        expiresAt: DateTime.utc(2020),
        flags: const {'arbitrator': false},
        signatureBase64: '',
      ),
      publicKeyBase64: 'bad',
    );
    expect(accepted, isFalse);
  });
}
