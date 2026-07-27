// R10 Fix 3 — the example app must mirror the host app's Android Auto
// Backup configuration for `FlutterSharedPreferences.xml` (where
// AdPreferences.isFirstInstallGraceApplied()'s flag lives), so a reinstall
// on the same Google account restores the flag and the first-install VIP
// grace guard correctly refuses to re-grant. Plain static-content assertions
// against the checked-in XML/manifest files — no Dart logic under test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final exampleAndroidDir =
      Directory('example/android/app/src/main/').existsSync()
          ? 'example/android/app/src/main'
          : 'android/app/src/main'; // when run from packages/ad_sdk/example

  test('example AndroidManifest.xml declares Android Auto Backup', () {
    final manifest =
        File('$exampleAndroidDir/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:allowBackup="true"'));
    expect(manifest,
        contains('android:fullBackupContent="@xml/full_backup_content"'));
    expect(manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
  });

  test('example full_backup_content.xml includes FlutterSharedPreferences.xml',
      () {
    final xml = File('$exampleAndroidDir/res/xml/full_backup_content.xml')
        .readAsStringSync();
    expect(
        xml,
        contains(
            '<include domain="sharedpref" path="FlutterSharedPreferences.xml" />'));
    expect(xml, isNot(contains('<exclude')),
        reason: 'an explicit <exclude> not nested under an <include> fails '
            'the Android lint FullBackupContent check');
  });

  test(
      'example data_extraction_rules.xml includes FlutterSharedPreferences.xml '
      'in both cloud-backup and device-transfer', () {
    final xml = File('$exampleAndroidDir/res/xml/data_extraction_rules.xml')
        .readAsStringSync();
    expect(xml, contains('<cloud-backup>'));
    expect(xml, contains('<device-transfer>'));
    final includeCount =
        '<include domain="sharedpref" path="FlutterSharedPreferences.xml" />'
            .allMatches(xml)
            .length;
    expect(includeCount, 2,
        reason:
            'must be included in both <cloud-backup> and <device-transfer>');
  });
}
