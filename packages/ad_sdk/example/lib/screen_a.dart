import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'screen_b.dart';

/// Demo Screen A — demonstrates interstitial + rewarded ads using AdScreen.
/// Part of the ad_sdk example app (no GetX dependency).
class ScreenA extends AdScreen {
  const ScreenA({super.key});

  @override
  State<ScreenA> createState() => _ScreenAState();
}

class _ScreenAState extends AdScreenState<ScreenA> {
  final ValueNotifier<int> _coinsNotifier = ValueNotifier<int>(0);

  @override
  void dispose() {
    _coinsNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen A — Ad Demo')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: _coinsNotifier,
                      builder: (_, coins, __) => Text(
                        'Coins: $coins',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Show Interstitial → Screen B'),
                      onPressed: () {
                        showInterstitialAd(onDone: (shown) {
                          SafeLogger.d('ScreenA', 'interstitial result: $shown');
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ScreenB()),
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.monetization_on),
                      label: const Text('Watch Ad for 10 Coins'),
                      onPressed: () {
                        showRewardedAd(
                          onEarnedReward: (earned) {
                            if (earned) {
                              SafeLogger.d('ScreenA', '🎉 Rewarded! +10 coins');
                              _coinsNotifier.value += 10;
                            }
                            // else: SDK already showed TopToast automatically
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            buildBanner(),
          ],
        ),
      ),
    );
  }
}
