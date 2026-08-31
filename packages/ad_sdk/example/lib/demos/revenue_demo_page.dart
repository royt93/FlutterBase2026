// T117 — revenue demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class RevenueDemoPage extends StatelessWidget {
  const RevenueDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revenue dashboard')),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RevenuePanel(),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Revenue is reported by AdMob/AppLovin via the OnPaidEvent '
                  'hook on each impression. The dashboard subscribes to '
                  'AdManager().events and accumulates AdRevenueEvent values.\n'
                  '\n'
                  'Pipe the same stream into your Firebase / AppsFlyer LTV '
                  'tracking — see README.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
