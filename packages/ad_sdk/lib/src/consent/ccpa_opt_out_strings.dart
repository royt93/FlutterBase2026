import 'dart:ui' show Locale, PlatformDispatcher;

/// Localisation strings for [CcpaOptOutToggle].
///
/// Override every field to translate. Defaults are English.
class CcpaOptOutStrings {
  const CcpaOptOutStrings({
    this.title = 'Do Not Sell or Share My Personal Information',
    this.subtitle = 'California residents (CCPA/CPRA) can opt out of the '
        '"sale" or "sharing" of personal information used for '
        'personalized ads. Turning this on switches ads on this device '
        'to a non-personalized mode.',
  });

  final String title;
  final String subtitle;

  /// Convenience: Vietnamese-localised strings.
  static const CcpaOptOutStrings vi = CcpaOptOutStrings(
    title: 'Không bán hoặc chia sẻ thông tin cá nhân của tôi',
    subtitle: 'Cư dân California (CCPA/CPRA) có quyền từ chối việc "bán" '
        'hoặc "chia sẻ" thông tin cá nhân dùng để cá nhân hoá quảng cáo. '
        'Bật tuỳ chọn này sẽ chuyển quảng cáo trên thiết bị này sang chế '
        'độ không cá nhân hoá.',
  );

  /// T219 — this class previously had NO named presets at all — a host
  /// wanting English (the plain defaults) had no discoverable name for it,
  /// only "pass nothing".
  static const CcpaOptOutStrings en = CcpaOptOutStrings();

  /// T219 — picks [vi] for a Vietnamese device locale, [en] otherwise.
  static CcpaOptOutStrings resolve([Locale? locale]) {
    final languageCode =
        (locale ?? PlatformDispatcher.instance.locale).languageCode;
    return languageCode == 'vi' ? vi : en;
  }
}
