import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around `SharedPreferences` for SDK-owned persistence.
///
/// Stores:
/// - VIP GAID list (1.x legacy, kept for migration)
/// - First-init flag (one-time VIP import)
/// - Daily ad count + day stamp (anti-fraud cap)
/// - Suspicious-violation count (progressive cooldown)
/// - VIP entries (2.x — JSON list of [VipEntry])
class AdPreferences {
  AdPreferences._();

  static AdPreferences? _instance;
  SharedPreferences? _prefs;

  static Future<AdPreferences> getInstance() async {
    var instance = _instance;
    if (instance == null) {
      instance = AdPreferences._();
      instance._prefs = await SharedPreferences.getInstance();
      _instance = instance;
    }
    return instance;
  }

  static AdPreferences? get instanceOrNull => _instance;

  // ─── Legacy VIP GAID list ─────────────────────────────────────────────────

  static const String _keyListGAID = 'ad_sdk_keyListGAID';
  static const String _keyAddVIPFirstInit = 'ad_sdk_keyAddVIPFirstInitSuccess';

  List<String> getGAIDList() => _prefs?.getStringList(_keyListGAID) ?? [];

  Future<void> saveGAIDList(List<String> list) async {
    await _prefs?.setStringList(_keyListGAID, list.toSet().toList());
  }

  bool isAddVIPMemberFirstInitSuccess() =>
      _prefs?.getBool(_keyAddVIPFirstInit) ?? false;

  Future<void> addVIPMemberFirstInitSuccess() async {
    await _prefs?.setBool(_keyAddVIPFirstInit, true);
  }

  // ─── Daily ad count (anti-fraud) ──────────────────────────────────────────

  static const String _keyDailyAdCount = 'ad_sdk_daily_count';
  static const String _keyDailyDate = 'ad_sdk_daily_date';
  static const String _keySuspiciousCount = 'ad_sdk_suspicious_count';

  int getDailyAdCount() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final saved = _prefs?.getString(_keyDailyDate) ?? '';
    if (saved != today) {
      _prefs?.setString(_keyDailyDate, today);
      _prefs?.setInt(_keyDailyAdCount, 0);
      return 0;
    }
    return _prefs?.getInt(_keyDailyAdCount) ?? 0;
  }

  Future<void> incrementDailyAdCount() async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final current = getDailyAdCount();
    await _prefs?.setInt(_keyDailyAdCount, current + 1);
    await _prefs?.setString(_keyDailyDate, today);
  }

  int getSuspiciousCount() => _prefs?.getInt(_keySuspiciousCount) ?? 0;

  Future<void> incrementSuspiciousCount() async {
    final current = getSuspiciousCount();
    await _prefs?.setInt(_keySuspiciousCount, current + 1);
  }

  // ─── First-install VIP grace ──────────────────────────────────────────────

  static const String _keyFirstInstallApplied =
      'ad_sdk_first_install_grace_applied';
  static const String _keyFirstInstallAt = 'ad_sdk_first_install_at_ms';

  bool isFirstInstallGraceApplied() =>
      _prefs?.getBool(_keyFirstInstallApplied) ?? false;

  Future<void> markFirstInstallGraceApplied() async {
    await _prefs?.setBool(_keyFirstInstallApplied, true);
  }

  /// Epoch-ms of the first SDK init on this install. Set on first init,
  /// preserved across hot-restart but lost on app data clear / reinstall.
  int? getFirstInstallAtMs() => _prefs?.getInt(_keyFirstInstallAt);

  Future<void> setFirstInstallAtMsIfMissing(int epochMs) async {
    if (_prefs?.getInt(_keyFirstInstallAt) != null) return;
    await _prefs?.setInt(_keyFirstInstallAt, epochMs);
  }

  // ─── Consent settings (JSON) ──────────────────────────────────────────────

  static const String _keyConsentSettings = 'ad_sdk_consent_settings_v1';

  String? getConsentSettingsRaw() => _prefs?.getString(_keyConsentSettings);

  Future<void> setConsentSettingsRaw(String json) async {
    await _prefs?.setString(_keyConsentSettings, json);
  }

  // ─── 2.x VIP entries (JSON-encoded list) ──────────────────────────────────

  static const String _keyVipEntries = 'ad_sdk_vip_entries';
  static const String _keyVipMigrated = 'ad_sdk_vip_migrated_v2';

  String? getVipEntriesRaw() => _prefs?.getString(_keyVipEntries);

  Future<void> setVipEntriesRaw(String json) async {
    await _prefs?.setString(_keyVipEntries, json);
  }

  bool isVipMigrated() => _prefs?.getBool(_keyVipMigrated) ?? false;

  Future<void> markVipMigrated() async {
    await _prefs?.setBool(_keyVipMigrated, true);
  }

  Future<void> clearAllData() async => _prefs?.clear();
}
