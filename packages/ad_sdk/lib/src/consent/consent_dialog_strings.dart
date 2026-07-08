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
    this.adPartnersLabel = 'Ad partners: Google AdMob, AppLovin',
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
  final String? adPartnersLabel;

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
    adPartnersLabel: 'Đối tác quảng cáo: Google AdMob, AppLovin',
  );
}
