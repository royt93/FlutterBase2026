// T117 — mrec demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class MrecDemoPage extends AdScreen {
  const MrecDemoPage({super.key});

  @override
  State<MrecDemoPage> createState() => _MrecDemoPageState();
}

class _MrecDemoPageState extends AdScreenState<MrecDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MREC demo')),
      body: Column(
        children: [
          buildMrec(),
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
                        builder: (_) => const _MrecSecondScreen()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'MREC is a fixed 300x250 rectangle. Push the second '
                    'screen — it pauses on AppLovin / hides on AdMob. Pop '
                    'back to resume.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Second instance below — proves both MRECs load '
                    'independently (T65 keyed-by-instance).',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                buildMrec(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MrecSecondScreen extends AdScreen {
  const _MrecSecondScreen();

  @override
  State<_MrecSecondScreen> createState() => _MrecSecondScreenState();
}

class _MrecSecondScreenState extends AdScreenState<_MrecSecondScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Second route')),
        body: SafeArea(
          top: false,
          child: Column(children: [
            const Expanded(
                child: Center(child: Text('MREC pauses on previous'))),
            buildMrec(),
          ]),
        ),
      );
}
