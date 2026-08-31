// T117 — diagnostics demo page. Split out of main.dart.
import 'dart:async';
import 'dart:convert' show JsonEncoder;

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class DiagnosticsDemoPage extends StatefulWidget {
  const DiagnosticsDemoPage({super.key});

  @override
  State<DiagnosticsDemoPage> createState() => _DiagnosticsDemoPageState();
}

class _DiagnosticsDemoPageState extends State<DiagnosticsDemoPage> {
  static const _encoder = JsonEncoder.withIndent('  ');

  String? _diagnosticsJson;
  SelfCheckResult? _selfCheck;
  bool _runningSelfCheck = false;

  void _runDiagnostics() {
    final diag = AdManager().diagnostics();
    setState(() => _diagnosticsJson = _encoder.convert(diag.toJson()));
  }

  Future<void> _runSelfCheck() async {
    setState(() => _runningSelfCheck = true);
    final result = await AdManager().runIntegrationSelfCheck();
    if (!mounted) return;
    setState(() {
      _selfCheck = result;
      _runningSelfCheck = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final diagJson = _diagnosticsJson;
    final selfCheck = _selfCheck;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics & self-check')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          const Text(
            'AdManager.diagnostics() — one-shot snapshot of mediation '
            'waterfall, fill rate and arbitrator stats, for "why is eCPM low '
            'today" without cross-referencing 3 separate pages.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _runDiagnostics,
            icon: const Icon(Icons.query_stats),
            label: const Text('Run diagnostics()'),
          ),
          if (diagJson != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(diagJson,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ),
          ],
          const Divider(height: 32),
          const Text(
            'AdManager.runIntegrationSelfCheck() — debug-only checklist '
            '(init → consent → per-slot load) so a partner integrating the '
            'SDK doesn\'t have to click through every demo page by hand. '
            'No-op (skipped) outside debug builds.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _runningSelfCheck ? null : _runSelfCheck,
            icon: _runningSelfCheck
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.checklist),
            label: const Text('Run runIntegrationSelfCheck()'),
          ),
          if (selfCheck != null) ...[
            const SizedBox(height: 8),
            Card(
              color: selfCheck.allPassed
                  ? Colors.green.withValues(alpha: 0.08)
                  : Colors.red.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                        selfCheck.allPassed ? 'All checks passed' : 'FAILED',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const Divider(height: 1),
                  for (final item in selfCheck.items)
                    ListTile(
                      dense: true,
                      leading: Icon(
                          switch (item.status) {
                            SelfCheckStatus.pass => Icons.check_circle,
                            SelfCheckStatus.fail => Icons.error,
                            SelfCheckStatus.skipped =>
                              Icons.remove_circle_outline,
                          },
                          color: switch (item.status) {
                            SelfCheckStatus.pass => Colors.green,
                            SelfCheckStatus.fail => Colors.red,
                            SelfCheckStatus.skipped => Colors.grey,
                          }),
                      title: Text(item.name),
                      subtitle: item.detail != null ? Text(item.detail!) : null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
