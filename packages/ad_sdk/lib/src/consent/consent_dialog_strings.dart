/// Localisation strings for the consent dialog.
///
/// Override every field to translate. Defaults are English. Keep messages
/// short — the dialog body does not scroll well past ~6 lines.
class ConsentDialogStrings {
  const ConsentDialogStrings({
    this.title = 'Privacy & Personalized Ads',
    this.message = 'This app is free and supported by ads — you will see '
        'ads either way. With your permission, we can use your advertising '
        'ID to personalize them to your interests instead of showing '
        'generic ads. Change this anytime in Settings.',
    this.allowButton = 'Allow personalized ads',
    this.rejectButton = 'No thanks',
    this.privacyPolicyLabel = 'Privacy Policy',
    this.privacyPolicyUrl,
    this.adPartnersLabel = 'Ad partners: $autoProvidersToken',
  });

  final String title;
  final String message;
  final String allowButton;
  final String rejectButton;

  /// Tappable label appended below [message]. Hidden if [privacyPolicyUrl]
  /// is null. Caller is responsible for handling the tap (we just expose it
  /// via the dialog callback).
  final String privacyPolicyLabel;
  final String? privacyPolicyUrl;

  /// Small transparency caption naming the ad networks that may receive
  /// consent signals from this dialog. Set to `null` to hide it.
  ///
  /// T167 — the default contains [autoProvidersToken] (`'{providers}'`),
  /// which `showConsentDialog` substitutes with the network(s) this app is
  /// ACTUALLY configured for (`AdConfig.provider`) at render time — this
  /// SDK supports exactly one active provider per app (AdMob XOR AppLovin,
  /// never both at once; see [AdProvider]), so naming both unconditionally
  /// (the pre-T167 hardcoded default) misstated who receives the user's
  /// data for every single integration, not just a rare misconfiguration.
  /// A custom string with no [autoProvidersToken] in it (a full manual
  /// override) is used exactly as given, with no substitution — this only
  /// touches the SDK's own default.
  final String? adPartnersLabel;

  /// T167 — substituted for the real, actually-configured ad network
  /// name(s) inside [adPartnersLabel] at render time. Only present in the
  /// two SDK-provided defaults below; a fully custom [adPartnersLabel]
  /// naturally has none of these and is left untouched.
  static const autoProvidersToken = '{providers}';

  /// Convenience: Vietnamese-localised strings.
  static const ConsentDialogStrings vi = ConsentDialogStrings(
    title: 'Quảng cáo cá nhân hoá',
    message: 'Ứng dụng này miễn phí nhờ quảng cáo — dù chọn thế nào bạn vẫn '
        'sẽ thấy quảng cáo. Nếu bạn đồng ý, chúng tôi sẽ dùng mã quảng cáo '
        '(advertising ID) để cá nhân hoá quảng cáo theo sở thích thay vì '
        'quảng cáo chung. Bạn có thể đổi lựa chọn này bất cứ lúc nào trong '
        'Cài đặt.',
    allowButton: 'Đồng ý',
    rejectButton: 'Từ chối',
    privacyPolicyLabel: 'Chính sách bảo mật',
    adPartnersLabel: 'Đối tác quảng cáo: $autoProvidersToken',
  );
}
