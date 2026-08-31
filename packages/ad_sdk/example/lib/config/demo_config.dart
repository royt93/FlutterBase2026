// T117 — DemoConfig + example-only constants (AppLovin placeholder ad-unit
// IDs, VIP demo keys, safety preset). Split out of main.dart.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../shared/log_buffer.dart';

// ═══════════════════════════════════════════════════════════════════════════
// §1  Constants + DemoConfig + VIP validator
// ═══════════════════════════════════════════════════════════════════════════

// T41 — no real AppLovin credentials are committed to source. Placeholders
// below make the demo build/run out of the box (native init simply fails to
// load real creative — safe default, not a crash). Anyone who needs to
// exercise real ads locally passes their own IDs via --dart-define, e.g.:
//   flutter run --dart-define=APPLOVIN_SDK_KEY=... \
//     --dart-define=APPLOVIN_BANNER_ID_ANDROID=... \
//     --dart-define=APPLOVIN_BANNER_ID_IOS=... (…and _INTERSTITIAL_/_APPOPEN_/_REWARDED_ for each platform)
// See README.md "Compliance checklist".
const String _kAppLovinSdkKey = String.fromEnvironment('APPLOVIN_SDK_KEY',
    defaultValue: 'YOUR_86_CHAR_SDK_KEY_FROM_APPLOVIN_DASHBOARD');
final String _kAppLovinBannerId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_BANNER_ID_IOS',
        defaultValue: 'YOUR_BANNER_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_BANNER_ID_ANDROID',
        defaultValue: 'YOUR_BANNER_AD_UNIT_ID');
final String _kAppLovinInterstitialId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_INTERSTITIAL_ID_IOS',
        defaultValue: 'YOUR_INTERSTITIAL_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_INTERSTITIAL_ID_ANDROID',
        defaultValue: 'YOUR_INTERSTITIAL_AD_UNIT_ID');
final String _kAppLovinAppOpenId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_APPOPEN_ID_IOS',
        defaultValue: 'YOUR_APP_OPEN_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_APPOPEN_ID_ANDROID',
        defaultValue: 'YOUR_APP_OPEN_AD_UNIT_ID');
final String _kAppLovinRewardedId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_REWARDED_ID_IOS',
        defaultValue: 'YOUR_REWARDED_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_REWARDED_ID_ANDROID',
        defaultValue: 'YOUR_REWARDED_AD_UNIT_ID');
final String _kAppLovinMrecId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_MREC_ID_IOS',
        defaultValue: 'YOUR_MREC_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_MREC_ID_ANDROID',
        defaultValue: 'YOUR_MREC_AD_UNIT_ID');
final String _kAppLovinNativeId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_NATIVE_ID_IOS',
        defaultValue: 'YOUR_NATIVE_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_NATIVE_ID_ANDROID',
        defaultValue: 'YOUR_NATIVE_AD_UNIT_ID');

/// Provider for this app — defaults to `AdProvider.appLovin` since AppLovin is
/// the harder-to-exercise path (AdMob demo IDs are Google's public test
/// units; AppLovin needs real per-account IDs passed via --dart-define, see
/// above). Do not change this default to `AdProvider.admob` in source.
///
/// For integration-test runs that need to exercise the AdMob path, pass
/// `--dart-define=AD_PROVIDER_ADMOB=true` instead of editing this constant.
///
/// F8 — this `--dart-define` compile-time switch is a dev/test convenience
/// specific to this example app. Don't copy it verbatim into a real app: a
/// production app almost always hard-codes one provider (or picks it from a
/// remote config it controls), not an env flag toggled at build time.
const AdProvider kProvider = bool.fromEnvironment('AD_PROVIDER_ADMOB')
    ? AdProvider.admob
    : AdProvider.appLovin;

/// T41 — the loose QA safety preset ([kDemoSafetyParams]) is opt-in only, so
/// a release build of this example never ships with fraud/frequency caps
/// disabled. Pass `--dart-define=QA_AD_STRESS=true` to enable it locally.
const bool kQaAdStress = bool.fromEnvironment('QA_AD_STRESS');

// QA seam for the EEA consent path. Without it, a tester outside the EEA can
// never reach UMP's `required` branch: UMP resolves `notRequired`, no form is
// served, and every EEA-only code path stays unexercised (that blind spot is
// what let two consent bugs ship). `UMP_TEST_ID` is the hashed device id UMP
// prints to the log on first run — required, or debugGeography is ignored.
//   flutter run --dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>
const bool kUmpEeaDebug = bool.fromEnvironment('UMP_EEA_DEBUG');
const String kUmpTestId = String.fromEnvironment('UMP_TEST_ID');

/// Placeholder privacy-policy link shown by the consent dialog demo.
/// Real apps should point this at their own published policy.
const String kDemoPrivacyPolicyUrl = 'https://example.com/privacy';

/// VIP demo keys (Q28 — user-supplied).
const Map<String, Duration> kDemoVipKeys = {
  'TEST_VIP_7': Duration(days: 7),
  'TEST_VIP_30': Duration(days: 30),
  'TEST_VIP_90': Duration(days: 90),
};

/// ⚠️ DEMO KEYPAIR — DO NOT SHIP THIS.
///
/// This public key and the signed codes below are published in the SDK's
/// example app, so they are public knowledge: any app that ships this exact
/// public key grants VIP to anyone who pastes one of the demo codes.
///
/// Before releasing an app, generate your own keypair with
/// `dart run tool/vip_keygen.dart`, keep the PRIVATE key off the repo, and
/// mint real codes with `dart run tool/vip_mint.dart`. Only the public key
/// belongs in your binary.
///
/// T18 — offline SIGNED VIP keys. The public key below verifies the keys; the
/// matching private key (never shipped) minted them via tool/vip_mint.dart.
const String kDemoVipPublicKey = 'nqmoUYYjAH_dVDcO5fZk8EagjLIq688hPbAzIYD0DWY=';
const Map<String, String> kDemoSignedVipKeys = {
  '1d':
      'AVP1.ODY0MDB8ZGVtbzFk.NFrAVXDD8FUNpZzBQG_MDq_dgKVyE6HmRTn7TTxmbWT0_hIZX2_9PO1tX2SBMMWh-Mp5nt3d3hnNSbYuDI-tCA==',
  '7d':
      'AVP1.NjA0ODAwfGRlbW83ZA==.7lj_TWdPk3h8LWcBAQzU5dfwmfMeu0--inrlLckEgqtlx3LpNpPNOX4TNZ7ypHmfKRamSWErp6uyRDP54jAaAg==',
  '30d':
      'AVP1.MjU5MjAwMHxkZW1vMzBk.nCPvlNoexldaulVWw5IycTDM1Cr_pUmQQMuf0myVogbnTcrccs69LB40t1MtvPLNhakK0OPIM3e_GaXOsXKrDg==',
};

/// Validator wired into [AdConfig.vipKeyValidator] — only the demo keys above
/// are valid. In a real app this calls your server.
Future<bool> demoVipValidator(String key) async {
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return kDemoVipKeys.containsKey(key);
}

/// Builds the [AdConfig] used by the demo. Provider is a compile-time const
/// (`kProvider` above) — runtime swap is intentionally NOT exposed because
/// the SDK is designed to be initialised once per app process.

class DemoConfig {
  DemoConfig._();

  static final DemoConfig instance = DemoConfig._();

  AdConfig build() {
    return AdConfig(
      provider: kProvider,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
        mrecId: 'ca-app-pub-3940256099942544/2247696110',
        nativeId: 'ca-app-pub-3940256099942544/2247696110',
        // Optional per-platform overrides (T15) — omit to use the same id
        // on both platforms, as above:
        // androidBannerId: 'ca-app-pub-.../android-banner',
        // iosBannerId: 'ca-app-pub-.../ios-banner',
      ),
      appLovin: AppLovinConfig(
        sdkKey: _kAppLovinSdkKey,
        bannerId: _kAppLovinBannerId,
        interstitialId: _kAppLovinInterstitialId,
        appOpenId: _kAppLovinAppOpenId,
        rewardedId: _kAppLovinRewardedId,
        mrecId: _kAppLovinMrecId,
        nativeId: _kAppLovinNativeId,
      ),
      logLevel: AdLogLevel.verbose,
      onLog: LogBuffer.instance.sink,
      vipKeyValidator: demoVipValidator,
      // Cap the total stacked VIP window (cộng dồn) — demo at 90 days. null = uncapped.
      maxVipStackDuration: const Duration(days: 90),
      adNotReadyMessage: 'Ad not ready — please wait.',
      adLoadingMessage: 'Loading…',
      splashMaxDuration: const Duration(seconds: 8),
      umpDebugGeography: kUmpEeaDebug ? DebugGeography.debugGeographyEea : null,
      umpTestIdentifiers: kUmpTestId.isEmpty ? const [] : const [kUmpTestId],
      // T41 — the loose preset (999 caps, 2 s throttle, 0 s warm-up) only
      // applies with --dart-define=QA_AD_STRESS=true, so QA can pound the
      // buttons on demand without every debug/release build shipping with
      // fraud/frequency caps effectively disabled.
      // ⚠️ DO NOT copy kDemoSafetyParams into a production app — use
      // AdSafetyParams.auto (default) or AdSafetyParams.production there.
      safety: kQaAdStress ? kDemoSafetyParams : AdSafetyParams.auto,
      // First-install VIP grace: 30 s in debug (so QA can verify "after
      // grace expires, ads return" without waiting 24 h), 24 h in release.
      // Other options:
      //   FirstInstallVipGrace.disabled                    → never grant
      //   FirstInstallVipGrace.day                         → force 24 h both modes
      //   FirstInstallVipGrace(Duration(hours: 12))        → custom
      firstInstallVipGrace: FirstInstallVipGrace.auto,
      // Auto-show Cupertino consent dialog ~1 s after splash → home (skipped
      // for VIP users — first 30 s of debug install stays silent because
      // grace is active). Strings default to English; consumers override
      // via consentDialogStrings: ConsentDialogStrings.vi etc.
      autoShowConsentDialog: true,
      consentDialogPostSplashDelay: const Duration(seconds: 1),
      // Demo wires a real privacy-policy URL so the dialog's link isn't
      // silently hidden — a bare `debugPrint` handler is enough here since
      // this is a demo harness, not a shipping app (a real app would
      // `launchUrl(Uri.parse(url))`, e.g. via package:url_launcher).
      consentDialogStrings:
          const ConsentDialogStrings(privacyPolicyUrl: kDemoPrivacyPolicyUrl),
      onPrivacyPolicyTap: (url) =>
          debugPrint('[example] privacy policy tapped: $url'),
    );
  }
}

/// Single set of safety params used by this demo for both debug and release.
/// All caps are 999 / throttle 2 s / no warm-up — chosen for easy QA testing.
const AdSafetyParams kDemoSafetyParams = AdSafetyParams(
  minTimeBetweenFullscreenAds: 2000, // 2 s between fullscreen ads
  maxFullscreenAdsPerSession: 999,
  maxFullscreenAdsPerHour: 999,
  maxFullscreenAdsPerDay: 999,
  minSessionDurationBeforeAd: 0,
  minTimeAppOpenResume: 0,
  maxClicksPerMinute: 999,
  suspiciousCtrThreshold: 1.0, // CTR fraud check effectively disabled
  maxRapidResumesPerMinute: 999,
  dryRun: false,
);
