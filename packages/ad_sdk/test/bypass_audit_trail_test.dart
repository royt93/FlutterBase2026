// T128 — flagship proof-of-compliance: a bounded ring buffer of every real
// bypassSafety/bypassVipGuard call, exportable as a signed bundle,
// replayable entirely locally via tool/bypass_audit_replay.dart. This file
// tests the same pure logic that tool exercises, without going through a
// file/process, plus the AdManager wiring that records real calls.
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BypassAuditTrail ring buffer', () {
    test('records kind/callSiteTag/type, newest last', () {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassVipGuard',
          callSiteTag: 'vip_extend_screen',
          type: AdSlotType.rewarded);

      expect(trail.entries, hasLength(2));
      expect(trail.entries.first.kind, 'bypassSafety');
      expect(trail.entries.first.callSiteTag, 'splash_app_open');
      expect(trail.entries.first.type, 'appOpen');
      expect(trail.entries.last.kind, 'bypassVipGuard');
    });

    test('drops the oldest entry past maxEntries', () {
      final trail = BypassAuditTrail(maxEntries: 2);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'b', type: AdSlotType.appOpen);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'c', type: AdSlotType.appOpen);

      expect(trail.entries, hasLength(2));
      expect(trail.entries.map((e) => e.callSiteTag), ['b', 'c']);
    });

    test('clear() empties the buffer', () {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      trail.clear();
      expect(trail.entries, isEmpty);
    });
  });

  group('persistence (T155)', () {
    late AdPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      // AdPreferences.getInstance() caches its instance for the whole
      // process (see its own doc comment) — setMockInitialValues alone
      // doesn't reach an already-cached SharedPreferences' own in-memory
      // copy, so without this, tests after the first would silently keep
      // seeing entries persisted by earlier tests in this group. Mirrors
      // ad_event_log_test.dart's identical setUp.
      await prefs.clearAllData();
    });

    // The actual bug this task fixes: a process kill (routine on mobile)
    // used to erase every prior bypass, leaving only the current cold
    // start's own — worthless as "flagship proof-of-compliance" if a real
    // dispute needed history older than the app's current run.
    test(
        'a fresh trail attached to the same AdPreferences reloads entries a '
        'prior "process" already persisted', () async {
      final first = BypassAuditTrail();
      first.attach(prefs);
      first.record(
          kind: 'bypassSafety', callSiteTag: 'splash', type: AdSlotType.appOpen);
      await first.flush();

      final second = BypassAuditTrail();
      second.attach(prefs);
      expect(second.entries, hasLength(1));
      expect(second.entries.single.callSiteTag, 'splash');
      expect(second.entries.single.kind, 'bypassSafety');
    });

    test('not yet attached — record() stays in-memory only, no crash', () {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      expect(trail.entries, hasLength(1));
    });

    test('corrupt persisted JSON is discarded, not thrown', () async {
      await prefs.setBypassAuditTrailRaw('{not valid json');
      final trail = BypassAuditTrail();
      trail.attach(prefs);
      expect(trail.entries, isEmpty);
    });

    // Codex review (P2): a valid entry followed by a malformed one used to
    // leave the valid prefix actually inserted into _entries before the
    // malformed one threw — `.map(...)` is lazy, so insertAll(0, loaded)
    // consumed it entry-by-entry instead of all at once. The catch block's
    // log message claims the whole thing was discarded; it wasn't.
    test(
        'a valid entry followed by a malformed one discards the WHOLE list, '
        'not just the bad entry', () async {
      await prefs.setBypassAuditTrailRaw(jsonEncode([
        {
          'timestampMs': 1,
          'kind': 'bypassSafety',
          'callSiteTag': 'a',
          'type': 'appOpen'
        },
        {'timestampMs': 2, 'kind': 'bypassSafety'}, // missing required fields
      ]));

      final trail = BypassAuditTrail();
      trail.attach(prefs);

      expect(trail.entries, isEmpty,
          reason: 'T155 (codex re-review, P2) — must not retain a partial, '
              'unvalidated prefix just because it happened to decode before '
              'the entry that actually failed');
    });

    test('maxEntries cap survives a reload — oldest dropped, not newest',
        () async {
      final first = BypassAuditTrail(maxEntries: 3);
      first.attach(prefs);
      for (var i = 0; i < 5; i++) {
        first.record(
            kind: 'bypassSafety',
            callSiteTag: 'entry$i',
            type: AdSlotType.appOpen);
      }
      await first.flush();

      final second = BypassAuditTrail(maxEntries: 3);
      second.attach(prefs);
      expect(second.entries, hasLength(3));
      expect(second.entries.map((e) => e.callSiteTag),
          ['entry2', 'entry3', 'entry4']);
    });

    test('clear() empties the persisted copy too, not just memory',
        () async {
      final trail = BypassAuditTrail();
      trail.attach(prefs);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      await trail.flush();
      await trail.clear();

      final reloaded = BypassAuditTrail();
      reloaded.attach(prefs);
      expect(reloaded.entries, isEmpty);
    });

    test('flush() writes immediately without waiting out the debounce window',
        () async {
      final trail = BypassAuditTrail();
      trail.attach(prefs);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      await trail.flush();

      final raw = prefs.getBypassAuditTrailRaw();
      expect(raw, isNotNull);
      final persisted = jsonDecode(raw!) as List;
      expect(persisted, hasLength(1));
    });

    // Codex review (P1): a bypass recorded before attach() (e.g. a pre-init
    // bypass, or the demo's own pre-init "Simulate a bypass" path) used to
    // never persist — record() no-ops the persist while _prefs is null, and
    // attach()'s own _load() only ever merged storage INTO memory, never
    // scheduled a write back out. Killed before the next record()/flush(),
    // that entry was gone.
    test(
        'an entry recorded BEFORE attach() is persisted once attach() runs, '
        'not lost if the process dies before the next record()', () async {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'pre_attach',
          type: AdSlotType.appOpen);
      expect(trail.entries, hasLength(1),
          reason: 'sanity: recorded in-memory before any attach()');

      trail.attach(prefs);
      await trail.flush();

      final reloaded = BypassAuditTrail();
      reloaded.attach(prefs);
      expect(reloaded.entries.map((e) => e.callSiteTag), contains('pre_attach'));
    });

    // Codex review (P2): attach() is called on every AdManager.initialize(),
    // including a destroy()+reinitialize() cycle — the trail itself is
    // deliberately never reset by destroy() (see its own doc comment). A
    // second attach() re-running _load() re-inserted the ENTIRE persisted
    // snapshot in front of what was already in memory (itself already
    // containing that same snapshot), doubling every prior entry each cycle.
    test(
        'attach() called twice (destroy()+reinit) does not duplicate history',
        () async {
      final trail = BypassAuditTrail();
      trail.attach(prefs);
      trail.record(
          kind: 'bypassSafety', callSiteTag: 'a', type: AdSlotType.appOpen);
      await trail.flush();
      expect(trail.entries, hasLength(1));

      // Simulates destroy()+initialize() calling attach() again on the SAME
      // (never-reset) trail instance.
      trail.attach(prefs);

      expect(trail.entries, hasLength(1),
          reason: 'T155 (codex re-review, P2) — a second attach() must not '
              're-insert the same persisted snapshot on top of what this '
              'process already has in memory');
    });
  });

  group('signBypassAuditTrail (Ed25519, reuses compliance-signing infra)',
      () {
    test('a signed trail verifies via verifySignedJsonPayload', () async {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);

      final signed = await signBypassAuditTrail(trail);
      final envelopeJson = signed.toJsonString();

      expect(await verifySignedJsonPayload(envelopeJson), isTrue);
      expect(signed.payloadJson, contains('splash_app_open'));
    });

    test('a tampered payload fails verification', () async {
      final trail = BypassAuditTrail();
      trail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen);
      final signed = await signBypassAuditTrail(trail);

      final tampered = SignedPayload(
        payloadJson:
            signed.payloadJson.replaceFirst('splash_app_open', 'forged_site'),
        publicKeyBase64: signed.publicKeyBase64,
        signatureBase64: signed.signatureBase64,
      );

      expect(await verifySignedJsonPayload(tampered.toJsonString()), isFalse);
    });
  });

  group('AdManager wiring', () {
    tearDown(() => AdManager().bypassAuditTrail.clear());

    test('showAppOpenAd(bypassSafety: true) records a bypassSafety entry',
        () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showAppOpenAd(
        onAdDismiss: (_) {},
        bypassSafety: true,
        callSiteTag: 'test_splash',
      );

      final entries = AdManager()
          .bypassAuditTrail
          .entries
          .where((e) => e.callSiteTag == 'test_splash');
      expect(entries, hasLength(1));
      expect(entries.single.kind, 'bypassSafety');
      expect(entries.single.type, 'appOpen');
    });

    test('showAppOpenAd(bypassSafety: false) records nothing', () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showAppOpenAd(onAdDismiss: (_) {});
      expect(AdManager().bypassAuditTrail.entries, isEmpty);
    });

    test(
        'showRewardedAd(bypassVipGuard: true) records a bypassVipGuard entry',
        () async {
      AdManager().bypassAuditTrail.clear();
      await AdManager().showRewardedAd(
        onEarnedReward: (_) {},
        bypassVipGuard: true,
        callSiteTag: 'test_vip_extend',
      );

      final entries = AdManager()
          .bypassAuditTrail
          .entries
          .where((e) => e.callSiteTag == 'test_vip_extend');
      expect(entries, hasLength(1));
      expect(entries.single.kind, 'bypassVipGuard');
      expect(entries.single.type, 'rewarded');
    });
  });
}
