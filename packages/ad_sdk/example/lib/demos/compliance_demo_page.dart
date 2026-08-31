// T117 — compliance demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/layout_helpers.dart';

class ComplianceDemoPage extends StatefulWidget {
  const ComplianceDemoPage({super.key});

  @override
  State<ComplianceDemoPage> createState() => _ComplianceDemoPageState();
}

class _ComplianceDemoPageState extends State<ComplianceDemoPage> {
  String? _reportJson;
  int _eventCount = 0;

  void _generate() {
    final report = AdManager().exportComplianceReport();
    setState(() {
      _eventCount = report.events.length;
      _reportJson = report.toJsonString(pretty: true);
    });
  }

  void _copy() {
    final json = _reportJson;
    if (json == null) return;
    Clipboard.setData(ClipboardData(text: json));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report JSON copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final json = _reportJson;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance report'),
        actions: [
          if (json != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy JSON',
              onPressed: _copy,
            ),
        ],
      ),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Combines the persisted ad event log, safety status snapshot, '
              'consent flags and VIP state into one JSON document — hand to '
              'a partner/reviewer as evidence of policy compliance.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Generate report'),
            ),
            const SizedBox(height: 12),
            if (json == null)
              const Expanded(
                child: Center(child: Text('(no report generated yet)')),
              )
            else
              Expanded(
                child: Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('$_eventCount event(s) in log',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            json,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
