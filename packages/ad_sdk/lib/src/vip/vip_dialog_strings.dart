import 'dart:ui' show Locale, PlatformDispatcher;

/// Strings displayed by the Cupertino VIP redeem dialog.
///
/// Override via [AdConfig.vipDialogStrings] to localise, or use one of the
/// built-in presets: [VipDialogStrings.en] (identical to the plain
/// defaults), [VipDialogStrings.vi], or [VipDialogStrings.resolve] to pick
/// between the two automatically from a locale.
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
      successMessageBuilder?.call(validUntil) ??
      'VIP active until $validUntil.';

  final String failedTitle;
  final String failedMessage;
  final String networkErrorMessage;
  final String confirmButton;

  /// T219 — same reasoning as `CcpaOptOutStrings.en`: this class previously
  /// had NO named presets at all — a host wanting English (the plain
  /// defaults) had no discoverable name for it, only "pass nothing".
  static const VipDialogStrings en = VipDialogStrings();

  /// T219 — Vietnamese-localised strings. Previously only demonstrated in
  /// this class's own doc comment as a copy-paste example — promoted to a
  /// real, tested preset here, same text.
  static const VipDialogStrings vi = VipDialogStrings(
    verifyingTitle: 'Đang xác thực',
    verifyingMessage: 'Vui lòng chờ trong giây lát...',
    successTitle: 'Kích hoạt thành công',
    successMessageBuilder: _viSuccessMessage,
    failedTitle: 'Mã không hợp lệ',
    failedMessage: 'Mã VIP bạn nhập không đúng hoặc đã hết hạn.',
    networkErrorMessage: 'Lỗi mạng — vui lòng thử lại.',
    confirmButton: 'OK',
  );

  /// T219 — picks [vi] for a Vietnamese device locale, [en] otherwise.
  static VipDialogStrings resolve([Locale? locale]) {
    final languageCode =
        (locale ?? PlatformDispatcher.instance.locale).languageCode;
    return languageCode == 'vi' ? vi : en;
  }
}

// A const constructor's default-value expression must itself be a
// compile-time constant — a top-level function tear-off qualifies, an
// inline closure literal does not, so `vi`'s successMessageBuilder is
// wired to this instead of an inline `(until) => '...'` lambda.
String _viSuccessMessage(String validUntil) =>
    'VIP của bạn có hiệu lực đến $validUntil.';
