import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import 'screen_a.dart';

/// HomeScreen — extends AdScreen to get banner + interstitial + rewarded helpers.
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  // ── ValueNotifiers (no setState) ──
  final ValueNotifier<int> _interCountNotifier = ValueNotifier(0);
  final ValueNotifier<String> _rewardStatusNotifier = ValueNotifier('Unlock premium content');

  @override
  void dispose() {
    _interCountNotifier.dispose();
    _rewardStatusNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ad_sdk Demo'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // ── Banner at top ── (RouteAware, lifecycle-managed automatically)
          buildBanner(),

          // ── Content ──
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Ad Touch Points',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // ── Interstitial ──
                  ValueListenableBuilder<int>(
                    valueListenable: _interCountNotifier,
                    builder: (_, count, __) => _DemoCard(
                      icon: Icons.fullscreen,
                      title: 'Interstitial Ad',
                      subtitle: 'Shown $count times',
                      color: Colors.blue,
                      onTap: () => showInterstitialAd(onDone: (shown) {
                        if (shown) _interCountNotifier.value++;
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Rewarded ──
                  ValueListenableBuilder<String>(
                    valueListenable: _rewardStatusNotifier,
                    builder: (_, status, __) => _DemoCard(
                      icon: Icons.star,
                      title: 'Rewarded Ad',
                      subtitle: status,
                      color: Colors.orange,
                      onTap: () => showRewardedAd(onEarnedReward: (earned) {
                        _rewardStatusNotifier.value = earned
                            ? '✅ Reward earned!'
                            : '❌ Ad skipped or unavailable';
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── App Open info ──
                  const _DemoCard(
                    icon: Icons.open_in_new,
                    title: 'App Open Ad',
                    subtitle: 'Background the app and return',
                    color: Colors.green,
                    onTap: null,
                  ),
                  const SizedBox(height: 12),

                  // ── Navigate to Screen A (multi-screen demo) ──
                  _DemoCard(
                    icon: Icons.navigate_next,
                    title: 'Multi-screen Ad Flow',
                    subtitle: 'Screen A → B → C with banner + interstitial',
                    color: Colors.purple,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ScreenA()),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Safety status ──
                  ValueListenableBuilder<bool>(
                    valueListenable: AdManager().bannerIsLoaded,
                    builder: (_, loaded, __) => Text(
                      'Banner loaded: $loaded\n${AdSafetyConfig.getStatus()}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Reusable demo card widget
// ─────────────────────────────────────────
class _DemoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _DemoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: onTap != null
            ? Icon(Icons.play_arrow, color: color)
            : const Icon(Icons.info_outline, color: Colors.grey),
        onTap: onTap,
      ),
    );
  }
}
