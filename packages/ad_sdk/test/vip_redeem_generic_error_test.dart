// Round-38 audit regression (claude CLI independent review, MINOR):
// `VipManager.redeemSignedKey`'s generic `catch (e)` branch (guarding
// `verifySignedVipKey`, for anything that isn't a `VipKeyException`) used to
// return `SignedVipRedeemResult.invalid('$e')` — leaking a raw exception's
// `toString()` into the public API's `error` field. The bundled
// `VipRedeemScreen` never surfaces that field, but a consuming app building
// its own redeem UI directly against this API could display it verbatim to
// an end user.
//
// This IS reachable with real, if malformed, input: a VIP code whose
// signature segment decodes to something other than exactly 64 bytes (e.g.
// a code truncated/corrupted by a copy-paste mistake) makes the underlying
// `cryptography` package's Ed25519 `verify()` throw a raw `StateError`
// ("Ed25519 signature must be 64 bytes"), not a `VipKeyException` — proven
// directly against `verifySignedVipKey` below, then through the full
// `VipManager.redeemSignedKey` path.

import 'dart:convert';
import 'dart:typed_data';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes);

/// A syntactically valid AVP1 code (3 dot-separated base64url parts) whose
/// signature segment decodes to 5 bytes instead of the required 64 — the
/// shape a truncated copy-paste of a real code would produce.
final _truncatedSigCode =
    'AVP1.${_b64url(Uint8List.fromList(List.generate(20, (i) => i)))}.'
    '${_b64url(Uint8List.fromList(List.filled(5, 1)))}';

const _pub = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 32 zero bytes, b64

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'verifySignedVipKey: a signature segment of the wrong decoded length '
      'throws a raw (non-VipKeyException) error, proving the generic catch '
      'in redeemSignedKey is genuinely reachable, not dead code', () async {
    await expectLater(
      verifySignedVipKey(_truncatedSigCode, publicKeyBase64: _pub),
      throwsA(isNot(isA<VipKeyException>())),
    );
  });

  test(
      'redeemSignedKey: a malformed code that throws a raw error returns a '
      'fixed, user-safe message — never the raw exception text',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    final store = _FakeVipEntriesStore(prefs);
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    final result =
        await mgr.redeemSignedKey(_truncatedSigCode, publicKeyBase64: _pub);

    expect(result.ok, isFalse);
    expect(result.error, 'invalid key format',
        reason: 'must be the fixed, user-safe message — not a raw '
            'exception toString() leaked to a public API field');
    expect(result.error, isNot(contains('StateError')));
    expect(result.error, isNot(contains('Ed25519')));
  });
}
