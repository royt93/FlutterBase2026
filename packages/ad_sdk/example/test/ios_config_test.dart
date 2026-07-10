// Regression guard: the example's Info.plist must declare SKAdNetworkItems
// (required by AdMob/AppLovin on iOS 14+ for attribution) and an
// AppLovinSdkKey placeholder (the SDK's four required native keys), or ad
// fill silently drops on iOS with no runtime error to point at why.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String plist;

  setUpAll(() {
    plist = File('ios/Runner/Info.plist').readAsStringSync();
  });

  test('declares a non-empty SKAdNetworkItems array', () {
    expect(plist, contains('<key>SKAdNetworkItems</key>'));
    final itemCount = 'SKAdNetworkIdentifier'.allMatches(plist).length;
    expect(itemCount, greaterThan(0),
        reason: 'SKAdNetworkItems must contain at least one identifier');
  });

  test('declares AppLovinSdkKey', () {
    expect(plist, contains('<key>AppLovinSdkKey</key>'));
  });

  test('declares GADApplicationIdentifier', () {
    expect(plist, contains('<key>GADApplicationIdentifier</key>'));
  });

  test('declares NSUserTrackingUsageDescription', () {
    expect(plist, contains('<key>NSUserTrackingUsageDescription</key>'));
  });
}
