// Round-25 QC round 18 — a paid VIP key must never be burned by a teardown.
//
// `redeemSignedKey` checks `_disposed` at the top, but that check does not
// survive the awaits that follow (the ~2s connectivity poll added in round 15,
// `PackageInfo` for AVP2, the cached-CRL load, and `addVip`'s own `_save()`).
// If the host tears the SDK down inside any of those windows, `_save()`
// correctly DROPS the grant (a discarded manager must not write over the store
// its replacement owns) while `addRedeemedVipKeyId` / `markRedeemed` happily
// burned the kid anyway — on iOS into the Keychain, surviving a reinstall.
//
// Real consequence: the customer pays for a key, the screen says "success",
// the next launch has no VIP, and re-entering the key says "already used".
//
// The two re-checks under test refuse to burn a key whose grant was not
// persisted, so the customer just taps ACTIVATE again.
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_redeemed_key_ledger.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ed = Ed25519();

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  int writes = 0;

  /// Runs on the first write only — the hook that lets a test drop a teardown
  /// exactly between the grant and the burn.
  void Function()? onFirstWrite;

  @override
  Future<String?> getRaw() async => _raw;

  @override
  Future<void> setRaw(String json) async {
    writes++;
    _raw = json;
    final hook = onFirstWrite;
    onFirstWrite = null;
    hook?.call();
  }
}

class _FakeLedger extends RedeemedKeyLedger {
  final Set<String> redeemed = <String>{};

  @override
  Future<bool> isRedeemed(String kid) async => redeemed.contains(kid);

  @override
  Future<void> markRedeemed(String kid) async => redeemed.add(kid);
}

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mint(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final payload = utf8.encode('$seconds|$kid');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;
  late String pub;
  late AdPreferences prefs;
  late _FakeVipEntriesStore store;
  late _FakeLedger ledger;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdPreferences.resetForTest();
    VipManager.resetSaveQueueForTest();
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    ledger = _FakeLedger();
    keyPair = await _ed.newKeyPair();
    pub = await _pubB64(keyPair);
  });

  tearDown(() => AdManager().debugVipManager = null);

  /// The replacement manager a real host builds on re-init — same prefs, same
  /// store, same durable ledger.
  Future<VipManager> replacement() async {
    final mgr = VipManager(prefs,
        vipEntriesStore: store,
        redeemedKeyLedger: ledger,
        isConnectedCheck: () => true);
    await mgr.load();
    addTearDown(mgr.dispose);
    return mgr;
  }

  group('a teardown mid-redeem must not consume the key', () {
    test('dispose() during the connectivity poll leaves the key redeemable',
        () async {
      // First read offline (the observed device behaviour), every read after it
      // online — so the redeem is inside `_waitForConnectivity` when the
      // teardown lands, exactly the window round 15 widened to ~2s.
      var reads = 0;
      final dying = VipManager(prefs,
          vipEntriesStore: store,
          redeemedKeyLedger: ledger,
          isConnectedCheck: () => reads++ > 0);
      await dying.load();

      final code = await _mint(keyPair, seconds: 3600, kid: 'poll-teardown');
      final inFlight = dying.redeemSignedKey(code, publicKeyBase64: pub);
      dying.dispose();
      final result = await inFlight;

      expect(result.ok, isFalse,
          reason: 'reporting success is the actual harm: the host tells the '
              'customer they are VIP while nothing was persisted');
      expect(prefs.isVipKeyIdRedeemed('poll-teardown'), isFalse,
          reason: 'the SharedPreferences ledger must not hold a key whose '
              'grant was dropped');
      expect(ledger.redeemed, isNot(contains('poll-teardown')),
          reason: 'the durable (iOS Keychain) ledger is the unforgiving one — '
              'a burn here survives an uninstall');

      // What the customer actually does next: the SDK comes back, they tap
      // ACTIVATE again.
      final retry = await (await replacement())
          .redeemSignedKey(code, publicKeyBase64: pub);
      expect(retry.status, VipRedeemStatus.success,
          reason: 'the paid key must still be worth what they paid');
    });

    test('dispose() landing between the grant and the burn leaves it redeemable',
        () async {
      // The narrower window: connectivity is fine, but `addVip` awaits its own
      // `_save()`, and the host tears down inside that write.
      final dying = VipManager(prefs,
          vipEntriesStore: store,
          redeemedKeyLedger: ledger,
          isConnectedCheck: () => true);
      await dying.load();
      store.onFirstWrite = dying.dispose;

      final code = await _mint(keyPair, seconds: 3600, kid: 'grant-teardown');
      final result = await dying.redeemSignedKey(code, publicKeyBase64: pub);

      expect(result.ok, isFalse);
      expect(prefs.isVipKeyIdRedeemed('grant-teardown'), isFalse);
      expect(ledger.redeemed, isNot(contains('grant-teardown')));

      final retry = await (await replacement())
          .redeemSignedKey(code, publicKeyBase64: pub);
      expect(retry.status, VipRedeemStatus.success);
    });

    test('CONTROL — an undisturbed redeem still burns the key exactly once',
        () async {
      // Without this, the two tests above would pass just as happily if the
      // "fix" had simply stopped the SDK from ever marking a key used, which
      // would hand every customer an infinitely reusable key.
      final mgr = await replacement();

      final code = await _mint(keyPair, seconds: 3600, kid: 'healthy');
      final first = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(first.status, VipRedeemStatus.success);
      expect(mgr.isActive, isTrue);
      expect(prefs.isVipKeyIdRedeemed('healthy'), isTrue);
      expect(ledger.redeemed, contains('healthy'));

      final replay = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(replay.status, VipRedeemStatus.alreadyUsed,
          reason: 'single-use enforcement must be untouched by the fix');
    });
  });
}
