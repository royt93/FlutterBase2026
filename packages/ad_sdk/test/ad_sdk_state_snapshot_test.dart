// T109 — AdManager.stateSnapshot: one ValueListenable<AdSdkStateSnapshot>
// combining isInitialised/canRequestAds/isOffline/isVipActive/fullscreenBusy,
// coalesced onto a microtask so a burst of source changes in the same
// synchronous callback only notifies listeners once.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  @override
  ValueListenable<bool> get activeListenable => ValueNotifier<bool>(_active);

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
    AdManager().debugVipManager = null;
  });

  test('default snapshot: not initialised, gate open, online, no VIP, '
      'screen free', () {
    final s = AdManager().stateSnapshot.value;
    expect(s.isInitialised, isFalse);
    expect(s.canRequestAds, isTrue);
    expect(s.isOffline, isFalse);
    expect(s.isVipActive, isFalse);
    expect(s.fullscreenBusy, isFalse);
  });

  test('a tracked source change (canRequestAds) updates the snapshot on '
      'the next microtask', () async {
    AdManager().debugCanRequestAds = false;
    expect(AdManager().stateSnapshot.value.canRequestAds, isTrue,
        reason: 'the recompute is coalesced onto a microtask, not synchronous');

    await Future<void>.value();

    expect(AdManager().stateSnapshot.value.canRequestAds, isFalse);
  });

  test('recompute reads the CURRENT VIP state, not just the signal that '
      'triggered it', () async {
    AdManager().debugVipManager = _FakeVip(true);
    // No signal this test hooks fired yet for the VIP change itself — an
    // unrelated tracked source (canRequestAds) is what triggers the
    // recompute, and it must pick up the live vip.isActive read alongside
    // its own change.
    AdManager().debugCanRequestAds = false;
    await Future<void>.value();

    final s = AdManager().stateSnapshot.value;
    expect(s.isVipActive, isTrue);
    expect(s.canRequestAds, isFalse);
  });

  test('several source changes in the same synchronous turn coalesce into '
      'one listener notification', () async {
    var notifications = 0;
    void listener() => notifications++;
    AdManager().stateSnapshot.addListener(listener);
    addTearDown(() => AdManager().stateSnapshot.removeListener(listener));

    // Three changes to a tracked source, same synchronous callback — each
    // call routes through _scheduleStateSnapshotRecompute().
    AdManager().debugCanRequestAds = false;
    AdManager().debugCanRequestAds = true;
    AdManager().debugCanRequestAds = false;

    expect(notifications, 0,
        reason: 'still coalesced — the microtask has not run yet');

    await Future<void>.value();

    expect(notifications, 1,
        reason: 'one microtask recompute for all three changes, not three');
    expect(AdManager().stateSnapshot.value.canRequestAds, isFalse);
  });

  test('AdSdkStateSnapshot equality/hashCode are value-based', () {
    const a = AdSdkStateSnapshot(
      isInitialised: true,
      canRequestAds: true,
      isOffline: false,
      isVipActive: false,
      fullscreenBusy: false,
    );
    const b = AdSdkStateSnapshot(
      isInitialised: true,
      canRequestAds: true,
      isOffline: false,
      isVipActive: false,
      fullscreenBusy: false,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
