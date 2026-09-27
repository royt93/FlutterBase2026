import Flutter
import UIKit
import google_mobile_ads

// T228 — the factoryId a host passes to NativeAdWidget(factoryId: ...) in
// Dart must match this string exactly; see lib/main.dart's demo call site.
private let t228NativeAdFactoryId = "t228CustomNativeAd"

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // T228 — held for the app's lifetime; registerNativeAdFactory does not
  // retain it.
  private let t228NativeAdFactory = T228CustomNativeAdFactory()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // T228 — registers the reference NativeAdFactory
    // (T228CustomNativeAdFactory.swift) so
    // NativeAdWidget(factoryId: "t228CustomNativeAd") renders this app's own
    // layout instead of Google's built-in template. A real host app copies
    // this pattern with its own factoryId/layout — the SDK itself cannot do
    // this for you (see the T228 class doc comment on
    // T228CustomNativeAdFactory).
    _ = FLTGoogleMobileAdsPlugin.registerNativeAdFactory(
      engineBridge.pluginRegistry,
      factoryId: t228NativeAdFactoryId,
      nativeAdFactory: t228NativeAdFactory
    )
  }
}
