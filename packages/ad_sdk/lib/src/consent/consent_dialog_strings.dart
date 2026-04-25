/// Localisation strings for the consent dialog.
///
/// Override every field to translate. Defaults are English. Keep messages
/// short — the dialog body does not scroll well past ~6 lines.
class ConsentDialogStrings {
  const ConsentDialogStrings({
    this.title = 'Privacy & Personalized Ads',
    this.message =
        'This app shows ads to keep it free. With your permission, we '
            'can show ads matched to your interests instead of generic ones. '
            'You can change this anytime in Settings.',
    this.allowButton = 'Allow personalized ads',
    this.rejectButton = 'No thanks',
    this.privacyPolicyLabel = 'Privacy Policy',
    this.privacyPolicyUrl,
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

  /// Convenience: Vietnamese-localised strings.
  static const ConsentDialogStrings vi = ConsentDialogStrings(
    title: 'Quảng cáo cá nhân hoá',
    message: 'Ứng dụng hiển thị quảng cáo để duy trì miễn phí. Nếu bạn '
        'đồng ý, chúng tôi sẽ hiển thị quảng cáo phù hợp với sở thích của bạn '
        'thay vì quảng cáo chung. Bạn có thể thay đổi bất cứ lúc nào trong Cài đặt.',
    allowButton: 'Đồng ý',
    rejectButton: 'Từ chối',
    privacyPolicyLabel: 'Chính sách bảo mật',
  );
}
