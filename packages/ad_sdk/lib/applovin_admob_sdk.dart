/// applovin_admob_sdk — Dual-provider Flutter ad SDK with adapter pattern.
///
/// Supports Google AdMob and AppLovin MAX through a unified API surface.
/// See `README.md` for the full integration guide (English + Tiếng Việt).
library;

// Compliance report export (T23)
export 'src/compliance/ad_event_log.dart';
export 'src/compliance/compliance_report.dart';

// Configuration
export 'src/config/ad_config.dart';
export 'src/config/ad_log_level.dart';

// Consent (binary dialog + manager)
export 'src/consent/consent_dialog.dart' show showConsentDialog;
export 'src/consent/consent_dialog_strings.dart';
export 'src/consent/consent_manager.dart';
export 'src/consent/consent_settings.dart';

// Orchestrator
export 'src/core/ad_consent.dart' show AdConsent;
export 'src/core/ad_manager.dart';
export 'src/core/ad_provider_adapter.dart'
    show AdProviderAdapter, BannerListenables, RewardResult;
export 'src/core/ad_route_observer.dart';
export 'src/core/ad_safety_config.dart'
    show AdSafetyConfig, AdSafetyParams, AdSafetyResult, AdSafetySnapshot;
export 'src/core/ad_screen.dart';
export 'src/core/event_bus.dart';
export 'src/core/integration_self_check.dart';
export 'src/core/ump_consent.dart' show UmpConsentResult, requestUmpConsentFlow;
export 'src/core/att_consent.dart'
    show AttStatus, AttResult, requestAttIfNeeded;

// Monetization (opt-in Smart Monetization Arbitrator + fill-rate monitor)
export 'src/monetization/ad_diagnostics.dart';
export 'src/monetization/fill_rate_monitor.dart';
export 'src/monetization/monetization_arbitrator.dart';
// Re-export Google's UMP enums so callers don't need a direct google_mobile_ads import.
export 'package:google_mobile_ads/google_mobile_ads.dart'
    show ConsentStatus, DebugGeography;

// State machine
export 'src/state/ad_event.dart';
export 'src/state/ad_placement.dart';
export 'src/state/ad_slot.dart';
export 'src/state/backoff.dart';

// Utilities
export 'src/utils/safe_logger.dart' show SafeLogger, AdLogSink;

// VIP
export 'src/vip/signed_vip_key.dart'
    show
        SignedVipKey,
        SignedVipRedeemResult,
        VipKeyException,
        VipRedeemStatus,
        verifySignedVipKey;
export 'src/vip/vip_dialog_strings.dart';
export 'src/vip/vip_entry.dart';
export 'src/vip/vip_manager.dart';
export 'src/vip/vip_redeem_screen.dart' show VipRedeemScreen, VipRedeemStrings;

// Widgets
export 'src/widget/ad_loading_dialog.dart';
export 'src/widget/banner_ad_widget.dart';
export 'src/widget/debug_ad_overlay.dart';
export 'src/widget/mrec_ad_widget.dart';
export 'src/widget/native_ad_widget.dart';
export 'src/widget/revenue_panel.dart';
export 'src/widget/top_toast.dart';
