import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T209 Android smoke: export is bounded and verifiable',
      (tester) async {
    final encoded = await AdManager().exportSafeDiagnostics(maxBytes: 4096);
    expect(utf8.encode(encoded).length, lessThanOrEqualTo(4096));
    expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
  });
}
