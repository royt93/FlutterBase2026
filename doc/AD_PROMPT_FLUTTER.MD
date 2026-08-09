# Prompt Template: Integrating `applovin_admob_sdk` into a Flutter Project

> **Maintenance note:** this file is the complete, self-contained handoff given to a partner engineering team integrating this SDK. Whenever the SDK version, ad unit conventions, native config requirements, splash lifecycle, VIP flow, or consent flow changes, update this file at the same time.
>
> **Filling in this template:** Section 0 below is where you record the *consuming* project's own values — SDK version pinned, provider choice, ad unit IDs, bundle ID, native config, logging setup, and so on. Do not carry over IDs, paths, or config from any other project. Every `<...>` placeholder must be filled with values that belong to the project you are integrating into.
>
> This template applies to any **Flutter** project. Before handing it to an AI agent, **fill in every `<...>` placeholder** in Section 0. The VIP feature is **mandatory** — every project must ship a VIP screen plus first-install grace (already built into the SDK — do not reimplement it).
> If your project already has a VIP-related screen, reuse or enhance it following Step 10 below. If not, build a new one — the SDK also ships a ready-made `VipRedeemScreen` widget you can wrap directly (see the usage note in Step 10.2, and `packages/ad_sdk/README.md` if you happen to have the SDK's source available).
>
> **Core rules (apply to the entire generated codebase):**
> 1. **Do NOT** use `setState` — use `ValueNotifier<T>` + `ValueListenableBuilder` instead (or the reactive equivalent of whatever state manager is in use — GetX `Rx<T>` + `Obx` preferred).
> 2. **Do NOT** use `!` (the bang operator) — use a null-safe pattern instead: `if (x case final v?)`, `final v = x; if (v == null) return;`, or the null-coalescing operator `??`.
> 3. **Do NOT** use `late` / `late final` — use a nullable field initialized in `initState` instead, read via a local copy (`final c = _controller; if (c != null) ...`).
> 4. **Prefer** `AdProvider.appLovin` as the active runtime provider; treat AdMob as a fallback only (swap by flipping one line, `AdConfig.provider`).
> 5. **Preferred state management**: GetX (`Rx<T>` / `Obx` / `'.tr'` for i18n / `Get.to` for navigation). i18n keys use `'snake_case'.tr`.
> 6. **Preferred logger**: the project's own logger, wired through `AdConfig.onLog`. (One reference implementation names its logger `SafeLogger` and prefixes every line with a project tag, e.g. `roy93~` — that's just an example from one integration, not a requirement; use whatever logger convention your project already has.)

---

## 0. Context — fill in before running

Read the SDK source carefully before starting: the monorepo path `packages/ad_sdk/` if you have it available, otherwise the hosted package under `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<version>/`.

| Field | Value |
|---|---|
| Current project (cwd, absolute path) | `<PROJECT_PATH>` |
| Dart package name (from `pubspec.yaml: name`) | `<DART_PACKAGE_NAME>` |
| Current state management | `<GetX \| Provider \| Riverpod \| Bloc \| none>` (GetX preferred; if empty → ask the user) |
| Default locale | `<vi_VN \| en_US \| ...>` (default to whatever the project already targets) |
| `applovin_admob_sdk` version | `<LATEST_STABLE_VERSION>` ← **fetch `https://pub.dev/api/packages/applovin_admob_sdk` (or run `flutter pub outdated`) to get the current latest stable version and fill it in here before running Step 1.** As of this writing (2026-08-09) the latest published version is `2.0.4` — treat that as a data point, not a hardcoded target; always use whatever is actually latest at integration time. |
| Local library reference (if monorepo) | `packages/ad_sdk/` |
| Library's own spec files | `packages/ad_sdk/README.md` (Quick start + API) + `packages/ad_sdk/CHANGELOG.md` (feature history) + `packages/ad_sdk/MIGRATION.md` |
| Sample app | `packages/ad_sdk/example/lib/main.dart` (demo pages, one page per feature) |
| Debug build target | `flutter build apk --debug` (Android) + `flutter build ios --debug --no-codesign` (iOS, if targeting iOS) — both must succeed |
| Release build target | `flutter build apk --release --analyze-size` — verify the size delta is < 5MB versus baseline |
| Primary provider (active at runtime) | **`AdProvider.appLovin`** (hard preference — do not change) |
| Fallback provider | `AdProvider.adMob` (swap by changing `AdConfig.provider`) |
| AppLovin SDK key | `<ask the user — stop if missing>` (86 chars, from `dash.applovin.com → Account → Keys → SDK Key`) |
| AppLovin Android banner ID | `<ask the user — stop if missing, if targeting Android>` |
| AppLovin Android interstitial ID | `<ask the user — stop if missing, if targeting Android>` |
| AppLovin Android app open ID | `<ask the user — stop if missing, if targeting Android>` |
| AppLovin Android rewarded ID | `<ask the user — stop if missing, if targeting Android>` |
| AppLovin iOS banner ID | `<ask the user — stop if missing, if targeting iOS>` |
| AppLovin iOS interstitial ID | `<ask the user — stop if missing, if targeting iOS>` |
| AppLovin iOS app open ID | `<ask the user — stop if missing, if targeting iOS>` |
| AppLovin iOS rewarded ID | `<ask the user — stop if missing, if targeting iOS>` |
| AdMob `APPLICATION_ID` | `<ask the user — if the user has no AdMob account, use Google's test App ID `ca-app-pub-3940256099942544~3347511713` + add a warning to the final report>` |
| AdMob banner ID | `<ask the user — stop if missing>` (do NOT use a test ID once the user has a production ID) |
| AdMob interstitial ID | `<ask the user — stop if missing>` |
| AdMob app open ID | `<ask the user — stop if missing>` |
| AdMob rewarded ID | `<ask the user — stop if missing>` |
| Privacy Policy URL | `<ask the user — stop if missing>` (gets embedded into `ConsentDialogStrings.privacyPolicyUrl` + the VIP screen footer) |
| Splash hard cap (seconds) | `<ask the user, default 8>` (must match `AdConfig.splashMaxDuration`) |
| VIP key whitelist (plaintext) | `<ask the user — list in the form "KEY: <duration>", e.g. "PROMO30: 30 days, PROMO3: 3 days">` |
| VIP key obfuscation level | Plaintext `Map<String, Duration>` in `vip_keys.dart` (simple, good enough for a new project). A stronger mechanism — Ed25519-signed keys, not a Base64 map — is also available if the user wants a higher anti-forgery bar; see `packages/ad_sdk/README.md` → "Signed VIP keys" (if you have the SDK source) or the hosted package's README on pub.dev. |

**Hard rules for Section 0**:

1. **Both AppLovin and AdMob config are mandatory** before setting up `AdConfig` — `AppLovinConfig` and `AdMobConfig` must both be non-null in the constructor (SDK constraint). For AppLovin, **ad unit IDs must be split per platform** if the app targets both; never reuse iOS units for Android or vice versa. This keeps provider swapping possible without rebuilding the template. If the user says "I only have AppLovin" → still ask for the AdMob IDs separately; never auto-fill a test ID when the user has a real one.
2. **AdMob `APPLICATION_ID` exception**: if the user has no AdMob account and confirms they won't serve AdMob ads → it's fine to use Google's test App ID `ca-app-pub-3940256099942544~3347511713` + write a warning into the final report in Step 12.
3. Any field still marked `<ask the user — stop if missing>`: the AI **must ask the user in chat** and then **stop and wait for an answer** — do not auto-fill the placeholder, do not use a test ID when the user has a production ID, do not skip it.
4. **Latest version**: fetch the `pub.dev` API or read `flutter pub outdated` to get the latest stable version right when starting Step 1. Every feature referenced in this document (VIP stacking, `bypassVipGuard`, the anti-uninstall-bypass guard, ATT integration) is present in current releases, so there's no known minimum-version constraint beyond "use whatever is latest."

---

## Forbidden (applies to every project)

- Adding a new ad slot beyond the slots that already exist in the current code.
- Refactoring code unrelated to the ad integration.
- Bumping or downgrading the SDK version outside the range settled in Section 0.
- Changing `AdConfig.provider` from AppLovin to AdMob without the user asking for it.
- Re-reading the same file more than once for "double checking" — review the result you already have; don't re-read.
- Adding a new interstitial trigger (e.g. "show after every action X") if the existing code doesn't already do that.
- Filling an ad ID with a test ID or placeholder when the user already has a production ID — you must ask the user instead.
- Bypassing `AdSafetyParams.auto` anywhere except the one sanctioned spot: the splash App Open ad (`bypassSafety: true`).
- Re-implementing first-install VIP grace in app code — the SDK already has `firstInstallVipGrace: FirstInstallVipGrace.auto` (30s debug / 24h release). **Mandate using `auto`, do NOT override it.**
- Showing an App Open Ad **directly on a bare splash screen** (this violates AdMob's "Disallowed interstitial implementations" policy) — it must go through the flow `loadAppOpenAd → AdLoadingDialog.showAdBuffer → showAppOpenAd(bypassSafety: true)`.
- Subscribing to `WidgetsBindingObserver` lifecycle yourself to show App Open on resume — the SDK already hooks this; double-subscribing means double-showing.
- Adding an Android/iOS permission beyond the whitelist (see Step 2 + Step 11), except for an ad-related permission with a clear justification (e.g. `ACCESS_WIFI_STATE` for AppLovin GeoTargeting). Any non-ad-related permission → ask the user first.
- **Using `setState`, `!` (the bang operator), or `late` / `late final`** — this violates the three core rules at the top of this file. Step 11 will grep for these and reject the integration if found.
- Hardcoding user-facing strings (consent dialog, VIP UI, disclaimer) — they must go through `'snake_case_key'.tr` (GetX) with the key added to both `vi_vn.dart` and `en_us.dart`.

---

## Step 1 — Read the reference library

- `ls -R packages/ad_sdk/` (if you have the monorepo) or `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<VERSION>/` (if hosted).
- Fetch `https://pub.dev/api/packages/applovin_admob_sdk` to verify the latest stable version and update Section 0 if needed.
- Read `packages/ad_sdk/README.md` (Quick start + Configuration reference + Public API). Pay particular attention to these call sites:
  - Bootstrap: `AdManager().setNavigatorKey(key)`, `adRouteObserver`, `AdScreenRouteLogger()`, `SimpleEventBus().listen`, `AdManager().initialize(config:, onComplete:)`.
  - Splash flow: `markSplashActive` / `markSplashInactive` / `incrementSplashCount` / `countInitSplashScreen`, `loadAppOpenAd`, `AdLoadingDialog.showAdBuffer`, `showAppOpenAd(bypassSafety: true)`.
  - Per-screen: `class XxxScreen extends AdScreen` → `class _XxxState extends AdScreenState<XxxScreen>` gives you `buildBanner()`, `showInterstitialAd(onDone:)`, `showRewardedAd(onEarnedReward:)`.
  - VIP: `AdManager().vip` (nullable!) → `addVip / redeemVip / revokeVip / revokeAll / activeListenable / activeStream / expiresAt / entries`. **`addVip` and `redeemVip` take a `stack: bool` (default `false`)** — `stack: true` means **global stacking**: `+duration` is added on top of the highest current expiry across ALL active entries (every source shares one timeline; e.g. 6 days left + a 30-day code ⇒ 36 days). `stack: false` keeps "latest-expiry-wins" semantics. Optional cap: **`AdConfig.maxVipStackDuration`** (default `null` = no cap) clamps the total to `≤ now + cap`. (Available in current SDK releases — check `CHANGELOG.md` if you need the exact version it landed in.)
  - Rewarded while already VIP: `showRewardedAd(bypassVipGuard: true, ...)` lets a VIP user **voluntarily** watch a real rewarded ad to extend their window (the SDK loads the ad on-demand and shows a loading dialog; default `false` keeps the surface suppressed). Configurable `onDemandLoadTimeout` (default 15s). `showRewardedAd` is already **re-entrancy-safe** (blocks double-tap while loading/showing). (Available in current SDK releases — check `CHANGELOG.md` for the exact version.)
  - Consent: `AdManager().requestUmpConsent(testMode:, debugGeography:, testIdentifiers:)` + `ConsentManager.instance.showDialog(context)` + `AdConfig.autoShowConsentDialog` + `consentDialogStrings`.
  - Safety: `AdSafetyParams.auto` (default, do NOT override).
  - Logger pipe: `AdConfig.onLog: (level, tag, msg) { ... }`.
- Read `packages/ad_sdk/CHANGELOG.md` — the "What's new" section for the version you're using, to learn about newer features (UMP wrapper, smart App-Open timeout, slot-state dismiss watcher, first-install grace, the anti-bypass guard if present in that version, the taskAffinity pitfall).
- Read `packages/ad_sdk/example/lib/main.dart` to see which demo pages are active.

**Required output**: a summary of ≤ 10 lines covering the library's API surface and everything the SDK manages automatically (App Open auto-show via `WidgetsBindingObserver`, banner auto pause/resume via `adRouteObserver` + RouteAware, frequency caps via the multi-layer safety gate, VIP auto-expire via `Timer`, consent dialog auto-show ~1s post-splash, first-install grace, anti-bypass guard if that version has it).

## Step 2 — Audit the current state of the project

Answer 8 questions (yes/no + evidence as `file:line`):

1. Has the project already adopted `applovin_admob_sdk`? Or is it still on an old SDK (e.g. raw `google_mobile_ads`, a custom `AdMobManager`, `AdsHelper`, ...)?
2. What does `main.dart` currently call for init? Does it call `AdManager().setNavigatorKey(navigatorKey)` **before** `runApp`? Are `adRouteObserver` + `AdScreenRouteLogger()` present in `navigatorObservers`?
3. Does the splash screen call `AdManager().initialize` (NOT `main`)? Is `SimpleEventBus().listen` registered **before** `initialize`? Is there a hard-cap timer + hot-restart guard (`countInitSplashScreen > 1`)?
4. Which screens currently load banner / interstitial / rewarded, and with which API? Have they already been converted to extend `AdScreen`?
5. **Is there a VIP screen already?** If yes → the AI will **upgrade it in place** in Step 10. If not → create a new one. Describe the current UI if one exists.
6. State management: is the project using GetX / Provider / Riverpod / Bloc / setState? Verify whether GetX is already present (`pubspec.yaml`) — if not → the AI will add it per Q37.
7. Does the project have a `BaseStatefulState` (or `BaseStatefulWidget`, `BaseScreen` equivalent)? Where is it? What helpers does it already provide (alert dialogs, lifecycle logging)? If none exists → the AI will create one at `lib/<DART_PACKAGE_NAME>/core/base_stateful_state.dart`.
8. Does the project have a `SafeLogger` (or `Logger`, `Talker`, `LogUtils` equivalent)? Where is it? Which methods (`d`/`i`/`w`/`e`)? If none exists → the AI will create one at `lib/<DART_PACKAGE_NAME>/util/safe_logger.dart`.

## Step 3 — Write the integration plan into `<PROJECT_PATH>/doc/AD.MD`

Target file: `<PROJECT_PATH>/doc/AD.MD` (create it if it doesn't exist yet).

It must contain these sections:

**(1) Touchpoint table** — one row per slot. If a slot doesn't exist yet in the project, write `(none yet)` in the "Old API replaced" column:

| Slot | Current file | Trigger | New API | Old API replaced |
|---|---|---|---|---|
| Banner | `<host screen>.dart` | `build()` of a screen extending `AdScreen` | `buildBanner()` (edge-to-edge wrap — Step 4) | `<old API or (none yet)>` |
| Interstitial | `<host screen>.dart` | `<keep the existing trigger>` | `showInterstitialAd(onDone: (shown) {...})` | `<old API>` |
| App Open (cold) | Splash | after `initialize` + `loadAppOpenAd` + `AdLoadingDialog.showAdBuffer` | `showAppOpenAd(bypassSafety: true, onAdDismiss:)` | `<old API or (none yet)>` |
| App Open (resume) | SDK auto | `WidgetsBindingObserver` (SDK internal) | (never called manually) | `<old API or (none yet)>` |
| Rewarded | VIP screen / clear-history button / etc. | user click | `showRewardedAd(onEarnedReward: (earned) {...})` | `<old API or (none yet)>` |

**(2) Step-by-step plan** — 6 steps (Setup pubspec + native config, App init wiring + Consent + ATT, Splash flow, VIP UI + AdKey + i18n, Banner placement edge-to-edge, Interstitial/Rewarded triggers). Each step should state which files get edited, which functions get added, and which lines get removed.

**(3) Before/after comparison table** — at least 8 rows (Provider, Architecture, App Open lifecycle, Consent UI + UMP, Memory leak risk, Frequency cap, VIP support, Banner pause/resume).

**(4) Information still needed from the user** — a clear list of what's missing: ad unit IDs, AppLovin SDK key, Privacy Policy URL, banner placement layout (top/bottom/anchored — default bottom), VIP key whitelist + duration mapping, splash hard-cap.

## Step 4 — Lifecycle requirements (hard rule, applies to every Flutter project)

### 4.1 — Bootstrap order in `main.dart` (do NOT reorder)

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. setNavigatorKey BEFORE runApp — mandatory
  AdManager().setNavigatorKey(navigatorKey);

  // 2. ATT: do NOT call it here. Apple will reject a prompt shown on a blank screen.
  //    Call `AdManager().requestAtt()` inside SplashScreen (postFrame, before
  //    requestUmpConsent) — see Step 4.2.4 and Step 8.3.

  // 3. Project bootstrap (wakelock, edge-to-edge, refresh rate)
  WakelockPlus.enable();
  UIUtils.initEdgeToEdge();
  if (Platform.isAndroid) await FlutterDisplayMode.setHighRefreshRate();

  // 4. State manager init
  Get.put(ControllerMain());

  // 5. Locale
  final savedLocale = await LanguageService.getSavedLanguage();

  // 6. runApp with the navigator key + both observers
  runApp(GetMaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    translations: AppTranslations(),
    locale: savedLocale ?? const Locale('vi', 'VN'),
    fallbackLocale: const Locale('en', 'US'),
    home: const SplashScreen(),
  ));
}
```

If `setNavigatorKey` is missing, the auto-show consent dialog and the app-open-on-resume buffer will silently fail.

### 4.2 — Splash flow (hard rule, hot-restart guard is mandatory)

```dart
class _SplashScreenState extends BaseStatefulState<SplashScreen> {
  Timer? _hardCap;
  StreamSubscription<BoolEvent>? _busSub;
  final ValueNotifier<bool> _navigated = ValueNotifier(false);

  @override
  void initState() {
    super.initState();

    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // 4.2.1 — Hot-restart guard (mandatory)
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    // 4.2.2 — Hard cap timer (default 8s, must match AdConfig.splashMaxDuration)
    _hardCap = Timer(const Duration(seconds: 8), _goHome);

    // 4.2.3 — Subscribe BEFORE initialize
    _busSub = SimpleEventBus().listen<BoolEvent>((e) {
      if (e.value) {
        _showSplashAppOpen();
      } else {
        _goHome();
      }
    });

    // 4.2.4 — ATT (iOS) → UMP → initialize. MANDATORY ORDER.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ATT before UMP so IDFA settles before the first ad request. No-op on Android.
      // The SDK swallows errors internally → returns AttStatus.denied, never throws.
      try {
        final att = await AdManager().requestAtt();
        SafeLogger.d('Splash', 'ATT status=${att.status.name}');
      } catch (e) {
        SafeLogger.w('Splash', 'ATT threw, continuing: $e');
      }
      // testMode: false — let real geolocation decide EEA (do NOT force EEA in debug).
      try {
        await AdManager().requestUmpConsent(testMode: false);
      } catch (e) {
        SafeLogger.w('Splash', 'UMP threw, continuing init anyway: $e');
      }
      AdManager().initialize(
        config: AdConfig(
          provider: AdProvider.appLovin,                  // RULE #4 preference
          appLovin: AdKey.appLovin,                       // RULE #16 AdKey class
          adMob: AdKey.adMob,
          // firstInstallVipGrace: FirstInstallVipGrace.auto,  // default — do NOT override
          // autoShowConsentDialog: true,                       // default
          consentDialogStrings: ConsentDialogStrings(
            title: 'consent_title'.tr,
            message: 'consent_message'.tr,
            allowButton: 'consent_allow'.tr,
            rejectButton: 'consent_reject'.tr,
            privacyPolicyLabel: 'consent_privacy_label'.tr,
            privacyPolicyUrl: AdKey.privacyPolicyUrl,
          ),
          vipKeyValidator: vipKeyValidator,
          vipDialogStrings: VipDialogStrings(
            verifyingTitle: 'vip_verifying_title'.tr,
            successTitle: 'vip_success_title'.tr,
            failedTitle: 'vip_failed_title'.tr,
            // ... full strings
          ),
          logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
          onLog: (level, tag, msg) {
            switch (level) {
              case AdLogLevel.error:   SafeLogger.e(tag, msg); break;
              case AdLogLevel.warning: SafeLogger.w(tag, msg); break;
              default:                  SafeLogger.d(tag, msg);
            }
          },
        ),
      );
    });
  }

  void _showSplashAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated.value || !mounted) return;
      if (!loaded) return _goHome();
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (!mounted) return _goHome();
        // Cancel the hard-cap BEFORE showAppOpenAd
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          bypassSafety: true,                   // the ONLY place this is allowed
          onAdDismiss: (_) => _goHome(),
        );
      });
    });
  }

  void _goHome() {
    if (_navigated.value) return;
    _navigated.value = true;
    _hardCap?.cancel();
    _hardCap = null;
    AdManager().markSplashInactive();
    if (!mounted) return;
    Get.offAll(() => const MainScreen());
  }

  @override
  void dispose() {
    _hardCap?.cancel();
    _busSub?.cancel();
    _navigated.dispose();
    super.dispose();
  }
}
```

### 4.3 — Splash UI (disclaimer is mandatory — Q27)

The splash screen must show a disclaimer before the App Open Ad appears:

```dart
Text(
  'splash_ads_notice'.tr,    // mandatory i18n key
  textAlign: TextAlign.center,
  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
)
LinearProgressIndicator(...)
```

Required translations to add:
```dart
// vi_vn.dart
'splash_ads_notice': 'Lưu ý: ứng dụng có thể hiển thị quảng cáo',
// en_us.dart
'splash_ads_notice': 'Please note: this action may show ads',
```

### 4.4 — Banner: extend `AdScreen` + edge-to-edge

```dart
class HomeScreen extends AdScreen {  // NOT StatefulWidget
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(child: _content()),
        _buildBannerEdgeToEdge(),    // bottom + edge-to-edge wrap
      ],
    ),
  );

  // Detect edge-to-edge (Q23D): if the app uses UIUtils.initEdgeToEdge() →
  // wrap with SafeArea(top: false, bottom: true) so the banner sits above the gesture nav bar.
  // If the app is NOT edge-to-edge → buildBanner() bare is fine.
  Widget _buildBannerEdgeToEdge() {
    return SafeArea(
      top: false,
      bottom: true,
      child: buildBanner(),
    );
  }
}
```

### 4.5 — App Open when returning to the foreground

The SDK already hooks `WidgetsBindingObserver`. **Do NOT** subscribe to lifecycle a second time — that causes a double-show.

As of current SDK releases: `showAppOpenAdOnResume` will not show App Open on top of a modal —
it checks `isDialogOnTop` (tracked by `AdScreenRouteLogger` counting open `PopupRoute`s) plus
`AdLoadingDialog.isShowing` before showing; if a dialog or loading buffer is currently on top, it skips.

### 4.6 — Interstitial pattern

```dart
showInterstitialAd(onDone: (shown) {
  // shown=true → ad displayed and dismissed
  // shown=false → blocked by safety / VIP / no network / slot showing
  // ALWAYS execute the post-action regardless (navigate, etc.)
  Get.to(() => const HistoryScreen());
});
```

### 4.7 — Rewarded pattern

Only load + show when the user taps a button (e.g. VIP screen "Watch ad → 3 days VIP", clear history, unlock a feature):

```dart
showRewardedAd(onEarnedReward: (earned) {
  if (!earned) return;
  // grant the reward (e.g. grant 3 days of VIP)
  final vip = AdManager().vip;     // RULE #2 no `!`
  if (vip == null) return;
  // Stacking: use a FIXED key (not a timestamp) + `stack: true` →
  // every ad watch adds +3 days on top of the current expiry, collapsed into one entry (no list clutter).
  vip.addVip(key: 'REWARDED_VIP', duration: const Duration(days: 3), stack: true);
});
```

**Letting an active VIP user stack more time (optional, only if the user asks for it).** By default, while VIP is
active the SDK suppresses all ads → the "Watch ad" button is usually hidden. If you want an active VIP to
extend their window **by watching a real ad** (stacking on top of remaining time), keep the button visible
and pass `bypassVipGuard: true`:

```dart
showRewardedAd(
  bypassVipGuard: true,            // an active VIP can still watch a REAL rewarded ad (SDK loads on demand)
  onEarnedReward: (earned) {
    if (!earned) return;           // still only grants on a completed watch — never auto-grant
    AdManager().vip?.addVip(
      key: 'REWARDED_VIP', duration: const Duration(days: 3), stack: true);
  },
);
```

> ⚠️ Do NOT hand out free VIP time to an already-VIP user (e.g. forcing `vipAutoGrant: true` and then stacking) —
> that's +N days of infinite unwatched ad time, which costs revenue and carries policy risk. `bypassVipGuard`
> still requires watching a real ad, so it's legitimate; anti-spam relies on the SDK's fullscreen safety cap.

## Step 5 — Scope of replacement (mandate replace-all — Q11)

If the project has an old ad SDK, it **must be fully replaced** with `applovin_admob_sdk`. No coexistence.

Before deleting any old SDK file/class, **grep-verify** nothing else still uses it:

- List the old SDK files that will be deleted (e.g. `lib/utils/ad_helper.dart`, `lib/services/admob_service.dart`, a custom `AdMobManager`, ...).
- For each file: `grep -r 'ClassName\|methodName' lib/` across the whole project, confirm 0 references, then delete.
- Remove old deps from `pubspec.yaml` (`google_mobile_ads`, `applovin_max`, `unity_ads`, etc.) except `gma_mediation_applovin` (mandatory at the app level for native mediation — do NOT remove it).
- Don't add banner/interstitial/rewarded to any screen the old SDK wasn't already on.

## Step 6 — Build & memory check

### 6.1 — Build

- `flutter analyze --fatal-infos` → 0 issues (mandate Q10)
- `flutter build apk --debug` → green
- `flutter build apk --release --analyze-size` → green, size delta < 5MB
- (If targeting iOS) `flutter build ios --debug --no-codesign` → green

### 6.2 — Memory leak review (4 manual checks)

- Does every screen extending `AdScreen` call `super.dispose()` at the end of `dispose()`?
- Does the VIP screen cancel every `Timer`, `AnimationController`, `StreamSubscription`, `TextEditingController.dispose()`, `FocusNode.dispose()`, `ValueNotifier.dispose()` in `dispose()`?
- Does the splash screen call `_hardCap?.cancel()` + `_busSub?.cancel()` + `_navigated.dispose()` in `dispose()`?
- Does `MaterialApp.navigatorKey` hold a stale reference after a hot restart?

Output: a table of "review item / conclusion / `file:line` evidence".

## Step 7 — Policy check (5 specific rules)

| # | Rule | How to verify |
|---|---|---|
| 1 | Banner never obscures interactive content, edge-to-edge wrap is correct | Read the host banner layout + verify SafeArea/Padding per Step 4.4 |
| 2 | App Open never shows on a bare splash — only after the loading buffer (`AdLoadingDialog.showAdBuffer`) right before navigating to main, or on resume from background (SDK auto) | Read the splash screen + verify the flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` |
| 3 | Interstitial never shows back-to-back below the frequency cap threshold | Trust the `AdSafetyParams.auto` default, and record the exact values (production: 60s throttle, session cap 6, hourly cap 3, daily cap 5) |
| 4 | Rewarded only triggers on a user tap | Read the VIP screen + check for any other rewarded trigger |
| 5 | The "may show ads" disclaimer is shown on splash before App Open | Read the splash UI |

Report: PASS/FAIL for each rule + `file:line` evidence.

## Step 8 — Consent (UMP + auto-show dialog + iOS ATT)

Wire up **all 3**:

### 8.1 — Cupertino auto-show dialog (default ON)

Strings go through i18n `.tr` (already wired in Step 4.2). Auto-shows ~1s after `markSplashInactive`. Skip conditions (automatic): VIP active, `hasBeenAsked == true`, no `navigatorKey`. Re-show from Privacy settings via `await ConsentManager.instance.showDialog(context)`.

### 8.2 — Google UMP form (mandatory)

Already called in splash before `initialize()` (Step 4.2.4). Minimum test scenarios to record in the report (no need to actually run them):
- Non-EEA: dialog skipped, ads load normally.
- EEA, first launch: Google's UMP form shows → user chooses → cached in `SharedPreferences`.
- EEA, no internet: `requestConsentInfoUpdate` fails → caught → init continues anyway.

### 8.3 — iOS ATT (mandatory, Q14A)

ATT is already built into the SDK — do NOT call
`app_tracking_transparency` directly yourself. Use `AdManager().requestAtt()`.

- The `app_tracking_transparency` dependency is transitive from the SDK — do NOT add it at the app level.
- Add the `Info.plist` key `NSUserTrackingUsageDescription` (MANDATORY — without it the
  prompt is silently suppressed):
  ```xml
  <key>NSUserTrackingUsageDescription</key>
  <string>This identifier is used to deliver personalised ads.</string>
  ```
- Call it in **SplashScreen postFrame, BEFORE `requestUmpConsent`** (Step 4.2.4) —
  do NOT call it in `main()` before `runApp`: **Apple will reject** a prompt shown on a
  blank screen.
  ```dart
  final att = await AdManager().requestAtt();   // no-op on Android
  // att.status: notSupported | notDetermined | restricted | denied | authorized
  // att.idfa: String? (only when authorized); att.allowsTracking: bool
  ```
- `requestAtt()` handles this internally: non-iOS → `notSupported`; already decided before →
  returns the cached status, no re-prompt; error/missing plugin → `denied` (never throws).
- ATT does NOT touch the GDPR consent flag — native AppLovin/AdMob read ATT for IDFA on their own.
- If an iOS user picks "Ask App Not to Track", it falls back to non-personalized ads / SKAdNetwork.

## Step 9 — First-install VIP grace + anti-uninstall-bypass guard

### 9.1 — Grace config (SDK built-in, do NOT reimplement)

**Do NOT** store a manual `pref_first_launch_vip_granted` flag, and **do NOT** call `vip.addVip(...)` in `main()` to grant a day — the SDK already ships `firstInstallVipGrace` defaulting to `auto` (30s debug / 24h release).

```dart
AdConfig(
  // firstInstallVipGrace: FirstInstallVipGrace.auto,  // default — do NOT override (Q34)
  // firstInstallVipKey: '__FIRST_INSTALL__',          // default
)
```

Verify the `__FIRST_INSTALL__` entry appears in `vip.entries` after the first init (see Step 10.6 — special entries).

### 9.2 — Anti-uninstall-bypass guard (available since SDK 1.0.17 — check `CHANGELOG.md` for your version)

Goal: prevent a user from uninstalling + reinstalling the app to get an unlimited number of 24h grace windows. Mechanism per platform:

| Platform | Mechanism | What does the AI need to do? |
|---|---|---|
| **iOS** | SDK auto: writes a flag to the Keychain via `flutter_secure_storage`. Keychain persists across uninstall by default. | ✅ Nothing (the SDK handles it) |
| **Android** | **Host-app config**: AndroidManifest + 2 XML files so Auto Backup can restore `FlutterSharedPreferences.xml` on reinstall under the same Google account. | ⚠️ **The AI MUST configure this** (see 9.3) |

Accepted limitations (documented):
- Android: bypass is possible if the app is uninstalled within the first 24h (before Auto Backup has run), if the user disables Backup, across accounts, or after a factory reset. ~5-15% edge cases.
- iOS: bypass is only possible via "Erase All Content and Settings" or restoring an encrypted backup onto a different device.

### 9.3 — Android Auto Backup config (MANDATORY if the host targets Android)

**(a) `android/app/src/main/AndroidManifest.xml`** — add 3 attributes to `<application>`:

```xml
<application
    android:name="${applicationName}"
    android:allowBackup="true"
    android:fullBackupContent="@xml/full_backup_content"
    android:dataExtractionRules="@xml/data_extraction_rules"
    ...>
```

What each attribute does:
- `android:allowBackup="true"` — enables Google Auto Backup (MANDATORY).
- `android:fullBackupContent="@xml/full_backup_content"` — legacy rules for Android 6-11 (API 23-30).
- `android:dataExtractionRules="@xml/data_extraction_rules"` — modern rules for Android 12+ (API 31+).

If the host app already has `android:allowBackup="false"` → the AI **must ask the user before changing it** (they may have turned it off for a compliance/privacy reason). If the user confirms → set it to `true`.

**(b) `android/app/src/main/res/xml/data_extraction_rules.xml`** — Android 12+ (target SDK ≥ 31), create this file if it doesn't exist:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Auto Backup + Device Transfer rules required by applovin_admob_sdk
  anti-uninstall-bypass guard. The first-install grace flag in
  FlutterSharedPreferences.xml must be cloud-backed up so a reinstall
  on the same Google account restores the flag and skips re-granting
  a fresh 24h grace window.

  Excludes FlutterSecureStorage.xml because EncryptedSharedPreferences
  ciphertext is unrecoverable without the device-bound Keystore key.
-->
<data-extraction-rules>
    <cloud-backup>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
        <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
    </cloud-backup>
    <device-transfer>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
        <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
    </device-transfer>
</data-extraction-rules>
```

**(c) `android/app/src/main/res/xml/full_backup_content.xml`** — Android 6-11 legacy, create this file if it doesn't exist:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Legacy Auto Backup rules (Android 6-11, API 23-30).
  Replaced by data_extraction_rules.xml on API 31+.
  Same intent: include host SharedPreferences (where the SDK first-install
  grace flag lives), exclude EncryptedSharedPreferences ciphertext.
-->
<full-backup-content>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
</full-backup-content>
```

**Note**: both `data_extraction_rules.xml` and `full_backup_content.xml` are needed — Android picks whichever file fits the runtime API level. You can't rely on just one.

**Verify**: if the host app already has a `res/xml/` directory with other backup files (e.g. for Firebase, Hive backup), the AI **must merge** the include/exclude entries rather than overwrite the file.

### 9.4 — iOS — no additional config needed

The SDK handles the Keychain itself. The default `flutter_secure_storage` settings (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no `kSecAttrAccessGroup`) are correct for anti-bypass. Do NOT override them.

### 9.5 — Manual smoke test for anti-bypass (release builds)

**Android (Play Store internal track)**:
```bash
# 1. Build a signed AAB
flutter build appbundle --release

# 2. Upload to Play Console Internal Testing, install via Play Store
# 3. Wait > 24h OR trigger a backup immediately:
adb shell bmgr backupnow <package_name>

# 4. Uninstall + reinstall via Play Store
# 5. Verify the log: NO "🎁 first-install VIP grace granted" line → the block worked
#                Or the app has no __FIRST_INSTALL__ VIP entry → it was skipped
```

**iOS (TestFlight or an Xcode-signed Ad Hoc build)**:
```
1. Temporarily set firstInstallVipGrace = FirstInstallVipGrace.debugShort (30s) for a fast cycle
2. Build a release IPA, install via Xcode/TestFlight
3. Verify the log "🎁 first-install VIP grace granted (30s, mode=release)"
4. Wait 30s → log "⏰ VIP entry expired"
5. Uninstall the app
6. Reinstall via Xcode/TestFlight
7. Verify the log "🛡️ Keychain flag present — prior install detected on this device"
8. Verify the log "🛡️ first-install VIP grace SKIPPED"
9. Restore firstInstallVipGrace = .auto for production
```

## Step 10 — VIP management screen UI/UX (detailed, mandatory)

**The VIP feature is mandatory — do not skip it. Step 2 already audited whether one exists: if so, upgrade it in place; if not, create a new one.**

### 10.1 — File structure (mandate)

```
lib/<DART_PACKAGE_NAME>/
├── common/const/
│   ├── ad_keys.dart              ← Q21A + Q29c — class AdKey
│   └── color_constants.dart      ← (already in the project)
├── core/
│   └── base_stateful_state.dart  ← Q36 — detect existing or create
├── util/
│   └── safe_logger.dart          ← Q9 — detect existing or create
└── widget/
    ├── splash/splash_screen.dart
    └── vip/
        ├── vip_screen.dart       ← main UI
        └── vip_keys.dart         ← validator + key map
```

### 10.2 — `AdKey` class (Q16A + Q21A + Q29c)

`lib/<DART_PACKAGE_NAME>/common/const/ad_keys.dart`:

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

/// Centralised ad-related constants. AppLovin SDK key can be shared by account,
/// but AppLovin ad unit IDs must be split per platform.
abstract final class AdKey {
  static AppLovinConfig get appLovin {
    return Platform.isIOS ? appLovinIos : appLovinAndroid;
  }

  static const AppLovinConfig appLovinAndroid = AppLovinConfig(
    sdkKey:         '<APPLOVIN_SDK_KEY>',
    bannerId:       '<APPLOVIN_ANDROID_BANNER_ID>',
    interstitialId: '<APPLOVIN_ANDROID_INTERSTITIAL_ID>',
    appOpenId:      '<APPLOVIN_ANDROID_APP_OPEN_ID>',
    rewardedId:     '<APPLOVIN_ANDROID_REWARDED_ID>',
  );

  static const AppLovinConfig appLovinIos = AppLovinConfig(
    sdkKey:         '<APPLOVIN_SDK_KEY>',
    bannerId:       '<APPLOVIN_IOS_BANNER_ID>',
    interstitialId: '<APPLOVIN_IOS_INTERSTITIAL_ID>',
    appOpenId:      '<APPLOVIN_IOS_APP_OPEN_ID>',
    rewardedId:     '<APPLOVIN_IOS_REWARDED_ID>',
  );

  static const AdMobConfig adMob = AdMobConfig(
    bannerId:       '<ADMOB_BANNER_ID>',
    interstitialId: '<ADMOB_INTERSTITIAL_ID>',
    appOpenId:      '<ADMOB_APP_OPEN_ID>',
    rewardedId:     '<ADMOB_REWARDED_ID>',
  );

  static const String privacyPolicyUrl = '<PRIVACY_POLICY_URL>';
}
```

**Usage:** `AdManager().initialize(config: AdConfig(provider: AdProvider.appLovin, appLovin: AdKey.appLovin, admob: AdKey.adMob, ...))`.

### 10.3 — UI structure (13 components required — Q19A + Q33A)

| # | Component | Detail (Flutter idiom, no `setState`/`!`/`late`) |
|---|---|---|
| 1 | Status header / Hero card | `ValueListenableBuilder<bool>` listening to `vip?.activeListenable` (null-safe pattern). Active: gold gradient + crown icon `Icons.workspace_premium` + 2-line text (`'vip_active'.tr` + `'vip_until'.trParams({'date': formatted})`). Inactive: grey gradient + `'vip_free_user'.tr` |
| 2 | Activation date row | `'Activated: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.grantedAt)}'` (hidden if free). Uses `package:intl`. The field is named `grantedAt` (SDK 1.0.18+), NOT `startedAt` |
| 3 | Expiry date row | `'Expires: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.expiresAt)}'` (hidden if free) |
| 4 | Progress bar (elapsed) | `LinearProgressIndicator` with `value = (now − entry.grantedAt) / (entry.expiresAt − entry.grantedAt)`, clamped to `[0.0, 1.0]`. **3 points on the horizontal timeline**: `start = entry.grantedAt` (left edge, 0%), `end = entry.expiresAt` (right edge, 100%), `current = now` (fill position). The bar starts **empty right after activation and fills up toward expiry** (elapsed semantics — matches the user's mental model of "progression toward expiry"). Absolutely do NOT invert the formula to `remaining/total` (full → empty) — that's confusing UX. Only show this when VIP is active. **No need for `TweenAnimationBuilder`** — a per-second tick from `_now` is smooth enough (Δ ≪ 0.001%/s for a 24h+ VIP window); `TweenAnimationBuilder` would only add overhead and slow rebuilds. Edge case `total ≤ 0` (clock skew / already expired) → default to `value = 1.0` (full = expired) |
| 5 | Countdown text | Format like `12d 03h 24m 15s` — updated via `Timer.periodic(Duration(seconds: 1), ...)` in `initState`, `cancel()`'d in `dispose`. State goes through `ValueNotifier<Duration>`, never `setState` |
| 6 | VIP key text field | `TextEditingController` + `TextCapitalization.characters` (auto-uppercase), prefix icon `Icons.confirmation_number`, suffix clear button. The "Activate" button calls `vip.redeemVip(context, key, duration, validator, strings, stack: true)` — `stack: true` for **global stacking**: `+duration` on top of the highest expiry across all entries (including watch-ad entries) instead of resetting. The SDK already handles the Cupertino verifying/success/failed dialogs (the success dialog reports the expiry after stacking) |
| 7 | "Watch ad → N days VIP" button | Tap → `showRewardedAd(onEarnedReward: (earned) {...})`. **Only grant VIP when `earned == true`** (the user watched the rewarded ad to completion). **Do NOT** fall back to an interstitial to grant the reward — granting VIP for watching an interstitial violates Google/AppLovin's rewarded policy (it blurs the rewarded/interstitial line). If rewarded isn't ready → show "try again later". **Stacking**: grant via the fixed key `REWARDED_VIP` + `addVip(..., stack: true)` (collapses into one entry). To let an active VIP extend their window this way, keep the button visible even while `active` and use `showRewardedAd(bypassVipGuard: true, ...)` (see 4.7). Pulse animation #1 |
| 8 | Buy 30-day VIP (disabled) | `OutlinedButton.icon(icon: Icon(Icons.card_giftcard))` disabled, label `'vip_buy_30d_locked'.tr` ('Buy 30-day VIP — coming soon'). Waiting on IAP integration |
| 9 | Buy 90-day VIP (disabled) | Same as #8 |
| 10 | Buy 1-year VIP (disabled) | Same as #8 |
| 11 | Buy lifetime VIP (disabled) | Same as #8 |
| 12 | List of active entries | `ValueListenableBuilder<List<VipEntry>>` (subscribed via `vip.activeStream` + a local notifier). Each entry is a card with its own icon (10.6), days/hours remaining, expiry date, and a revoke button |
| 13 | "Restore Purchase" (disabled) | `OutlinedButton.icon(icon: Icon(Icons.restore))` disabled, label `'vip_restore_locked'.tr` ('Restore purchase — coming soon'). Placeholder for future IAP (Q33A) |
| — | "Revoke all VIP" button | Material 3 `AlertDialog` confirm → `await vip.revokeAll()`. Disabled for free users |
| — | "VIP" toolbar badge on the main screen | `ValueListenableBuilder<bool>(valueListenable: vip.activeListenable, ...)` — active: gold chip `0xFFFFD60A`, inactive: white outline |
| — | Privacy Policy footer | `InkWell` → `url_launcher.launchUrl(Uri.parse(AdKey.privacyPolicyUrl), mode: LaunchMode.externalApplication)` |

- The text field and dialogs must use Material 3 (`useMaterial3: true` in `ThemeData`).
- After a successful VIP activation, the UI must update immediately via the reactive `activeListenable` — never `setState`. Pair it with a confetti animation (Q18A) + `HapticFeedback.heavyImpact()`.

#### Reference implementation for row #4 (progress bar — elapsed semantics)

```dart
/// 3 points on the horizontal timeline [grantedAt ─── expiresAt]:
///   start   = entry.grantedAt   (left edge, value 0.0)
///   end     = entry.expiresAt   (right edge, value 1.0)
///   current = now               (fill position)
///
/// progress = (current − start) / (end − start)
/// The bar is EMPTY right after activation, FILLS UP toward expiry.
Widget _buildProgressBar(VipEntry entry) {
  return ValueListenableBuilder<DateTime>(
    valueListenable: _now,  // 1s ticker, drives the elapsed update
    builder: (context, now, _) {
      final total = entry.expiresAt.difference(entry.grantedAt);
      final elapsed = now.difference(entry.grantedAt);
      final progress = total.inMilliseconds <= 0
          ? 1.0  // expired / clock skew → render full
          : (elapsed.inMilliseconds / total.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 10,
          backgroundColor: Colors.white.withValues(alpha: 0.18),
          valueColor: AlwaysStoppedAnimation<Color>(
            Colors.white.withValues(alpha: 0.95),
          ),
        ),
      );
    },
  );
}
```

Visualization for a 30-day VIP:
```
T+0      [░░░░░░░░░░░░░░░░░░░░░░░░░░░]   0% — just redeemed
T+1d     [█░░░░░░░░░░░░░░░░░░░░░░░░░░]   3.3%
T+15d    [██████████████░░░░░░░░░░░░░]   50%
T+29d    [██████████████████████████░]   96.7%
T+30d    [███████████████████████████]  100% — expired
```

### 10.4 — Animation (5 required — Flutter idiom, no `late`)

| # | Animation | Implementation | Trigger |
|---|---|---|---|
| 1 | Pulse on the "Watch ad" button | `AnimationController? _pulseController;` initialized in `initState` with `duration: 1600ms` `..repeat(reverse: true)`. Local copy pattern: `final c = _pulseController; if (c != null) ... ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...)` | `initState` starts it, `dispose` cancels it |
| 2 | Slide-in from below when opening the screen | `AnimationController? _entryController;` init `duration: 1100ms` `..forward()`. 3 sections share one controller, each with its own `Interval(0.0, 0.4)`, `Interval(0.3, 0.7)`, `Interval(0.6, 1.0)` — fade-slide in sequentially | `initState` |
| 3 | Crown icon shimmer | `AnimationController? _shimmerController;` init `duration: 3000ms` `..repeat()`. Either `RotationTransition` ±5° OR a `ShaderMask` with a shimmer `LinearGradient` | `initState` repeats it, `dispose` cancels it |
| 4 | Number count-up for the countdown | `TweenAnimationBuilder<double>` runs only when the value changes meaningfully (once per minute) — NOT every second, to avoid a build hot loop | Whenever `Timer.periodic` crosses a new minute |
| 5 | Confetti on successful activation | `package:confetti` (Q18A): `ConfettiController? _confettiController;` init `duration: 1000ms`. In `dispose`: `_confettiController?.dispose()`. On successful `redeemVip` or `onEarnedReward == true` → `_confettiController?.play()` + `HapticFeedback.heavyImpact()` (Flutter built-in, no need for the `vibration` package) | After success |

Bonus (nice-to-have, not mandatory): default ripple effect for both buttons (comes with Material 3), an animated gradient background for the status header.

### 10.5 — Memory leak rules specific to the VIP screen (do NOT use these patterns)

- **NO `late` / `late final`** — use a nullable field + null-check on every read instead:
  ```dart
  // ❌ DO NOT
  late AnimationController _pulseController;
  // ✅ CORRECT
  AnimationController? _pulseController;
  // When using it:
  final c = _pulseController;
  if (c == null) return const SizedBox.shrink();
  return ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...);
  ```
- **NO `setState`** — use `ValueNotifier<T>` + `ValueListenableBuilder` instead (or GetX `Rx<T>` + `Obx`). Countdown example:
  ```dart
  // ❌ DO NOT
  setState(() => _remaining = newDuration);
  // ✅ CORRECT
  final ValueNotifier<Duration> _remaining = ValueNotifier(Duration.zero);
  // ...
  _remaining.value = newDuration;     // does not trigger setState
  // Build:
  ValueListenableBuilder<Duration>(
    valueListenable: _remaining,
    builder: (_, d, __) => Text(_format(d)),
  )
  ```
- **NO `!` (the bang operator)**:
  ```dart
  // ❌ DO NOT
  AdManager().vip!.redeemVip(...);
  _pulseController!.repeat();
  // ✅ CORRECT (Dart 3 pattern matching)
  if (AdManager().vip case final vip?) {
    vip.redeemVip(...);
  }
  // or a local copy
  final vip = AdManager().vip;
  if (vip == null) return;
  vip.redeemVip(...);
  ```
- **NO `Future.delayed` for a countdown** — use `Timer.periodic` instead, with `cancel()` in `dispose`.
- **Don't hold a rewarded callback as an anonymous closure capturing `this`** when the screen could be `dispose()`d before the callback fires — check `if (!mounted) return;` at the top of the callback.
- **Don't forget to call `.dispose()`** on every `AnimationController`, `TextEditingController`, `FocusNode`, `Timer`, `StreamSubscription`, `ValueNotifier`, `ConfettiController` in `dispose()`. Pattern:
  ```dart
  @override
  void dispose() {
    _keyController.dispose();
    _keyFocus.dispose();
    _shimmerController?.dispose();
    _entryController?.dispose();
    _pulseController?.dispose();
    _confettiController?.dispose();
    _tickTimer?.cancel();
    _activeSubscription?.cancel();
    _isProcessing.dispose();
    _entriesNotifier.dispose();
    _remaining.dispose();
    super.dispose();
  }
  ```

### 10.6 — VIP key whitelist + special entries

`vip_keys.dart`:

```dart
// Plaintext map (simple):
final Map<String, Duration> kVipKeyMap = {
  'PROMO30': const Duration(days: 30),
  'PROMO3':  const Duration(days: 3),
};

// OR a Base64-obfuscated map (a bit more obscured, good enough for a new project):
// import 'dart:convert';
// final Map<String, Duration> kVipKeyMap = {
//   utf8.decode(base64Decode('OUZBMFE3RU4hMjdDTFgwNEAyMTk5M1kyVTBJNyNRMA==')):
//       const Duration(days: 30),
// };
// A stronger option — Ed25519 signed keys instead of a plaintext/Base64 duration map —
// is also available if you need it; see `packages/ad_sdk/README.md` → "Signed VIP keys".

Future<bool> vipKeyValidator(String normalisedKey) async =>
    kVipKeyMap.containsKey(normalisedKey);

Duration? lookupVipKeyDuration(String normalisedKey) =>
    kVipKeyMap[normalisedKey];
```

`VipManager.normaliseKey` (trim + uppercase) runs before the validator → a user typing `promo30` or ` PROMO30 ` will still match.

**Special entries** (auto-managed by the SDK, do NOT delete manually):

| Key prefix | Source | UI label (i18n key) |
|---|---|---|
| `__FIRST_INSTALL__` | `firstInstallVipGrace.auto` (Step 9) | `'vip_entry_first_install'.tr` ('New install gift') |
| `LEGACY_<gaid>` | Auto-migrated from `vipDeviceGaids` (if set) | `'vip_entry_legacy'.tr` ('QA device') |
| `REWARDED_VIP` (prefix `REWARDED_`) | Watch-ad reward (fixed key + `stack: true`) | `'vip_reward_entry'.tr` ('Ad-watch reward') |
| Anything else | User redeem or programmatic `addVip` | `entry.key` raw (mask the first 3 characters) |

### 10.7 — Translations (mandatory: local + English — Q26)

Add to `lib/translations/vi_vn.dart` and `en_us.dart` (snake_case keys):

```dart
// VIP
'vip_active', 'vip_free_user', 'vip_until',
'vip_activated_at', 'vip_expires_at', 'vip_remaining',
'vip_redeem_label', 'vip_redeem_hint', 'vip_redeem_button',
'vip_watch_ad_3d', 'vip_buy_30d_locked', 'vip_buy_90d_locked',
'vip_buy_1y_locked', 'vip_buy_lifetime_locked', 'vip_restore_locked',
'vip_revoke_all_button', 'vip_revoke_all_confirm_title',
'vip_revoke_all_confirm_message', 'vip_entry_first_install',
'vip_entry_legacy', 'vip_verifying_title', 'vip_success_title',
'vip_failed_title',

// Consent
'consent_title', 'consent_message', 'consent_allow', 'consent_reject',
'consent_privacy_label',

// Splash
'splash_ads_notice',

// Common
'privacy_policy', 'cancel', 'confirm', 'ok',
```

Other languages (zh / ja / ko / es / fr, etc.) can be added in a later pass — don't add them for this integration.

### 10.8 — Entry point from the AppBar

```dart
// In your app's main/home screen:
final vip = AdManager().vip;     // null-safe, no `!`
ValueListenableBuilder<bool>(
  valueListenable: vip?.activeListenable ?? ValueNotifier(false),
  builder: (_, active, __) => IconButton(
    icon: Icon(
      Icons.workspace_premium,
      color: active ? const Color(0xFFFFD60A) : Colors.white,
    ),
    onPressed: () => Get.to(() => const VipScreen()),
  ),
)
```

## Step 11 — Self-review & update `<PROJECT_PATH>/doc/AD.MD`

One review pass only, do NOT repeat it 3 times. Checklist:

### 11.1 — Native config

- [ ] `pubspec.yaml`: `applovin_admob_sdk: <LATEST_STABLE>` + `gma_mediation_applovin:` (app-level) + the required packages (Q37 → C):
  - `get`, `intl`, `url_launcher`, `confetti`, `shared_preferences` (already present if using GetX), the SDK
  - `app_tracking_transparency` is a **transitive dependency of the SDK** — do NOT add it at the app level
  - For VIP confetti/success feedback: **skip** adding a separate `vibration` package, use Flutter's built-in `HapticFeedback.heavyImpact()` instead. Note: some projects legitimately keep `vibration` as a real dependency in `pubspec.yaml` for an unrelated long-press haptic feature elsewhere in the app — that's fine and unrelated to VIP/ads; this rule only applies to the VIP UI itself.
- [ ] `AndroidManifest.xml` permission whitelist (Q12B): `INTERNET` + `ACCESS_NETWORK_STATE` + `AD_ID`. Any ad-related permission beyond these 3 needs a clear justification. Any non-ad permission → ask the user first.
- [ ] `AndroidManifest.xml` has the AdMob `APPLICATION_ID` meta-data (production or test ID + warning per Q6C)
- [ ] `MainActivity` does **NOT** have `android:taskAffinity=""` (pitfall #1)
- [ ] (If iOS) `ios/Runner/Info.plist` has `GADApplicationIdentifier`, `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems` (count them for real with `grep -c SKAdNetworkIdentifier ios/Runner/Info.plist`, do NOT hardcode a number — the mediation partner list changes over time; currently ~50 entries)
- [ ] (If iOS) Podfile targets ≥ 13.0

### 11.2 — Bootstrap

- [ ] `main.dart`: `AdManager().setNavigatorKey` before `runApp`, navigator observers complete (`adRouteObserver` + `AdScreenRouteLogger()`)
- [ ] (If iOS) `AdManager().requestAtt()` is called in **splash postFrame, before `requestUmpConsent`** (NOT called in `main()` before `runApp`)
- [ ] Splash: `SimpleEventBus().listen` registered BEFORE `initialize`, hard-cap (default 8s — Q24D), `markSplashActive/Inactive` paired correctly, **hot-restart guard `countInitSplashScreen > 1`** (mandatory — Q35A), the App Open flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` in the right order
- [ ] Splash UI has the `'splash_ads_notice'.tr` disclaimer (Q27A)
- [ ] `AdConfig.onLog` is wired to the project's logger (Q9)

### 11.3 — Slot integration

- [ ] Every screen with an ad extends `AdScreen` + `AdScreenState`
- [ ] Banner is wrapped edge-to-edge if the app uses `UIUtils.initEdgeToEdge()` (Q23D)
- [ ] Every ad slot has been replaced (grepping the old SDK's name no longer matches anything)
- [ ] Old SDK deps removed from `pubspec.yaml` (except `gma_mediation_applovin`)
- [ ] Both build targets from Section 0 are green (debug + release)
- [ ] `flutter analyze --fatal-infos` → 0 issues

### 11.4 — VIP + Consent

- [ ] First-install VIP grace uses the SDK's `auto`, not overridden (Q34A)
- [ ] `AdKey` class at `lib/<DART_PACKAGE_NAME>/common/const/ad_keys.dart` contains `appLovinAndroid`, `appLovinIos`, a platform-selecting `appLovin` getter, `adMob: AdMobConfig(...)`, `privacyPolicyUrl` (Q21A + Q29c)
- [ ] The VIP screen has **all 13 UI components** (10.3) + **all 5 animations** (10.4) + **0 violations of the memory leak rules** (10.5)
- [ ] Translations for both locales added (10.7), 0 hardcoded user-facing strings (Q26)
- [ ] The AppBar VIP icon is reactive via `vip?.activeListenable` (10.8)
- [ ] Consent: all 3 pieces wired (auto-show + UMP + iOS ATT)

### 11.5 — Code style enforcement (core rule — Q3A + Q4D + Q28B)

- [ ] `grep -rn 'setState' lib/` → 0 matches (except `super.setState` inside `BaseStatefulState` framework code, if any)
- [ ] `grep -rn '\!' lib/` manually reviewed → 0 user-introduced bang operators (Dart's `!=` "not equal" syntax is allowed; every other `expr!` pattern is forbidden)
- [ ] `grep -rn 'late ' lib/` → 0 matches
- [ ] `grep -rn 'late final' lib/` → 0 matches

### 11.6 — 5-step smoke test (mandatory Q31)

Run it once on an emulator or a real device (debug build), recording the result of each step:

```
1. Cold-start the app on an emulator/device (debug build).
   Verify: console has no "FATAL"/"Exception", splash renders in < 1s.

2. Wait through the splash flow.
   Verify: console log `🚀 AdManager singleton CREATED` appears exactly once.
   Verify: the `splash_ads_notice` text is shown.
   Verify: if network is OK and the ad loads successfully → App Open Ad shows, dismisses → enters main screen.
   Verify: if the hard-cap (8s) fires → main screen shows immediately, no stuck state.

3. Tap the VIP 👑 icon in the AppBar → enters VipScreen.
   Verify: countdown text updates every second (via ValueNotifier, not setState).
   Verify: if first-install grace is active → the __FIRST_INSTALL__ entry appears in the list with label `vip_entry_first_install`.tr.

4. Enter a valid VIP key (e.g. "PROMO30") → tap "Activate".
   Verify: the Cupertino "Verifying" dialog shows for ≥ 400ms.
   Verify: the success dialog shows, the new entry is added to the list.
   Verify: the AppBar VIP icon turns gold `0xFFFFD60A` immediately (reactive ValueListenableBuilder).
   Verify: the hero card transitions from grey → gold gradient + crown shimmer animation plays.
   Verify: confetti animation fires + heavy haptic feedback.

5. Tap "Revoke all VIP" → confirm in the Material 3 dialog.
   Verify: the entries list is empty.
   Verify: the AppBar VIP icon reverts to a white outline immediately.
```

If any item FAILs → fix it → re-check only that item (don't re-check items that already PASSed).

## Step 12 — Final report (once, ≤ 25 lines)

Fixed format, **only 2 sections**:

```
### Integration Result
- Build: flutter analyze=<PASS|FAIL>, flutter build apk --debug=<PASS|FAIL>, flutter build apk --release=<PASS|FAIL>, (iOS) flutter build ios --debug=<PASS|FAIL>
- Slots integrated: <N/M>
- Policy: <5/5 or list failing rules>
- Memory review: <OK | list suspect points with file:line>
- VIP UI: <13/13 components, 5/5 animations | list missing>
- Code style: setState=<0 match>, !=<count user-introduced>, late=<0 match>, late final=<0 match>
- Smoke test: <5/5 PASS | step <X> FAIL: <reason>>
- Translations: vi=<count keys>, en=<count keys>
- Files changed: <count>, lines +<X> -<Y>
- AdMob APPLICATION_ID: <production | test ID — user has no AdMob account>

### Open questions for user
- <specific key/id still missing>
- <pending decision, if any>
```

Do NOT repeat this "3 rounds" — once the Step 11 checklist is all PASS, stop. If there's a FAIL, fix it until it PASSes, then report.

---

## Appendix A — Cheat sheet: API mapping (Android Kotlin → Flutter Dart)

If the user is migrating from a native Android project using an `_AdmobWrapper`, here's a quick mapping:

| Android (Kotlin) | Flutter (Dart) |
|---|---|
| `AdManager.setConfig(...)` | `AdManager().initialize(config: AdConfig(...))` |
| `AdManager.requestConsentInfoUpdate(...)` | `AdManager().requestUmpConsent(...)` |
| `AdManager.awaitSplashComplete()` | `SimpleEventBus().listen` + `loadAppOpenAd` + `showAppOpenAd(bypassSafety: true)` |
| `AdManager.loadBanner(view, R.id.banner_container)` | `class _XxxState extends AdScreenState<Xxx>` → `buildBanner()` inside `build()` |
| `AdManager.showInterstitial { ... }` | `showInterstitialAd(onDone: (shown) {...})` |
| `AdManager.loadRewarded` + `showRewarded` | `showRewardedAd(onEarnedReward: (earned) {...})` |
| `AdManager.activateVipByKey(base64)` | `AdManager().vip` (null-safe) → `redeemVip(context, key:, duration:, validator:, strings:)` |
| `AdSafetyLimits(interstitialMinIntervalSec: 60, ...)` | `AdSafetyParams.production.copyWith(...)` (defaults to `auto`, do NOT override) |
| `BuildConfig.IS_ENABLE_ADMOB` flag | Flip `AdConfig.provider` (`AdProvider.appLovin` ↔ `AdProvider.adMob`) |
| `Application.onCreate { AdManager.initialize() }` | `main()` only calls `setNavigatorKey`; init happens in `SplashScreen.initState()` |
| `ProcessLifecycleOwner` for App Open resume | SDK auto via `WidgetsBindingObserver` — do NOT subscribe yourself |
| Fragment + `onDestroyView` | `StatefulWidget` + `dispose()` |
| `ObjectAnimator`, `ValueAnimator`, `CountDownTimer` | `AnimationController`, `TweenAnimationBuilder`, `Timer.periodic` |
| `SharedPreferences.edit().putBoolean(...)` | `package:shared_preferences` `prefs.setBool(...)` |
| `DateFormat.getDateInstance(MEDIUM)` | `package:intl` `DateFormat('dd/MM/yyyy')` |
| `VibrationEffect.EFFECT_CLICK` | `HapticFeedback.heavyImpact()` (Flutter built-in) |
| Material You (`com.google.android.material`) | Material 3 (`ThemeData(useMaterial3: true)`) |
| Kotlin `lateinit var` | **FORBIDDEN** `late` — use nullable + check instead (Step 10.5) |
| Kotlin `!!` | **FORBIDDEN** `!` — use pattern matching `if (x case final v?)` or a local copy |
| `viewModel.observe { setState }` | `ValueListenableBuilder` + `ValueNotifier` (or GetX `Obx` + `Rx<T>`) — **never `setState`** |

## Appendix B — Where to find more detail

If you have the SDK's source available (either the monorepo at `packages/ad_sdk/` or a clone of it), these are worth reading directly:

- `packages/ad_sdk/README.md` — full SDK API reference (Quick start + Configuration reference + Public API)
- `packages/ad_sdk/CHANGELOG.md` — version-by-version feature history
- `packages/ad_sdk/example/lib/main.dart` — a demo app with one page per feature, useful as a working reference for bootstrap, splash, banner/interstitial/rewarded, and VIP wiring
- `packages/ad_sdk/lib/src/vip/` — the SDK's own `VipRedeemScreen` implementation, useful if you're wrapping it directly instead of building the 13-component screen from scratch (see the note in Step 10.2)

If you only have the hosted `applovin_admob_sdk` package (no source access), the equivalent material ships with the package itself:

- The package's README and CHANGELOG on pub.dev (`https://pub.dev/packages/applovin_admob_sdk`)
- The same files under your local `.pub-cache`, e.g. `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<version>/README.md` and `CHANGELOG.md`
- The package's own `example/` directory (also mirrored into `.pub-cache`) for a working demo of every integration point covered in this document

---

## Appendix C — Audit log (internal, reserved for next audit round)

This section is a running log for whoever continues auditing/enhancing this SDK. Each round appends a dated entry below — do not delete prior entries, only add. Keep this section free of real ad-unit IDs, SDK keys, bundle IDs, and local absolute paths, since this file is shared with partners as-is.

### Round — 2026-08-09

**Scope**: full audit of the SDK (`packages/ad_sdk/`), the SDK example app (`packages/ad_sdk/example/`), and the host app, including a 100%-of-suite pass on a real physical Android device (Pixel 7 Pro).

**Automated results at time of audit**:
- SDK unit tests: 699/699 pass, `flutter analyze` clean.
- SDK example on-device integration tests: 19/21 clean pass on the real device; the remaining 2 (`interstitial_ad_test`, `rewarded_ad_test`) load and display the ad creative correctly (confirmed via log lines showing successful display with network/creative/latency info) but can't complete because there's no unattended way to dismiss the ad — a known limitation, not an SDK defect, and the same reason CI already excludes these two files from its automated run.
- Host app tests: 118/118 pass, `flutter analyze` clean.

**Scores** (1–10, informs but doesn't replace an editorial decision on publishing):
- SDK itself: **9/10**.
- SDK example/demo app: **7/10**.
- Host app: **8/10**.

**Findings worth carrying into the next round**:

1. **Build-output path collision (DX trap, not a bug)**: `flutter build apk --debug` and `flutter test integration_test/*.dart` both write to the same default path (`build/app/outputs/flutter-apk/app-debug.apk` under whichever project directory you're in). Running an integration test after a debug build — or vice versa — silently overwrites that APK with a different compiled entrypoint. Reinstalling "the debug build" afterward can boot to a blank/stuck splash screen with zero crash log, because the installed binary's `main()` is actually a test file's harness waiting for a VM service connection that will never arrive. Not documented anywhere in the repo yet. Worth a one-line callout in `packages/ad_sdk/example/README.md` or `doc/README_TESTING.md`: rebuild explicitly (`flutter build apk --debug`) before manually reinstalling after running integration tests.
2. **Local interstitial/rewarded on-device testing needs real AppLovin credentials via `--dart-define`**, not documented in one obvious place. Without them, `interstitial_ad_test`/`rewarded_ad_test` fail for a credentials reason that looks superficially like an ad-load bug; worth a short note (which dart-define flags, roughly what they gate) somewhere a new contributor running these tests locally would see it before debugging the wrong thing.
3. **Same Android `applicationId` used by both the SDK example app and the host app** causes an install conflict on one device (installing one force-uninstalls or blocks the other). Not a bug — expected Android behavior for two apps sharing a package name — but worth a one-line note in `packages/ad_sdk/example/README.md` so a tester doesn't waste time diagnosing an "installation failed" error.
4. **AppLovin MAX test-ad creative close (X) button was not discoverable on this device/session** for either interstitial or rewarded, despite the ad genuinely loading and displaying (confirmed via SDK event logs), 10+ tap coordinates tried across letterbox and content-area corners, the hardware back button, and swipe gestures. Most likely a quirk of the specific AppLovin MAX test creative and/or this device's rendering, not an SDK integration defect — it directly explains why these two integration test files are excluded from CI (`.github/workflows/test.yml` comments call out exactly this: no unattended way to dismiss the ad). Worth re-checking on a future AppLovin MAX SDK bump in case a newer test creative fixes it, but not something to chase as an SDK code bug.

**Publish decision this round**: user reviewed the above and explicitly authorized publishing `applovin_admob_sdk` **2.0.4** to pub.dev (docs-only release — corrected an overclaimed "offline VIP redeem" description, see `CHANGELOG.md`). Published successfully; no new pub.dev scoring traps hit (description 153 chars, all three screenshot descriptions under 160 chars, dry-run and real publish both clean).

**Suggested next-round starting points**: re-verify the score-driving findings above are still accurate before re-quoting them (files/behavior may have moved), then decide whether findings #1–#3 warrant small doc patches (they're all doc-only fixes, no code risk) versus being left as tribal knowledge in this log.

Either way, treat this `AD_PROMPT_FLUTTER.MD` file itself as the primary, self-contained spec — the SDK source (when available) is a secondary reference for implementation detail, not a prerequisite for following the steps above.
