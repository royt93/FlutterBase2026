import 'package:applovin_admob_sdk/src/config/compatibility_matrix.dart';

void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('platform and provider required');
  final platform = args[0] == 'android'
      ? CompatibilityPlatform.android
      : CompatibilityPlatform.ios;
  final provider = args[1] == 'admob'
      ? CompatibilityProvider.admob
      : CompatibilityProvider.appLovin;
  CompatibilityMatrix.validate([
    CompatibilityTarget(
        flutter: '3.35.1',
        platform: platform,
        provider: provider,
        apiLevel: platform == CompatibilityPlatform.android ? 34 : 26),
  ]);
}
