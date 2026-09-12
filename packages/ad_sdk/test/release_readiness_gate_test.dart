import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release gate script declares every required stage', () {
    final script = File('tool/release_readiness_gate.sh').readAsStringSync();
    for (final stage in ['secret', 'api', 'size', 'dependency', 'all']) {
      expect(script, contains(stage));
    }
    expect(script, contains('2048'));
  });
}
