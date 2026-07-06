import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolvePlatformAdUnitId (T15)', () {
    test('isAndroid=true with androidId set returns androidId', () {
      final id = resolvePlatformAdUnitId(
        fallback: 'fallback',
        androidId: 'android-id',
        iosId: 'ios-id',
        isAndroid: true,
        isIos: false,
      );
      expect(id, 'android-id');
    });

    test('isIos=true with iosId set returns iosId', () {
      final id = resolvePlatformAdUnitId(
        fallback: 'fallback',
        androidId: 'android-id',
        iosId: 'ios-id',
        isAndroid: false,
        isIos: true,
      );
      expect(id, 'ios-id');
    });

    test('no override on either platform returns fallback', () {
      final id = resolvePlatformAdUnitId(
        fallback: 'fallback',
        androidId: null,
        iosId: null,
        isAndroid: true,
        isIos: false,
      );
      expect(id, 'fallback');
    });

    test('empty-string override is treated as absent, returns fallback', () {
      final android = resolvePlatformAdUnitId(
        fallback: 'fallback',
        androidId: '',
        iosId: null,
        isAndroid: true,
        isIos: false,
      );
      final ios = resolvePlatformAdUnitId(
        fallback: 'fallback',
        androidId: null,
        iosId: '',
        isAndroid: false,
        isIos: true,
      );
      expect(android, 'fallback');
      expect(ios, 'fallback');
    });
  });
}
