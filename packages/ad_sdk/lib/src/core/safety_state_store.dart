import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/safe_logger.dart';

/// Invalid-traffic state that must outlive the process (T293): last violation
/// time, active pause end. One JSON record in the encrypted store, so editing it
/// by hand needs a broken Keystore, unlike plain `SharedPreferences`.
///
/// Fail-open: any read/write error means "no stored state". Never throws.
class SafetyStateStore {
  SafetyStateStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              aOptions: AndroidOptions(),
            );

  static const String _key = 'ad_sdk_safety_state_v1';

  /// Bounds the start-up read: a Keystore that never answers must not block it.
  static const Duration readTimeout = Duration(seconds: 2);
  final FlutterSecureStorage _secure;

  /// Serialises writes (static: every instance shares the one key).
  static Future<void> _chain = Future<void>.value();

  Future<String?> readRaw() => _secure.read(key: _key);
  Future<void> writeRaw(String json) => _secure.write(key: _key, value: json);
  Future<void> deleteRaw() => _secure.delete(key: _key);

  /// [bounded] is true for release start-up, where the caller waits for this and
  /// a Keystore that never answers must not block it. Elsewhere no timer is
  /// created (a pending timer fails widget tests running on a fake clock).
  Future<({int lastViolationAtMs, int pauseUntilMs})?> load(
      {bool bounded = false}) async {
    try {
      final read = readRaw();
      final raw = bounded ? await read.timeout(readTimeout) : await read;
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        lastViolationAtMs: (m['lastViolationAtMs'] as num?)?.toInt() ?? 0,
        pauseUntilMs: (m['pauseUntilMs'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      SafeLogger.w('SafetyStateStore', 'load failed, ignoring: $e');
      return null;
    }
  }

  Future<void> save({required int lastViolationAtMs, required int pauseUntilMs}) {
    final next = _chain.then((_) async {
      try {
        await writeRaw(jsonEncode({
          'lastViolationAtMs': lastViolationAtMs,
          'pauseUntilMs': pauseUntilMs,
        }));
      } catch (e) {
        SafeLogger.w('SafetyStateStore', 'save failed, ignoring: $e');
      }
    });
    _chain = next;
    return next;
  }

  Future<void> erase() {
    final next = _chain.then((_) async {
      try {
        await deleteRaw();
      } catch (e) {
        SafeLogger.w('SafetyStateStore', 'erase failed: $e');
      }
    });
    _chain = next;
    return next;
  }
}
