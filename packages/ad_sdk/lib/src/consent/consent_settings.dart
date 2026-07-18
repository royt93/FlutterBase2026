import 'dart:convert';

import '../core/ad_consent.dart';

/// Persistent record of the user's consent choices.
///
/// Layered above [AdConsent]: [AdConsent] is the runtime flag struct
/// forwarded to providers, [ConsentSettings] is the durable user-state
/// (which flag values they chose, plus when they were asked).
class ConsentSettings {
  const ConsentSettings({
    this.hasUserConsent = false,
    this.isAgeRestrictedUser = false,
    this.doNotSell = false,
    this.hasBeenAsked = false,
    this.askedAt,
    this.country,
  });

  /// True if user agreed to personalized ads (GDPR / generic).
  final bool hasUserConsent;

  /// True if app is directed to children < 13 (COPPA). Usually a compile-time
  /// constant per-app, not per-user — but exposed here for completeness.
  final bool isAgeRestrictedUser;

  /// True if user opted out of "sale" of personal data (CCPA).
  final bool doNotSell;

  /// True after the consent dialog has been presented (user picked Accept,
  /// Reject, or dismissed it). Used to suppress auto-show on subsequent
  /// launches — caller can still call `showDialog()` from a settings page.
  final bool hasBeenAsked;

  /// When [hasBeenAsked] flipped true. Useful for analytics + GDPR audit
  /// trail (some regulators require timestamp evidence of consent capture).
  final DateTime? askedAt;

  /// ISO country code for consent analytics (e.g. `'DE'`, `'US'`).
  ///
  /// The SDK does **not** self-derive the user's real country — UMP only
  /// exposes an EEA/non-EEA classification plus a debug-only override, not a
  /// real geolocation. This is only populated when `AdConfig.umpDebugGeography`
  /// is set (test/QA), or when the host app supplies it itself (e.g. from
  /// `Platform.localeName` or the host's own GeoIP service). Do not treat this
  /// as accurate geolocation.
  final String? country;

  /// Default for a fresh install: not asked yet, conservative non-personalized.
  static const ConsentSettings unset = ConsentSettings();

  /// Convenience: settings representing "user accepted personalized ads".
  static ConsentSettings get accepted => ConsentSettings(
        hasUserConsent: true,
        hasBeenAsked: true,
        askedAt: DateTime.now(),
      );

  /// Convenience: settings representing "user rejected personalized ads".
  static ConsentSettings get rejected => ConsentSettings(
        hasUserConsent: false,
        hasBeenAsked: true,
        askedAt: DateTime.now(),
      );

  ConsentSettings copyWith({
    bool? hasUserConsent,
    bool? isAgeRestrictedUser,
    bool? doNotSell,
    bool? hasBeenAsked,
    DateTime? askedAt,
    String? country,
  }) =>
      ConsentSettings(
        hasUserConsent: hasUserConsent ?? this.hasUserConsent,
        isAgeRestrictedUser: isAgeRestrictedUser ?? this.isAgeRestrictedUser,
        doNotSell: doNotSell ?? this.doNotSell,
        hasBeenAsked: hasBeenAsked ?? this.hasBeenAsked,
        askedAt: askedAt ?? this.askedAt,
        country: country ?? this.country,
      );

  /// Project to the runtime flag struct used by `applyConsentToProviders`.
  AdConsent toAdConsent() => AdConsent(
        hasUserConsent: hasUserConsent,
        isAgeRestrictedUser: isAgeRestrictedUser,
        doNotSell: doNotSell,
      );

  Map<String, dynamic> toJson() => {
        'hasUserConsent': hasUserConsent,
        'isAgeRestrictedUser': isAgeRestrictedUser,
        'doNotSell': doNotSell,
        'hasBeenAsked': hasBeenAsked,
        'askedAt': askedAt?.toIso8601String(),
        'country': country,
      };

  factory ConsentSettings.fromJson(Map<String, dynamic> j) => ConsentSettings(
        hasUserConsent: j['hasUserConsent'] as bool? ?? false,
        isAgeRestrictedUser: j['isAgeRestrictedUser'] as bool? ?? false,
        doNotSell: j['doNotSell'] as bool? ?? false,
        hasBeenAsked: j['hasBeenAsked'] as bool? ?? false,
        askedAt: j['askedAt'] is String
            ? DateTime.tryParse(j['askedAt'] as String)
            : null,
        country: j['country'] as String?,
      );

  static String encode(ConsentSettings s) => jsonEncode(s.toJson());

  static ConsentSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return ConsentSettings.unset;
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) return ConsentSettings.fromJson(j);
    } catch (_) {}
    return ConsentSettings.unset;
  }

  @override
  String toString() => 'ConsentSettings(consent=$hasUserConsent, '
      'coppa=$isAgeRestrictedUser, ccpa=$doNotSell, '
      'asked=$hasBeenAsked${askedAt != null ? ' @${askedAt!.toIso8601String()}' : ''})';
}
