// T117 — banner demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class BannerDemoPage extends AdScreen {
  const BannerDemoPage({super.key});

  @override
  State<BannerDemoPage> createState() => _BannerDemoPageState();
}

class _BannerDemoPageState extends AdScreenState<BannerDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Banner demo')),
      body: Column(
        children: [
          buildBanner(),
          Expanded(
            child: ListView(
              padding: bottomSafe(context, EdgeInsets.zero),
              children: [
                ListTile(
                  leading: const Icon(Icons.navigate_next),
                  title:
                      const Text('Push another screen (verifies pause/resume)'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const _BannerSecondScreen()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Banner refreshes here. Push the second screen — banner '
                    'pauses on AppLovin / hides on AdMob. Pop back to resume.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Second instance below — proves both banners load and '
                    'refresh independently (T65 keyed-by-instance).',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                buildBanner(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerSecondScreen extends AdScreen {
  const _BannerSecondScreen();

  @override
  State<_BannerSecondScreen> createState() => _BannerSecondScreenState();
}

class _BannerSecondScreenState extends AdScreenState<_BannerSecondScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Second route')),
        body: SafeArea(
          top: false,
          child: Column(children: [
            const Expanded(
                child: Center(child: Text('Banner pauses on previous'))),
            buildBanner(),
          ]),
        ),
      );
}
