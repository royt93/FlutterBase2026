// T117 — native demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class NativeDemoPage extends AdScreen {
  const NativeDemoPage({super.key});

  @override
  State<NativeDemoPage> createState() => _NativeDemoPageState();
}

class _NativeDemoPageState extends AdScreenState<NativeDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Native demo')),
      body: ListView(
        padding: bottomSafe(context, EdgeInsets.zero),
        children: [
          buildNative(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Native ad v1: fixed layout, no auto-refresh/route-pause. '
              'AdMob renders its own template + "Ad" badge; AppLovin renders '
              'a custom Dart layout with a package-drawn "Ad" badge.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Second instance below — proves both natives load '
              'independently (T65 keyed-by-instance).',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          buildNative(),
        ],
      ),
    );
  }
}
