// T117 — log viewer demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import '../shared/log_buffer.dart';
import '../shared/layout_helpers.dart';

class LogViewerDemoPage extends StatelessWidget {
  const LogViewerDemoPage({super.key});

  Color _colorFor(AdLogLevel l) => switch (l) {
        AdLogLevel.verbose => Colors.grey,
        AdLogLevel.warning => Colors.orange,
        AdLogLevel.error => Colors.red,
        AdLogLevel.none => Colors.black,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => LogBuffer.instance.clear(),
            tooltip: 'Clear',
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: LogBuffer.instance.revision,
        builder: (_, __, ___) {
          final entries = LogBuffer.instance.snapshot();
          if (entries.isEmpty) {
            return const Center(child: Text('(no logs yet)'));
          }
          return ListView.builder(
            reverse: true,
            padding: bottomSafe(context, EdgeInsets.zero),
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[entries.length - 1 - i];
              final time = e.timestamp.toIso8601String().substring(11, 19);
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(time,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.grey)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: _colorFor(e.level).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(e.level.name.toUpperCase(),
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: _colorFor(e.level),
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('[${e.tag}] ${e.message}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11)),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
