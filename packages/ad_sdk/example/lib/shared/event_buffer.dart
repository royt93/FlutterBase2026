// T117 — in-memory ring buffer of AdEvent stream entries, feeding
// EventsDemoPage. Split out of main.dart. EventRow lives here (not in
// demos/events_demo_page.dart) since EventBuffer constructs it directly.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class EventBuffer {
  EventBuffer._();

  static final EventBuffer instance = EventBuffer._();

  static const int _maxEntries = 100;
  final List<EventRow> _rows = [];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void onEvent(AdEvent event) {
    _rows.insert(0, EventRow(DateTime.now(), event));
    if (_rows.length > _maxEntries) _rows.removeLast();
    revision.value = revision.value + 1;
  }

  List<EventRow> snapshot() => List.unmodifiable(_rows);

  void clear() {
    _rows.clear();
    revision.value = revision.value + 1;
  }
}

class EventRow {
  EventRow(this.timestamp, this.event);
  final DateTime timestamp;
  final AdEvent event;
}
