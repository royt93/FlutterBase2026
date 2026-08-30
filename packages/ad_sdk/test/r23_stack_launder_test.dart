// Round-23 QC (reviewer C, MAJOR) — stacking must not launder a revoked key's
// window out of the CRL's reach.
//
// `addVip(stack: true)` extends from the latest expiry across ALL live entries,
// which is the documented, deliberate product behaviour ("grants stack
// globally"). The consequence nobody had closed: redeem a signed 30-day key,
// then watch one rewarded ad for "+1 day", and the whole 30 days moves into a
// `WATCH_AD` entry. `_clampRevokedEntries` matches entry keys against
// `SIGNED_<kid>`, so publishing a CRL for that key afterwards — leaked,
// refunded, resold — clamped a row that no longer held the time, and the user
// kept the month.
//
// One tap. No root, no clock tampering, no tooling: the SDK's own reward button.
//
// The fix records what a stacked grant absorbed, transitively, and the clamp
// matches on that too.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
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

class _FakeRevocationProvider implements VipRevocationProvider {
  _FakeRevocationProvider(this._code);
  final String? _code;
  @override
  Future<String?> fetchSignedCrl() async => _code;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ed = Ed25519();

  Future<String> pubB64(SimpleKeyPair kp) async =>
      base64Url.encode((await kp.extractPublicKey()).bytes);

  Future<String> mintCrl(SimpleKeyPair kp,
      {required int issuedAtEpoch, required List<String> kids}) async {
    final payload = utf8.encode('$issuedAtEpoch|${kids.join(',')}');
    final sig =
        await ed.sign(utf8.encode('CRL1|') + payload, keyPair: kp);
    return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  Future<String> mintVipKey(SimpleKeyPair kp,
      {required int seconds, required String kid}) async {
    final expiresAt = DateTime.now()
            .toUtc()
            .add(const Duration(days: 400))
            .millisecondsSinceEpoch ~/
        1000;
    final payload = utf8.encode('$seconds|$kid|$expiresAt|');
    final sig = await ed.sign(payload, keyPair: kp);
    return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  const thirtyDays = 30 * 24 * 3600;

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    await prefs
        .setVipMaxObservedClockMs(DateTime.now().millisecondsSinceEpoch);
  });

  Duration remaining(VipManager m) =>
      m.expiresAt!.difference(DateTime.now());

  test('a rewarded-ad stack cannot carry a revoked 30-day key out of reach',
      () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // 1. Customer redeems a genuine 30-day key.
    final redeem = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: thirtyDays, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );
    expect(redeem.ok, isTrue);
    expect(remaining(mgr).inDays, greaterThan(28));

    // 2. ...then taps the SDK's own "watch an ad for +1 day" button, once.
    await mgr.addVip(
        key: 'WATCH_AD', duration: const Duration(days: 1), stack: true);
    expect(remaining(mgr).inDays, greaterThan(29),
        reason: 'sanity — global stacking is the intended product behaviour');

    // 3. The publisher refunds the purchase and revokes the key.
    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );

    // THE finding: the month has to go, wherever it currently lives.
    expect(remaining(mgr).inDays, lessThan(2),
        reason: 'the WATCH_AD row absorbed the revoked key\'s window — the '
            'clamp has to reach it, or a refund costs the publisher a month '
            'of suppressed ads for free');
  });

  // Round-38 QC (reviewer B, MAJOR) — a THIRD `VipEntry` rebuild site fix 2
  // had not reached: `addVip`'s plain, non-stacked "latest expiry wins"
  // replace under the SAME key. No `stack: true` involved in this second
  // call at all — just an ordinary host re-grant that happens to reuse a key
  // that had previously absorbed a stacked signed grant.
  test(
      'a later non-stacked re-grant on the SAME key must not launder it '
      'either', () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    final redeem = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: thirtyDays, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );
    expect(redeem.ok, isTrue);

    // The reward stack absorbs the 30 days into WATCH_AD, exactly as above.
    await mgr.addVip(
        key: 'WATCH_AD', duration: const Duration(days: 1), stack: true);
    expect(remaining(mgr).inDays, greaterThan(29), reason: 'sanity');

    // THE new step: an ordinary, non-stacked re-grant on the SAME key —
    // e.g. a host giving the account a fixed 60-day bonus under a key name
    // it reuses. `stack` defaults to false; no ad was watched this time.
    await mgr.addVip(key: 'WATCH_AD', duration: const Duration(days: 60));
    expect(remaining(mgr).inDays, greaterThan(58),
        reason: 'sanity — the later expiry replaces the row, as designed');

    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );

    expect(remaining(mgr).inDays, lessThan(2),
        reason: 'THE finding — the plain replace must not have discarded the '
            'provenance the row already carried, or the clamp has nothing '
            'left to match against');
  });

  test('chaining a second stack does not launder it again', () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: thirtyDays, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );
    await mgr.addVip(
        key: 'WATCH_AD', duration: const Duration(days: 1), stack: true);
    await mgr.addVip(
        key: 'PROMO', duration: const Duration(days: 1), stack: true);
    expect(remaining(mgr).inDays, greaterThan(30));

    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );

    expect(remaining(mgr).inDays, lessThan(2),
        reason: 'provenance is transitive — PROMO stacked onto WATCH_AD, which '
            'stacked onto the revoked key');
  });

  test('the clamp survives a restart — provenance is persisted', () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final first = VipManager(prefs, vipEntriesStore: store);
    await first.load();
    await first.redeemSignedKey(
      await mintVipKey(publisher, seconds: thirtyDays, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );
    await first.addVip(
        key: 'WATCH_AD', duration: const Duration(days: 1), stack: true);
    first.dispose();

    // Restart, then revoke. The provenance has to have made it to disk, or the
    // second session sees an ordinary WATCH_AD row holding a month.
    final second = VipManager(prefs, vipEntriesStore: store);
    await second.load();
    addTearDown(second.dispose);
    await second.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );

    expect(remaining(second).inDays, lessThan(2));
  });

  test('a clamped entry cannot be re-laundered by stacking onto it again',
      () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: thirtyDays, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );
    await mgr.addVip(
        key: 'WATCH_AD', duration: const Duration(days: 1), stack: true);
    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );
    expect(remaining(mgr).inDays, lessThan(2));

    // The clamped row is still live (grace window), so it is still the highest
    // expiry — stacking onto it moves whatever it holds into the new row. If
    // the clamp had dropped the provenance, the next idempotent clamp would
    // find nothing to match and the user renews the grace window forever, one
    // tap a day.
    await mgr.addVip(
        key: 'WATCH_AD_2', duration: const Duration(days: 1), stack: true);
    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1760000000, kids: ['REFUNDME'])),
    );

    expect(remaining(mgr).inDays, lessThan(2),
        reason: 'the clamp is idempotent and must stay reachable across '
            'repeated stacks, or it buys the user one day per tap forever');
  });

  test('CONTROL — an unrelated grant is untouched by the clamp', () async {
    final publisher = await ed.newKeyPair();
    final pub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // Not stacked: an independent 30-day promo standing on its own.
    await mgr.addVip(key: 'PROMO', duration: const Duration(days: 30));
    await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 3600, kid: 'REFUNDME'),
      publicKeyBase64: pub,
    );

    await mgr.refreshRevocationList(
      publicKeyBase64: pub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: 1750000000, kids: ['REFUNDME'])),
    );

    expect(remaining(mgr).inDays, greaterThan(28),
        reason: 'clamping by provenance must not reach a grant that never '
            'absorbed the revoked window — that would be the publisher taking '
            'back something the customer paid for separately');
  });

  test('CONTROL — old rows without provenance still load and stay valid',
      () async {
    // A row written by <= 2.3.x: no `stackedFrom` field at all.
    final legacy = jsonEncode([
      {
        'key': 'LEGACY',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 10))
            .toIso8601String(),
        'grantedAt': DateTime.now().toUtc().toIso8601String(),
      }
    ]);
    await store.setRaw(legacy);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    expect(mgr.isActive, isTrue,
        reason: 'an unknown-field-free legacy row must not be read as corrupt');
    expect(remaining(mgr).inDays, greaterThan(8));
  });
}
