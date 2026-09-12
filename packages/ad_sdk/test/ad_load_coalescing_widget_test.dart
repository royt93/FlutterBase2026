import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mount storm joins one rewarded load future', (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    await tester.pumpWidget(const _Storm());
    await tester.pumpAndSettle();
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
