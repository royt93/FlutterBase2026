/// Strings displayed by the Cupertino VIP redeem dialog.
///
/// Override via [AdConfig.vipDialogStrings] to localise. Defaults are English.
///
/// Tiếng Việt example:
/// ```dart
/// VipDialogStrings(
///   verifyingTitle: 'Đang xác thực',
///   verifyingMessage: 'Vui lòng chờ trong giây lát...',
///   successTitle: 'Kích hoạt thành công',
///   successMessageBuilder: (until) => 'VIP của bạn có hiệu lực đến \$until.',
///   failedTitle: 'Mã không hợp lệ',
///   failedMessage: 'Mã VIP bạn nhập không đúng hoặc đã hết hạn.',
///   networkErrorMessage: 'Lỗi mạng — vui lòng thử lại.',
///   confirmButton: 'OK',
/// );
/// ```
class VipDialogStrings {
  const VipDialogStrings({
    this.verifyingTitle = 'Verifying',
    this.verifyingMessage = 'Please wait a moment…',
    this.successTitle = 'VIP Activated',
    this.successMessageBuilder,
    this.failedTitle = 'Invalid Key',
    this.failedMessage = 'The VIP key you entered is invalid or expired.',
    this.networkErrorMessage = 'Network error — please try again.',
    this.confirmButton = 'OK',
  });

  final String verifyingTitle;
  final String verifyingMessage;
  final String successTitle;

  /// Builder for the success message. Receives the formatted "valid until"
  /// date string. Default builds: `VIP active until [date]`.
  final String Function(String validUntil)? successMessageBuilder;

  String successMessage(String validUntil) =>
      successMessageBuilder?.call(validUntil) ?? 'VIP active until $validUntil.';

  final String failedTitle;
  final String failedMessage;
  final String networkErrorMessage;
  final String confirmButton;
}
