import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'screen_c.dart';

/// Demo Screen B — demonstrates interstitial ad before navigation.
class ScreenB extends AdScreen {
  const ScreenB({super.key});

  @override
  State<ScreenB> createState() => _ScreenBState();
}

class _ScreenBState extends AdScreenState<ScreenB> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen B — Interstitial Demo'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Show Interstitial → Screen C'),
                  onPressed: () {
                    showInterstitialAd(onDone: (shown) {
                      SafeLogger.d('ScreenB', 'interstitial result: $shown');
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ScreenC()),
                      );
                    });
                  },
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
