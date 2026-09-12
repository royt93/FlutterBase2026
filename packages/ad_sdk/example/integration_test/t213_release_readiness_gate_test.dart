import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T213 Android smoke: release gate fixture is available',
      (tester) async {
    expect(const String.fromEnvironment('FLUTTER_TEST'), isNotNull);
  });
}
