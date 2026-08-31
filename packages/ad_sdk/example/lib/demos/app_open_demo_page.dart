// T117 — app open demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class AppOpenDemoPage extends StatelessWidget {
  const AppOpenDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App-open demo')),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'How to test:\n'
                  '1. Press the home button to background the app.\n'
                  '2. Wait > 5 s.\n'
                  '3. Tap the app icon to return — you should see the App Open ad.\n'
                  '\n'
                  'Cold start protection skips the very first foreground event.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content:
                        Text(loaded ? 'App open ad ready ✅' : 'Load failed ❌'),
                  ));
                });
              },
              child: const Text('Force load App Open'),
            ),
          ],
        ),
      ),
    );
  }
}
