// T117 — top-level list of all demos. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import '../config/demo_config.dart';
import 'demo_tile.dart';
import '../demos/banner_demo_page.dart';
import '../demos/mrec_demo_page.dart';
import '../demos/native_demo_page.dart';
import '../demos/interstitial_demo_page.dart';
import '../demos/rewarded_demo_page.dart';
import '../demos/app_open_demo_page.dart';
import '../demos/vip_demo_page.dart';
import '../demos/consent_demo_page.dart';
import '../demos/safety_demo_page.dart';
import '../demos/log_viewer_demo_page.dart';
import '../demos/revenue_demo_page.dart';
import '../demos/state_panel_demo_page.dart';
import '../demos/events_demo_page.dart';
import '../demos/compliance_demo_page.dart';
import '../demos/diagnostics_demo_page.dart';
import '../demos/test_device_hash_demo_page.dart';
import 'layout_helpers.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ad_sdk demo'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      // DebugAdOverlay is mounted at MaterialApp.builder so it floats over
      // every page, not just HomePage.
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.symmetric(vertical: 8)),
        children: [
          DemoTile(
            icon: Icons.image,
            title: 'Banner ad',
            subtitle: 'Anchored adaptive banner with route lifecycle',
            color: Colors.blue,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BannerDemoPage())),
          ),
          DemoTile(
            icon: Icons.crop_landscape,
            title: 'MREC ad',
            subtitle: 'Fixed 300x250 rectangle with route lifecycle',
            color: Colors.blueGrey,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MrecDemoPage())),
          ),
          DemoTile(
            icon: Icons.view_agenda,
            title: 'Native ad',
            subtitle: 'AdMob template vs AppLovin custom layout',
            color: Colors.brown,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NativeDemoPage())),
          ),
          DemoTile(
            icon: Icons.fullscreen,
            title: 'Interstitial ad',
            subtitle: 'Show + safety gate + counter',
            color: Colors.indigo,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const InterstitialDemoPage())),
          ),
          DemoTile(
            icon: Icons.star,
            title: 'Rewarded ad',
            subtitle: 'Show + reward + VIP auto-grant toggle',
            color: Colors.orange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RewardedDemoPage())),
          ),
          DemoTile(
            icon: Icons.open_in_new,
            title: 'App-open ad',
            subtitle: 'Background → foreground triggers',
            color: Colors.green,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AppOpenDemoPage())),
          ),
          DemoTile(
            icon: Icons.workspace_premium,
            title: 'VIP / redeem',
            subtitle: 'Shared VipRedeemScreen (identical to host)',
            color: Colors.purple,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VipRedeemScreen(
                  publicKeyBase64: kDemoVipPublicKey,
                  onPrivacyPolicyTap: () =>
                      debugPrint('[example] privacy policy tapped'),
                  onPrivacyOptionsTap: () => AdManager().showPrivacyOptions(),
                ),
              ),
            ),
          ),
          DemoTile(
            icon: Icons.science_outlined,
            title: 'VIP API playground',
            subtitle: 'Raw redeem / signed keys / watch-ad buttons',
            color: Colors.deepPurple,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const VipDemoPage())),
          ),
          DemoTile(
            icon: Icons.privacy_tip,
            title: 'Consent / GDPR',
            subtitle: 'Consent flags + provider propagation',
            color: Colors.teal,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ConsentDemoPage())),
          ),
          DemoTile(
            icon: Icons.shield,
            title: 'Safety status',
            subtitle: 'Caps, throttle, dryRun mode, presets',
            color: Colors.red,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SafetyDemoPage())),
          ),
          DemoTile(
            icon: Icons.terminal,
            title: 'Log viewer',
            subtitle: 'Ring buffer of SDK logs',
            color: Colors.grey,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LogViewerDemoPage())),
          ),
          DemoTile(
            icon: Icons.attach_money,
            title: 'Revenue dashboard',
            subtitle: '\$ from onPaidEvent stream',
            color: Colors.lightGreen,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RevenueDemoPage())),
          ),
          DemoTile(
            icon: Icons.dashboard,
            title: 'Slot state panel',
            subtitle: 'Live AdSlot state + manual destroy/reinit',
            color: Colors.cyan,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const StatePanelDemoPage())),
          ),
          DemoTile(
            icon: Icons.stream,
            title: 'AdEvent stream',
            subtitle: 'All load/show/click/reward/revenue events live',
            color: Colors.deepOrange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EventsDemoPage())),
          ),
          DemoTile(
            icon: Icons.fact_check,
            title: 'Compliance report',
            subtitle: 'Export event log + safety + consent snapshot (T23)',
            color: Colors.brown,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ComplianceDemoPage())),
          ),
          DemoTile(
            icon: Icons.health_and_safety,
            title: 'Diagnostics & self-check',
            subtitle:
                'Waterfall/fill-rate/arbitrator snapshot + debug checklist',
            color: Colors.teal,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagnosticsDemoPage())),
          ),
          DemoTile(
            icon: Icons.fingerprint,
            title: 'AdMob test-device hash',
            subtitle: 'GAID vs the logcat-only AdMob test-device hash',
            color: Colors.pink,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const TestDeviceHashDemoPage())),
          ),
        ],
      ),
    );
  }
}
