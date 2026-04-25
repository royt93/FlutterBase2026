import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VipEntry', () {
    final now = DateTime(2025, 6, 15, 12, 0);

    test('isActive true when expiresAt is in the future', () {
      final e = VipEntry(
        key: 'TEST_VIP_7',
        expiresAt: DateTime.now().add(const Duration(days: 7)),
        grantedAt: now,
      );
      expect(e.isActive, isTrue);
    });

    test('isActive false when expiresAt is in the past', () {
      final e = VipEntry(
        key: 'EXPIRED',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        grantedAt: now,
      );
      expect(e.isActive, isFalse);
    });

    test('remaining returns Duration.zero when expired', () {
      final e = VipEntry(
        key: 'EXPIRED',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        grantedAt: now,
      );
      expect(e.remaining, Duration.zero);
    });

    test('remaining is positive when active', () {
      final e = VipEntry(
        key: 'A',
        expiresAt: DateTime.now().add(const Duration(hours: 5)),
        grantedAt: now,
      );
      expect(e.remaining.inHours, inInclusiveRange(4, 5));
    });

    test('toJson + fromJson round-trip', () {
      final e = VipEntry(
        key: 'TEST_VIP_30',
        expiresAt: DateTime(2026, 1, 1, 12, 30),
        grantedAt: DateTime(2025, 1, 1, 12, 30),
      );
      final json = e.toJson();
      final back = VipEntry.fromJson(json);
      expect(back.key, e.key);
      expect(back.expiresAt, e.expiresAt);
      expect(back.grantedAt, e.grantedAt);
    });

    test('encodeList + decodeList round-trip', () {
      final entries = [
        VipEntry(
          key: 'A',
          expiresAt: DateTime(2026, 1, 1),
          grantedAt: DateTime(2025, 1, 1),
        ),
        VipEntry(
          key: 'B',
          expiresAt: DateTime(2027, 6, 15),
          grantedAt: DateTime(2025, 6, 15),
        ),
      ];
      final encoded = VipEntry.encodeList(entries);
      final decoded = VipEntry.decodeList(encoded);
      expect(decoded.length, 2);
      expect(decoded[0].key, 'A');
      expect(decoded[1].key, 'B');
    });

    test('decodeList returns empty for null/empty input', () {
      expect(VipEntry.decodeList(null), isEmpty);
      expect(VipEntry.decodeList(''), isEmpty);
    });

    test('decodeList returns empty for malformed JSON', () {
      expect(VipEntry.decodeList('not json'), isEmpty);
      expect(VipEntry.decodeList('{"not": "a list"}'), isEmpty);
    });

    test('decodeList skips bad entries but keeps good ones', () {
      // Mix of one valid + one missing-field entry.
      const mixed =
          '[{"key":"GOOD","expiresAt":"2026-01-01T00:00:00.000","grantedAt":"2025-01-01T00:00:00.000"},'
          '{"key":"BAD"}]';
      final decoded = VipEntry.decodeList(mixed);
      expect(decoded.length, 1);
      expect(decoded.first.key, 'GOOD');
    });
  });
}
