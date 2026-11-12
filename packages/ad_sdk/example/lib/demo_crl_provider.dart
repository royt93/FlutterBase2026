import 'dart:convert' show utf8;
import 'dart:io' show HttpClient;

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';

/// URL of a signed CRL (`CRL1.<payload>.<signature>` from `tool/vip_crl_mint.dart`).
/// Pass `--dart-define=VIP_CRL_URL=https://example.com/vip_crl.txt`. Empty (the
/// default) keeps the demo button a harmless no-op.
const String kDemoCrlUrl = String.fromEnvironment('VIP_CRL_URL');

/// Demo [VipRevocationProvider]: one HTTPS GET of [url].
///
/// A real host ships its own provider (see [VipRevocationProvider]'s doc). The
/// SDK verifies the CRL signature itself, so TLS here is transport hygiene, not
/// the trust anchor. Returning `null` or throwing are both safe: the SDK
/// fail-opens and keeps whatever CRL it had cached.
///
/// Plain `http` is refused unless [allowInsecureHttp] is set; on Android it
/// also needs `usesCleartextTraffic`, which this example deliberately does not
/// enable.
class DemoCrlProvider implements VipRevocationProvider {
  DemoCrlProvider({
    this.url = kDemoCrlUrl,
    this.allowInsecureHttp = false,
    this.timeout = const Duration(seconds: 8),
  });

  final String url;
  final bool allowInsecureHttp;
  final Duration timeout;

  @override
  Future<String?> fetchSignedCrl() async {
    if (url.isEmpty) {
      debugPrint(
        '[example] fetchSignedCrl: no VIP_CRL_URL configured — '
        'revocation refresh is a no-op (see demo_crl_provider.dart)',
      );
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'https' ||
            (uri.scheme == 'http' && allowInsecureHttp))) {
      debugPrint('[example] fetchSignedCrl: refusing non-HTTPS CRL URL');
      return null;
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        debugPrint('[example] fetchSignedCrl: HTTP ${response.statusCode}');
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return body.trim();
    } finally {
      client.close(force: true);
    }
  }
}
