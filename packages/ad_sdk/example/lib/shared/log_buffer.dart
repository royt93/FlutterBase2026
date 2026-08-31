// T117 — in-memory ring buffer of SDK logs, feeding LogViewerDemoPage.
// Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class LogBuffer {
  LogBuffer._();

  static final LogBuffer instance = LogBuffer._();

  static const int _maxEntries = 200;
  final List<LogEntry> _entries = [];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void Function(AdLogLevel, String, String) get sink => _onLog;

  void _onLog(AdLogLevel level, String tag, String message) {
    _entries.add(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    ));
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    revision.value = revision.value + 1;
  }

  List<LogEntry> snapshot() => List.unmodifiable(_entries);

  void clear() {
    _entries.clear();
    revision.value = revision.value + 1;
  }
}

class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime timestamp;
  final AdLogLevel level;
  final String tag;
  final String message;
}
