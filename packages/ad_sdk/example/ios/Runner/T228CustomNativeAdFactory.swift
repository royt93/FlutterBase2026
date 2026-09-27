import UIKit
import google_mobile_ads

/// T228 — reference `FLTNativeAdFactory` a host app registers so
/// `NativeAdWidget(factoryId: "t228CustomNativeAd")` in Dart routes to THIS
/// layout instead of `google_mobile_ads`' built-in template.
///
/// This is the actual native-platform-code half of AdMob custom native ad
/// layouts. `packages/ad_sdk` (the pure-Dart SDK package) has no `ios/`
/// directory of its own and cannot ship this — it must live in every
/// consuming app, exactly like this file does for the example app. See
/// `AppDelegate.swift` for the registration call, and
/// `T228CustomNativeAdFactory.kt` for the Android equivalent.
///
/// Built entirely in code (no .xib) to keep this a single self-contained
/// file to copy into a host app.
///
/// `adChoicesView` is NOT optional — Google's own native-ad policy requires
/// it in every custom layout; the SDK cannot draw it for you here (unlike
/// AppLovin's Dart-side `MaxNativeAdOptionsView`) because this whole view
/// lives outside Flutter's widget tree.
final class T228CustomNativeAdFactory: NSObject, FLTNativeAdFactory {
  func createNativeAd(
    _ nativeAd: NativeAd,
    customOptions: [AnyHashable: Any]?
  ) -> NativeAdView? {
    let adView = NativeAdView(frame: .zero)
    adView.translatesAutoresizingMaskIntoConstraints = false

    let iconView = UIImageView()
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 40).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true
    adView.iconView = iconView

    let headlineLabel = UILabel()
    headlineLabel.font = .boldSystemFont(ofSize: 16)
    adView.headlineView = headlineLabel

    let bodyLabel = UILabel()
    bodyLabel.font = .systemFont(ofSize: 13)
    bodyLabel.numberOfLines = 2
    adView.bodyView = bodyLabel

    let mediaView = MediaView()
    mediaView.translatesAutoresizingMaskIntoConstraints = false
    mediaView.heightAnchor.constraint(equalToConstant: 180).isActive = true
    adView.mediaView = mediaView

    let ctaButton = UIButton(type: .system)
    ctaButton.backgroundColor = .systemBlue
    ctaButton.setTitleColor(.white, for: .normal)
    // Mirrors Google's own reference factory (AppDelegate.m in
    // google_mobile_ads' example app): the SDK's own click-through handling
    // on adView.callToActionView takes over once nativeAd is assigned
    // below, so this button must not process touch events itself.
    ctaButton.isUserInteractionEnabled = false
    adView.callToActionView = ctaButton

    let advertiserLabel = UILabel()
    advertiserLabel.font = .systemFont(ofSize: 12)
    adView.advertiserView = advertiserLabel

    let starRatingView = UIImageView()  // placeholder view; real hosts may
    // use a star-rating control — kept minimal for this reference factory.
    adView.starRatingView = starRatingView

    let adChoicesView = AdChoicesView()
    adView.adChoicesView = adChoicesView

    let headerRow = UIStackView(arrangedSubviews: [iconView, headlineLabel])
    headerRow.axis = .horizontal
    headerRow.spacing = 8
    headerRow.alignment = .center

    let topRow = UIStackView(arrangedSubviews: [headerRow, adChoicesView])
    topRow.axis = .horizontal
    topRow.distribution = .equalSpacing

    let column = UIStackView(arrangedSubviews: [
      topRow, bodyLabel, mediaView, advertiserLabel, ctaButton,
    ])
    column.axis = .vertical
    column.spacing = 8
    column.translatesAutoresizingMaskIntoConstraints = false
    adView.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(
        equalTo: adView.leadingAnchor, constant: 12),
      column.trailingAnchor.constraint(
        equalTo: adView.trailingAnchor, constant: -12),
      column.topAnchor.constraint(equalTo: adView.topAnchor, constant: 12),
      column.bottomAnchor.constraint(
        equalTo: adView.bottomAnchor, constant: -12),
    ])

    headlineLabel.text = nativeAd.headline
    bodyLabel.text = nativeAd.body
    bodyLabel.isHidden = nativeAd.body == nil
    advertiserLabel.text = nativeAd.advertiser
    advertiserLabel.isHidden = nativeAd.advertiser == nil
    iconView.image = nativeAd.icon?.image
    iconView.isHidden = nativeAd.icon == nil
    mediaView.mediaContent = nativeAd.mediaContent
    ctaButton.setTitle(nativeAd.callToAction, for: .normal)
    ctaButton.isHidden = nativeAd.callToAction == nil

    // Tells the Google Mobile Ads SDK this view is fully populated — must
    // be the LAST call.
    adView.nativeAd = nativeAd
    return adView
  }
}
