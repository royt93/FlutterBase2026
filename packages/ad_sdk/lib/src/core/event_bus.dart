/// Simple event bus for internal SDK communication.
class BoolEvent {
  final bool value;
  const BoolEvent(this.value);
}

class SimpleEventBus {
  static final SimpleEventBus _instance = SimpleEventBus._internal();
  factory SimpleEventBus() => _instance;
  SimpleEventBus._internal();

  final List<void Function(BoolEvent)> _listeners = [];

  /// F1 — the most recently fired event, replayed to any listener that
  /// subscribes after it fired. "Subscribe before init starts" was a caller
  /// convention (see SplashScreen), not something the bus enforced — a late
  /// listener used to silently miss the init-completion event.
  BoolEvent? _lastEvent;

  void listen(void Function(BoolEvent) listener) {
    _listeners.add(listener);
    final last = _lastEvent;
    if (last != null) listener(last);
  }

  void remove(void Function(BoolEvent) listener) {
    _listeners.remove(listener);
  }

  /// Fire event — each listener is guarded so one failure
  /// doesn't prevent other listeners from receiving the event.
  void fire(BoolEvent event) {
    _lastEvent = event;
    for (final l in List.of(_listeners)) {
      try {
        l(event);
      } catch (_) {
        // Fix #43: swallow — one bad listener must not block others
      }
    }
  }

  /// Remove all listeners — call from [AdManager.destroy()].
  void clearAll() {
    _listeners.clear();
    _lastEvent = null;
  }
}
