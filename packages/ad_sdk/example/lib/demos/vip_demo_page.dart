// T117 — vip demo page. Split out of main.dart.
import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import '../config/demo_config.dart';
import '../shared/layout_helpers.dart';

class VipDemoPage extends StatefulWidget {
  const VipDemoPage({super.key});

  @override
  State<VipDemoPage> createState() => _VipDemoPageState();
}

class _VipDemoPageState extends State<VipDemoPage> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _redeem(String key, Duration duration) async {
    final vip = AdManager().vip;
    if (vip == null) return;
    await vip.redeemVip(
      context,
      key: key,
      duration: duration,
      validator: AdManager().config?.vipKeyValidator,
      strings: AdManager().config?.vipDialogStrings ?? const VipDialogStrings(),
      // stack: true → global stacking: ADDS time on top of the latest expiry
      // across ALL VIP entries (cộng dồn toàn cục) instead of latest-wins.
      stack: true,
    );
    // vip.activeListenable only fires on true/false transitions, so stacking
    // more time while already active wouldn't otherwise refresh the card below.
    if (mounted) setState(() {});
  }

  /// T18 — redeem an offline SIGNED VIP key (Ed25519, verified against the
  /// embedded public key; no network; per-device one-time-use).
  Future<void> _redeemSigned(String code) async {
    final vip = AdManager().vip;
    if (vip == null) return;
    final r = await vip.redeemSignedKey(code,
        publicKeyBase64: kDemoVipPublicKey, stack: true);
    if (!mounted) return;
    setState(() {});
    final msg = switch (r.status) {
      VipRedeemStatus.success => '✅ Signed key OK — VIP granted',
      VipRedeemStatus.alreadyUsed => '⏭️ Key already used on this device',
      VipRedeemStatus.invalid => '❌ Invalid key: ${r.error}',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Watch a real rewarded ad to EXTEND VIP — works even while already VIP
  /// (`bypassVipGuard: true` plays a real ad; the SDK loads it on demand). The
  /// reward is granted into a fixed key with `stack: true` so repeats add up.
  Future<void> _watchAdToExtend() async {
    final vip = AdManager().vip;
    if (vip == null) return;
    AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (earned) {
        if (!earned) return;
        vip.addVip(
          key: 'REWARDED_VIP',
          duration: const Duration(days: 3),
          stack: true,
        );
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final vip = AdManager().vip;
    return Scaffold(
      appBar: AppBar(title: const Text('VIP demo')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          // GAID allow-list — a second VIP mechanism alongside key redeem:
          // mark specific devices VIP by their Google Advertising ID. The
          // SUPPORTED way is the startup config `AdConfig.vipDeviceGaids:
          // ['gaid1', ...]` (auto-migrated to VipManager entries on first
          // init). `AdManager().isVIPMember()` reports the current state.
          // (The runtime add/deleteVIPMember mutators are deprecated — prefer
          // `AdManager().vip.addVip(...)` / `revokeVip(...)`.)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('GAID VIP allow-list',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Set at startup via AdConfig.vipDeviceGaids: [...]. '
                    'Tap to read the live VIP state:',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      final isVip = AdManager().isVIPMember();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('isVIPMember() = $isVip')),
                      );
                    },
                    child: const Text('Check isVIPMember()'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Status card
          if (vip != null)
            ValueListenableBuilder<bool>(
              valueListenable: vip.activeListenable,
              builder: (_, active, __) {
                final exp = vip.expiresAt;
                return Card(
                  color: active ? Colors.purple.shade50 : Colors.grey.shade100,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active ? '🟣 VIP active' : '⚪ VIP inactive',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        if (active && exp != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                'Until ${exp.toLocal().toIso8601String().substring(0, 16)}'),
                          ),
                        ValueListenableBuilder<bool>(
                          valueListenable: vip.graceNudgeDueListenable,
                          builder: (_, due, __) {
                            if (!due) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber,
                                      color: Colors.orange, size: 18),
                                  const SizedBox(width: 4),
                                  const Expanded(
                                      child: Text(
                                          '⏳ VIP expiring soon — grace nudge due')),
                                  TextButton(
                                    onPressed: vip.acknowledgeGraceNudge,
                                    child: const Text('Ack'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        if (vip.entries.isNotEmpty) ...[
                          const Divider(),
                          const Text('Entries:',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          ...vip.entries.map((e) => Text(
                                '• ${e.key} → ${e.expiresAt.toLocal().toIso8601String().substring(0, 16)}',
                                style: const TextStyle(fontSize: 12),
                              )),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 16),

          // Quick redeem buttons
          const Text('Quick redeem',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: kDemoVipKeys.entries
                .map((e) => OutlinedButton(
                      onPressed: () => _redeem(e.key, e.value),
                      child: Text('${e.key}\n(${e.value.inDays} days)',
                          textAlign: TextAlign.center),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),

          // T18 — signed offline keys (Ed25519). Redeeming twice shows the
          // per-device one-time-use guard ("already used").
          const Text('Signed keys (T18 — offline, forge-proof)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: kDemoSignedVipKeys.entries
                .map((e) => FilledButton.tonal(
                      onPressed: () => _redeemSigned(e.value),
                      child: Text('signed ${e.key}'),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),

          // Custom redeem
          const Text('Custom key (1-day duration)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'enter key',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _redeem(_ctrl.text, const Duration(days: 1)),
                child: const Text('Redeem'),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Watch ad → +3 days VIP (stacks; works even while already VIP)
          const Text('Extend by watching an ad',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _watchAdToExtend,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Watch ad → +3 days VIP (stack)'),
          ),
          const SizedBox(height: 24),

          // Revoke
          FilledButton.tonal(
            onPressed: () async {
              await vip?.revokeAll();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All VIP entries revoked')),
                );
              }
            },
            child: const Text('Revoke ALL'),
          ),
        ],
      ),
    );
  }
}
