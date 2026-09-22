// Round-25 QC round 15 — the on-device VIP finding.
//
// `connection_notifier`'s FIRST snapshot after process start can report
// "offline" on a phone that is demonstrably online (3 of 36 launches on an
// OPPO CPH1989 that pinged 8.8.8.8 fine throughout). `redeemSignedKey`
// consulted that single read, so a genuine key was rejected — and the shipped
// `VipRedeemScreen` told the user it was "invalid or expired", because
// "no network" and "bad key" share one `VipRedeemStatus.invalid` value.
//
// Two fixes pinned here:
//   1. unit — a false first read is re-polled for up to 2s, so the redeem goes
//      through; a genuinely offline device still gets rejected.
//   2. widget — the offline rejection carries `isOffline`, and the screen
//      shows the "connect and try again" message instead of "invalid key".

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ed = Ed25519();

/// In-memory fake so VIP tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

Future<String> _pubB64(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

// AVP2, not AVP1 — round 72 gated AVP1 behind `allowLegacyV1` (default
// false); this file tests the connectivity-poll/offline flag, not
// key-format legacy support, so it mints the currently-accepted-by-default
// format.
Future<String> _mint(SimpleKeyPair kp,
    {required int seconds, required String kid}) async {
  final farFuture = DateTime.now().add(const Duration(days: 3650));
  final payload = utf8
      .encode('$seconds|$kid|${farFuture.millisecondsSinceEpoch ~/ 1000}|');
  final sig = await _ed.sign(payload, keyPair: kp);
  return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;
  late String pub;
  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    keyPair = await _ed.newKeyPair();
    pub = await _pubB64(keyPair);
  });

  tearDown(() => AdManager().debugVipManager = null);

  group('a false first connectivity read no longer sinks a good key', () {
    test('the redeem succeeds once connectivity settles to online', () async {
      // Exactly the observed device behaviour: the first read says offline,
      // every read after it says online.
      var reads = 0;
      final mgr = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => reads++ > 0);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await _mint(keyPair, seconds: 7200, kid: 'settles-online');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(r.ok, isTrue,
          reason: 'a single false read from the connectivity plugin must not '
              'reject a genuine key — poll, then decide');
      expect(r.status, VipRedeemStatus.success);
      expect(r.isOffline, isFalse);
      expect(mgr.isActive, isTrue);
      expect(reads, greaterThan(1),
          reason: 'control — the gate must actually re-read, not just pass '
              'because the first read was lucky');
    });

    test('a genuinely offline device is still rejected, and says why',
        () async {
      final mgr = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => false);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await _mint(keyPair, seconds: 7200, kid: 'really-offline');
      final started = DateTime.now();
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      final elapsed = DateTime.now().difference(started);

      expect(r.ok, isFalse);
      expect(r.status, VipRedeemStatus.invalid,
          reason: 'deliberately NOT a new enum value — adding one to an '
              'exported enum breaks every host with an exhaustive switch');
      expect(r.isOffline, isTrue,
          reason: 'the flag is what lets a host tell "no network" apart from '
              '"bad key" while the status stays the same');
      expect(mgr.isActive, isFalse);
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(1500),
          reason: 'the poll window must actually be waited out');
      expect(elapsed.inSeconds, lessThan(5),
          reason: 'and must not hang the caller either');

      // The product rule is unchanged: the key itself was never consumed, so
      // it still works once the device is back online.
      final online = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => true);
      await online.load();
      addTearDown(online.dispose);
      expect((await online.redeemSignedKey(code, publicKeyBase64: pub)).ok,
          isTrue);
    });

    test('a truly invalid key is not reported as an offline failure', () async {
      final mgr = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => true);
      await mgr.load();
      addTearDown(mgr.dispose);

      final r = await mgr.redeemSignedKey('not-a-real-key',
          publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.invalid);
      expect(r.isOffline, isFalse,
          reason: 'control — the flag must be specific to the network gate');
    });
  });

  testWidgets(
      'the shipped redeem screen shows the offline message, not '
      '"invalid or expired", when there is no network', (tester) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final vip = VipManager(prefs,
        vipEntriesStore: store, isConnectedCheck: () => false);
    await vip.load();
    addTearDown(vip.dispose);
    AdManager().debugVipManager = vip;

    final code = await _mint(keyPair, seconds: 7200, kid: 'screen-offline');

    await tester
        .pumpWidget(MaterialApp(home: VipRedeemScreen(publicKeyBase64: pub)));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    await tester.tap(find.text('ACTIVATE'));
    // The connectivity poll waits on `Future.delayed`, which is a VIRTUAL
    // timer inside `testWidgets` — only `pump(duration)` advances it. The
    // SharedPreferences round trip, in contrast, needs a real event-loop turn
    // (`runAsync`). The offline path needs both, in this order.
    await tester.pump(const Duration(seconds: 3));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(
        find.text('No internet connection. Connect and try again — your key '
            'is still valid.'),
        findsOneWidget);
    expect(find.text('The VIP key you entered is invalid or expired.'),
        findsNothing,
        reason: 'the whole point of the fix — a good key must never be '
            'reported as invalid because the radio blinked');
    expect(find.text('VIP ACTIVE'), findsNothing);
    expect(find.text(code), findsOneWidget,
        reason: 'the field keeps the key so the user can just retry');
    expect(tester.takeException(), isNull);
  });
}
