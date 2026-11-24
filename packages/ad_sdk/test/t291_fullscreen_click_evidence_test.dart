// T291 — a click inside a fullscreen ad is written when it happens, but the
// visible/dismissed pair for THAT show is only written at dismiss. Reproduce the
// recorder chain a real session produces and look at `interactionDurationMs`.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AdFlightRecorder> session() async {
  final r = AdFlightRecorder();
  // Show #1 (interstitial, placement p): pair written at its dismiss, t=0.
  await r.recordPair(
      label1: 'fullscreenVisible',
      label2: 'fullscreenDismissed',
      slotType: 'interstitial',
      placement: 'p',
      providerTag: '[Fake]',
      timestampMs: 1000);
  // Show #2 starts at t=60_000. User clicks at t=63_000 (3 s into the ad).
  await r.record(
      label: 'clicked',
      slotType: 'interstitial',
      placement: 'p',
      providerTag: '[Fake]',
      touchActive: true,
      timestampMs: 63000);
  // Show #2 dismisses at t=70_000: its pair lands only now.
  await r.recordPair(
      label1: 'fullscreenVisible',
      label2: 'fullscreenDismissed',
      slotType: 'interstitial',
      placement: 'p',
      providerTag: '[Fake]',
      timestampMs: 70000);
  return r;
}

void main() {
  test('what the chain says today about a mid-ad click', () async {
    final r = await session();
    final clicked = r.entries.firstWhere((e) => e.label == 'clicked');
    // ignore: avoid_print
    print('T291 chain: ${r.entries.map((e) => '${e.label}@${e.timestampMs}').toList()} '
        'clickDuration=${clicked.interactionDurationMs}');
    expect(clicked.interactionDurationMs, 62000,
        reason: 'measured from the PREVIOUS ad\'s visible entry (t=1000), '
            'not from when this ad appeared (t=60000)');
  });
}
