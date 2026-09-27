package com.example.ad_sdk_example

import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.widget.RatingBar
import android.widget.TextView
import com.google.android.gms.ads.nativead.MediaView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.NativeAdFactory

/**
 * T228 — reference `NativeAdFactory` a host app registers so
 * `NativeAdWidget(factoryId: "t228CustomNativeAd")` in Dart routes to THIS
 * layout instead of `google_mobile_ads`' built-in template.
 *
 * This is the actual native-platform-code half of AdMob custom native ad
 * layouts. `packages/ad_sdk` (the pure-Dart SDK package) has no `android/`
 * directory of its own and cannot ship this — it must live in every
 * consuming app, exactly like this file does for the example app. See
 * `res/layout/t228_custom_native_ad.xml` for the layout this inflates, and
 * `MainActivity.kt` for the registration call.
 *
 * The `AdChoicesView` in the XML layout is NOT optional — Google's own
 * native-ad policy requires it in every custom layout; the SDK cannot draw
 * it for you here (unlike AppLovin's Dart-side `MaxNativeAdOptionsView`)
 * because this whole view lives outside Flutter's widget tree.
 */
class T228CustomNativeAdFactory(private val layoutInflater: LayoutInflater) :
    NativeAdFactory {
  override fun createNativeAd(
      nativeAd: NativeAd,
      customOptions: MutableMap<String, Any>?,
  ): NativeAdView {
    // Real-device smoke-test proof this factory (not Google's built-in
    // template) actually ran — grep for this tag in logcat.
    Log.d("T228NativeFactory", "createNativeAd: custom layout inflated")
    val adView =
        layoutInflater.inflate(R.layout.t228_custom_native_ad, null) as NativeAdView

    adView.mediaView = adView.findViewById<MediaView>(R.id.t228_ad_media)
    adView.headlineView = adView.findViewById(R.id.t228_ad_headline)
    adView.bodyView = adView.findViewById(R.id.t228_ad_body)
    adView.callToActionView = adView.findViewById(R.id.t228_ad_call_to_action)
    adView.iconView = adView.findViewById(R.id.t228_ad_icon)
    adView.starRatingView = adView.findViewById(R.id.t228_ad_stars)
    adView.advertiserView = adView.findViewById(R.id.t228_ad_advertiser)
    // Mandatory attribution — see class doc comment above.
    adView.adChoicesView = adView.findViewById(R.id.t228_ad_choices)

    (adView.headlineView as TextView).text = nativeAd.headline

    val body = nativeAd.body
    adView.bodyView?.visibility = if (body == null) View.INVISIBLE else View.VISIBLE
    if (body != null) (adView.bodyView as TextView).text = body

    nativeAd.mediaContent?.let { adView.mediaView?.mediaContent = it }

    val cta = nativeAd.callToAction
    adView.callToActionView?.visibility = if (cta == null) View.INVISIBLE else View.VISIBLE
    if (cta != null) {
      (adView.callToActionView as android.widget.Button).text = cta
      // As with Google's own reference factory: the CTA button must not
      // consume touches directly — the SDK's own click-through handling on
      // adView.callToActionView does that once setNativeAd() runs below.
      adView.callToActionView?.isEnabled = false
      adView.callToActionView?.isClickable = false
    }

    val icon = nativeAd.icon
    if (icon == null) {
      adView.iconView?.visibility = View.GONE
    } else {
      (adView.iconView as android.widget.ImageView).setImageDrawable(icon.drawable)
      adView.iconView?.visibility = View.VISIBLE
    }

    val rating = nativeAd.starRating
    if (rating == null) {
      adView.starRatingView?.visibility = View.INVISIBLE
    } else {
      (adView.starRatingView as RatingBar).rating = rating.toFloat()
      adView.starRatingView?.visibility = View.VISIBLE
    }

    val advertiser = nativeAd.advertiser
    adView.advertiserView?.visibility =
        if (advertiser == null) View.INVISIBLE else View.VISIBLE
    if (advertiser != null) (adView.advertiserView as TextView).text = advertiser

    // Tells the Google Mobile Ads SDK this view is fully populated — must be
    // the LAST call.
    adView.setNativeAd(nativeAd)
    return adView
  }
}
