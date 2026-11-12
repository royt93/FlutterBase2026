// T273 — DemoCrlProvider branches: empty URL, scheme gate, 200, non-200,
// connection error. Uses a real loopback HttpServer (no external network).
// A thrown error is a valid result: VipManager.refreshRevocationList fails open.

import 'dart:io';

import 'package:ad_sdk_example/demo_crl_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late int hits;

  Future<void> serve(int status, String body) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    hits = 0;
    server.listen((req) async {
      hits++;
      req.response
        ..statusCode = status
        ..write(body);
      await req.response.close();
    });
  }

  tearDown(() async {
    await server.close(force: true);
  });

  test('empty URL returns null without any request', () async {
    await serve(200, 'CRL1.x.y');
    expect(await DemoCrlProvider(url: '').fetchSignedCrl(), isNull);
    expect(hits, 0);
  });

  test('plain http is refused by default, no request is made', () async {
    await serve(200, 'CRL1.x.y');
    final url = 'http://127.0.0.1:${server.port}/crl.txt';
    expect(await DemoCrlProvider(url: url).fetchSignedCrl(), isNull);
    expect(hits, 0);
  });

  test('unsupported scheme and garbage URL are refused', () async {
    await serve(200, 'CRL1.x.y');
    expect(
      await DemoCrlProvider(url: 'ftp://127.0.0.1/crl.txt').fetchSignedCrl(),
      isNull,
    );
    expect(await DemoCrlProvider(url: ':::not a url').fetchSignedCrl(), isNull);
    expect(hits, 0);
  });

  test(
    'http works only when allowInsecureHttp is set; body is trimmed',
    () async {
      await serve(200, '  CRL1.payload.sig \n');
      final url = 'http://127.0.0.1:${server.port}/crl.txt';
      final got = await DemoCrlProvider(
        url: url,
        allowInsecureHttp: true,
      ).fetchSignedCrl();
      expect(got, 'CRL1.payload.sig');
      expect(hits, 1);
    },
  );

  test('non-200 status returns null', () async {
    await serve(404, 'nope');
    final url = 'http://127.0.0.1:${server.port}/crl.txt';
    expect(
      await DemoCrlProvider(url: url, allowInsecureHttp: true).fetchSignedCrl(),
      isNull,
    );
    expect(hits, 1);
  });

  test('connection failure throws (SDK fail-opens on a throw)', () async {
    await serve(200, 'x');
    final port = server.port;
    await server.close(force: true);
    // Rebind a fresh server so tearDown always has a live one to close; the
    // port captured above is now free, so connecting to it is refused.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:$port/crl.txt';
    await expectLater(
      DemoCrlProvider(
        url: url,
        allowInsecureHttp: true,
        timeout: const Duration(seconds: 2),
      ).fetchSignedCrl(),
      throwsA(isA<Exception>()),
    );
  });
}
