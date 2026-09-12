import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mount storm receives callback for every app-open caller',
      (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    await tester.pumpWidget(const _AppOpenStorm());
    await tester.pumpAndSettle();
    expect(find.byType(_CallbackProbe), findsNWidgets(8));
    expect(_CallbackProbe.totalCallbacks, 8);
    manager.debugResetGuardState();
    manager.debugSetAdapter(null);
  });
}

class _AppOpenStorm extends StatelessWidget {
  const _AppOpenStorm();

  @override
  Widget build(BuildContext context) => Column(
        children: List.generate(8, (_) => const _CallbackProbe()),
      );
}

class _CallbackProbe extends StatefulWidget {
  const _CallbackProbe();
  static int totalCallbacks = 0;

  @override
  State<_CallbackProbe> createState() => _CallbackProbeState();
}

class _CallbackProbeState extends State<_CallbackProbe> {
  @override
  void initState() {
    super.initState();
    AdManager()
        .loadAppOpenAd(onAdLoaded: (_) => _CallbackProbe.totalCallbacks++);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
