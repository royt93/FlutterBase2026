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

    // ── T17: anti clock-rollback ─────────────────────────────────────────
    group('anti clock-rollback (T17)', () {
      test(
          'isActive false when grantedAt is in the future (clock rolled back '
          'after grant)', () {
        final e = VipEntry(
          key: 'ROLLED_BACK',
          // Still "unexpired" by wall-clock, but grantedAt in the future
          // means the system clock was set backwards since the grant.
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          grantedAt: DateTime.now().add(const Duration(days: 10)),
        );
        expect(e.isActive, isFalse);
      });

      test('remaining is Duration.zero when grantedAt is in the future', () {
        final e = VipEntry(
          key: 'ROLLED_BACK',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          grantedAt: DateTime.now().add(const Duration(days: 10)),
        );
        expect(e.remaining, Duration.zero);
      });

      test('isActive still true for a normal, non-rolled-back active entry',
          () {
        final e = VipEntry(
          key: 'NORMAL',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          grantedAt: DateTime.now().subtract(const Duration(hours: 1)),
        );
        expect(e.isActive, isTrue);
      });

      test(
          'isActive false for both expired AND rolled-back (still false, '
          'not resurrected)', () {
        final e = VipEntry(
          key: 'EXPIRED_AND_ROLLED_BACK',
          expiresAt: DateTime.now().subtract(const Duration(days: 1)),
          grantedAt: DateTime.now().add(const Duration(days: 10)),
        );
        expect(e.isActive, isFalse);
      });
    });

    // ─── Round-23 audit, MAJOR. A timestamp persisted without a zone marker
    // is re-read in whatever zone the device is in NEXT time — fly west, or
    // just let DST end, and the stored instant moves by hours. VipManager
    // purges anything it reads as expired and there is no server to restore
    // from, so the VIP time is gone for good.
    group('persisted timestamps are zone-explicit (round 23)', () {
      test('toJson stamps UTC, so the string cannot be re-read as another zone',
          () {
        final e = VipEntry(
          key: 'ZONE',
          expiresAt: DateTime(2026, 8, 25, 10, 30),
          grantedAt: DateTime(2026, 8, 24, 10, 30),
        );
        final json = e.toJson();

        expect(json['expiresAt'], endsWith('Z'));
        expect(json['grantedAt'], endsWith('Z'));
        // Any reader, in any zone, resolves this to one instant.
        expect(DateTime.parse(json['expiresAt'] as String).isUtc, isTrue);
      });

      test('fromJson round-trips the exact instant and hands back local time',
          () {
        final e = VipEntry(
          key: 'ZONE',
          expiresAt: DateTime(2026, 8, 25, 10, 30),
          grantedAt: DateTime(2026, 8, 24, 10, 30),
        );
        final back = VipEntry.fromJson(e.toJson());

        expect(back.expiresAt.isAtSameMomentAs(e.expiresAt), isTrue);
        expect(back.grantedAt.isAtSameMomentAs(e.grantedAt), isTrue);
        // Local, so every existing consumer (display, countdown, difference)
        // behaves exactly as before the UTC switch.
        expect(back.expiresAt.isUtc, isFalse);
      });

      test('a legacy (pre-2.4.0) suffix-less payload still decodes', () {
        final back = VipEntry.fromJson(<String, dynamic>{
          'key': 'LEGACY',
          'expiresAt': '2026-08-25T10:30:00.000',
          'grantedAt': '2026-08-24T10:30:00.000',
        });
        expect(back.key, 'LEGACY');
        expect(back.expiresAt, DateTime(2026, 8, 25, 10, 30));
      });
    });
  });
}
