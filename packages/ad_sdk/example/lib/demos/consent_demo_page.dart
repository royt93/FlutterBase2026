// T117 — consent demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class ConsentDemoPage extends StatefulWidget {
  const ConsentDemoPage({super.key});

  @override
  State<ConsentDemoPage> createState() => _ConsentDemoPageState();
}

class _ConsentDemoPageState extends State<ConsentDemoPage> {
  final ValueNotifier<bool> _hasConsent = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isAge = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _doNotSell = ValueNotifier<bool>(false);
  final TextEditingController _countryController = TextEditingController();

  /// Bumped after setConsent so the "effective personalization" card below
  /// reflects the just-applied AdManager().consent state.
  final ValueNotifier<int> _appliedRev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _hasConsent.value = AdManager().consent.hasUserConsent;
    _isAge.value = AdManager().consent.isAgeRestrictedUser;
    _doNotSell.value = AdManager().consent.doNotSell;
  }

  @override
  void dispose() {
    _hasConsent.dispose();
    _isAge.dispose();
    _doNotSell.dispose();
    _appliedRev.dispose();
    _countryController.dispose();
    super.dispose();
  }

  Widget _row(String label, ValueNotifier<bool> n, String help) {
    return ValueListenableBuilder<bool>(
      valueListenable: n,
      builder: (_, on, __) => SwitchListTile(
        value: on,
        onChanged: (v) => n.value = v,
        title: Text(label),
        subtitle: Text(help),
      ),
    );
  }

  void _syncFromSdk() {
    _hasConsent.value = AdManager().consent.hasUserConsent;
    _isAge.value = AdManager().consent.isAgeRestrictedUser;
    _doNotSell.value = AdManager().consent.doNotSell;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild + resync local toggles whenever SDK destroy/reinit fires.
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _syncFromSdk();
        });
        return _build(context);
      },
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consent demo')),
      body: ListView(
        padding: bottomSafe(context, EdgeInsets.zero),
        children: [
          _row('GDPR consent (hasUserConsent)', _hasConsent,
              'EEA users — set after UMP form ACCEPT.'),
          _row('Age-restricted (COPPA)', _isAge,
              'App targets children < 13 → tagForChildDirectedTreatment=YES.'),
          _row('Do-not-sell (CCPA)', _doNotSell,
              'California users opt-out of personal-data sale.'),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton(
              onPressed: () async {
                await AdManager().setConsent(AdConsent(
                  hasUserConsent: _hasConsent.value,
                  isAgeRestrictedUser: _isAge.value,
                  doNotSell: _doNotSell.value,
                ));
                _appliedRev.value++;
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Consent applied to both providers ✅')));
                }
              },
              child: const Text('Apply consent to providers'),
            ),
          ),
          const SizedBox(height: 12),
          // Effective per-request personalization (T02): AdMob attaches npa=1 to
          // every AdRequest when the applied consent has hasUserConsent=false.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<int>(
              valueListenable: _appliedRev,
              builder: (context, _, __) {
                final npa = !AdManager().consent.hasUserConsent;
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: npa
                        ? Colors.orange.withValues(alpha: 0.12)
                        : Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    npa
                        ? '📵 AdMob ad requests: NON-personalized (npa=1)'
                        : '🎯 AdMob ad requests: personalized',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 32),
          // ─── ConsentManager (Cupertino dialog) ──────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'ConsentManager — built-in Cupertino dialog (auto-shown post-splash on first launch)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          ValueListenableBuilder<ConsentSettings>(
            valueListenable: ConsentManager.instance.listenable,
            builder: (_, s, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: s.hasBeenAsked
                    ? Colors.green.shade50
                    : Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.hasBeenAsked
                            ? '✅ User has been asked'
                            : '⚠️ Not asked yet',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'consent=${s.hasUserConsent}  coppa=${s.isAgeRestrictedUser}  ccpa=${s.doNotSell}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                      if (s.askedAt != null)
                        Text(
                            'askedAt=${s.askedAt!.toLocal().toIso8601String().substring(0, 19)}',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11)),
                      Text(
                          'country=${s.country ?? '(not set — host-supplied only, see below)'}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Consent country analytics (T27) — SDK never infers this itself
          // (UMP only exposes EEA/non-EEA); host app must supply it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _countryController,
                    decoration: const InputDecoration(
                      labelText: 'Consent country (e.g. DE, US)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    final country = _countryController.text.trim();
                    await ConsentManager.instance.set(
                      ConsentManager.instance.current
                          .copyWith(country: country.isEmpty ? null : country),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(country.isEmpty
                              ? 'Consent country cleared'
                              : 'Consent country set to $country')));
                    }
                  },
                  child: const Text('Set'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Show consent dialog'),
                  onPressed: () async {
                    await ConsentManager.instance.showDialog(
                      context,
                      config: AdManager().config,
                      onPrivacyPolicyTap:
                          AdManager().config?.onPrivacyPolicyTap,
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reset (re-prompt next launch)'),
                  onPressed: () async {
                    await ConsentManager.instance
                        .reset(config: AdManager().config);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Consent reset — next init will re-prompt')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Note: the SDK auto-shows the binary dialog ~1s AFTER markSplashInactive '
              'on first launch (default behaviour, controlled by AdConfig.autoShowConsentDialog). '
              'iOS ATT prompt is still caller responsibility — see README.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
