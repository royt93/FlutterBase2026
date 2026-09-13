import 'dart:convert';
import 'dart:io';

import 'package:applovin_admob_sdk/src/config/compatibility_matrix.dart';

/// Audit fix (post-T215) — this used to hardcode `flutter: '3.35.1'`
/// (duplicating, not reading, the version CI's own `flutter-version:
/// '3.35.1'` step config pins) and a hardcoded `apiLevel`. Combined with
/// [CompatibilityMatrix.isSupported]'s own old floor-only check, the whole
/// gate validated a constant against itself and could never fail — if CI's
/// pinned Flutter version were ever bumped to something genuinely
/// incompatible without this file being updated too (or vice versa),
/// nothing here would have caught it. This reads the REAL running
/// `flutter` binary's version instead, so the check reflects whatever
/// Flutter is actually installed in the environment this script runs in.
Future<String> resolveRealFlutterVersion() async {
  final result = await Process.run('flutter', ['--version', '--machine']);
  if (result.exitCode != 0) {
    throw StateError(
        'flutter --version --machine failed (exit ${result.exitCode}): '
        '${result.stderr}');
  }
  final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final version = decoded['frameworkVersion'] as String?;
  if (version == null || version.isEmpty) {
    throw StateError(
        'flutter --version --machine did not report a frameworkVersion: '
        '${result.stdout}');
  }
  return version;
}

Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('platform and provider required');
  final platform = args[0] == 'android'
      ? CompatibilityPlatform.android
      : CompatibilityPlatform.ios;
  final provider = args[1] == 'admob'
      ? CompatibilityProvider.admob
      : CompatibilityProvider.appLovin;
  final realFlutterVersion = await resolveRealFlutterVersion();
  // API level isn't something `flutter --version` reports and isn't tied
  // to a real running device in this CI job (it builds, doesn't run, on a
  // simulated/no device) — kept as the SDK's own documented minimum target
  // per platform, same as before this fix; the part that was actually
  // fake (the Flutter version) is what changed.
  CompatibilityMatrix.validate([
    CompatibilityTarget(
        flutter: realFlutterVersion,
        platform: platform,
        provider: provider,
        apiLevel: platform == CompatibilityPlatform.android ? 34 : 26),
  ]);
  // ignore: avoid_print
  print('compatibility matrix OK: flutter=$realFlutterVersion '
      'platform=${args[0]} provider=${args[1]}');
}
