// T117 — rewarded demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class RewardedDemoPage extends AdScreen {
  const RewardedDemoPage({super.key});

  @override
  State<RewardedDemoPage> createState() => _RewardedDemoPageState();
}

class _RewardedDemoPageState extends AdScreenState<RewardedDemoPage> {
  final ValueNotifier<int> _coins = ValueNotifier<int>(0);
  final ValueNotifier<bool> _vipAutoGrant = ValueNotifier<bool>(false);
  final ValueNotifier<String> _last = ValueNotifier<String>('—');
  final TextEditingController _ssvCtrl = TextEditingController();

  @override
  void dispose() {
    _coins.dispose();
    _vipAutoGrant.dispose();
    _last.dispose();
    _ssvCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewarded demo')),
      body: SingleChildScrollView(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _coins,
              builder: (_, c, __) => Text('Coins: $c',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _last,
              builder: (_, r, __) =>
                  Text('Last: $r', style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<bool>(
              valueListenable: _vipAutoGrant,
              builder: (_, on, __) => SwitchListTile(
                value: on,
                onChanged: (v) => _vipAutoGrant.value = v,
                title: const Text('VIP auto-grant'),
                subtitle: const Text(
                    'When VIP, auto-mark reward earned (Q12B: opt-in only).'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ssvCtrl,
              decoration: const InputDecoration(
                labelText: 'SSV user id (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final ssvUserId = _ssvCtrl.text.isEmpty ? null : _ssvCtrl.text;
                showRewardedAd(
                  vipAutoGrant: _vipAutoGrant.value,
                  ssvUserId: ssvUserId,
                  onEarnedReward: (earned) {
                    _last.value = earned
                        ? 'earned 🏆${ssvUserId != null ? ' (pending SSV confirmation)' : ''}'
                        : 'skipped/blocked ❌';
                    if (earned) _coins.value = _coins.value + 10;
                  },
                );
              },
              child: const Text('Watch ad for +10 coins'),
            ),
          ],
        ),
      ),
    );
  }
}
