import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CLI source accepts file/stdin and rejects secret argv', () {
    final mint = File('tool/vip_mint.dart').readAsStringSync();
    final crl = File('tool/vip_crl_mint.dart').readAsStringSync();
    expect(mint, contains("opts['priv-file']"));
    expect(mint, contains("opts.containsKey('priv-stdin')"));
    expect(crl, contains("opts['priv-file']"));
    expect(crl, contains("opts.containsKey('priv-stdin')"));
    expect(mint, contains('--priv is disabled because argv is observable'));
    expect(crl, contains('--priv is disabled because argv is observable'));
  });

  test('keygen writes private value to file and does not print it', () {
    final keygen = File('tool/vip_keygen.dart').readAsStringSync();
    expect(keygen, contains("writeAsString(base64Url.encode(priv)"));
    expect(keygen, contains("Process.run('chmod', ['600'"));
    expect(keygen, isNot(contains('PRIVATE (KEEP SECRET')));
  });
}
