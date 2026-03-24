import 'package:shared_preferences/shared_preferences.dart';

/// Manages SharedPreferences for VIP member state and AdSafety daily persistence.
class AdPreferences {
  static AdPreferences? _instance;
  SharedPreferences? _prefs;

  AdPreferences._();

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

  // ════════════════ VIP MANAGEMENT ════════════════

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

  // ════════════════ AD SAFETY PERSISTENCE ════════════════

  static const String _keyDailyAdCount = 'ad_sdk_daily_count';
  static const String _keyDailyDate = 'ad_sdk_daily_date';
  static const String _keySuspiciousCount = 'ad_sdk_suspicious_count';

  int getDailyAdCount() {
    final today = DateTime.now().toString().substring(0, 10);
    final savedDate = _prefs?.getString(_keyDailyDate) ?? '';
    if (savedDate != today) {
      _prefs?.setString(_keyDailyDate, today);
      _prefs?.setInt(_keyDailyAdCount, 0);
      // NOTE: _keySuspiciousCount is NOT reset daily — it persists across days
      // so progressive cooldown escalates for repeat offenders.
      return 0;
    }
    return _prefs?.getInt(_keyDailyAdCount) ?? 0;
  }

  Future<void> incrementDailyAdCount() async {
    final today = DateTime.now().toString().substring(0, 10);
    final current = getDailyAdCount();
    await _prefs?.setInt(_keyDailyAdCount, current + 1);
    await _prefs?.setString(_keyDailyDate, today);
  }

  int getSuspiciousCount() => _prefs?.getInt(_keySuspiciousCount) ?? 0;

  Future<void> incrementSuspiciousCount() async {
    final current = getSuspiciousCount();
    await _prefs?.setInt(_keySuspiciousCount, current + 1);
  }

  Future<void> clearAllData() async => _prefs?.clear();
}
