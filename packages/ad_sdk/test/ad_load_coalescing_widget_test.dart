import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audit fix (post-T211) — see the matching class in
/// `ad_load_coalescing_test.dart`: the old assertion (`isReady, isTrue`)
/// can't tell a real single native request apart from 12 real native
/// requests that all happened to succeed. Counts real invocations instead.
class _CountingAdapter extends FakeAdProviderAdapter {
  int rewardedLoadCalls = 0;

  @override
  Future<void> loadRewarded() {
    rewardedLoadCalls++;
    return super.loadRewarded();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mount storm joins into exactly one real rewarded load',
      (tester) async {
    final adapter = _CountingAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    await tester.pumpWidget(const _Storm());
    await tester.pumpAndSettle();
    expect(adapter.rewardedLoadCalls, 1);
    expect(adapter.rewardedSlot.isReady, isTrue);
    manager.debugSetAdapter(null);
    manager.debugResetGuardState();
  });
}

class _Storm extends StatelessWidget {
  const _Storm();

  @override
  Widget build(BuildContext context) => Column(
        children: List.generate(
          12,
          (_) => FutureBuilder<void>(
            future: AdManager().loadRewardedAd(),
            builder: (_, __) => const SizedBox.shrink(),
          ),
        ),
      );
}
