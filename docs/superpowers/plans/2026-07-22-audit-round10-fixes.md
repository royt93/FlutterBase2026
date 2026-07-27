# Audit Round 10 Fixes (8.8 → 10/10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all 8 open findings from `applovin_admob_sdk` v1.2.2 audit round 10 (`doc/audit/audit_claude.md`) without regressing the existing 649-test suite, raising the audit score from 8.8 to 10/10.

**Architecture:** Each fix is a small, surgical change to existing code/config — no new modules, no new architecture. Fix 1/2/6/7 touch `AdManager` (`packages/ad_sdk/lib/src/core/ad_manager.dart`). Fix 3 is native Android config parity (example app mirrors the host app) plus a doc-comment accuracy update. Fix 4 is a host-app `assert()`. Fix 5 is an iOS `Info.plist` string. Fix 8 is a doc-comment expansion only (no logic change).

**Tech Stack:** Flutter/Dart (package `applovin_admob_sdk` under `packages/ad_sdk/`), `flutter_test` + method-channel mocking for tests, Android XML resources for native config, no new packages.

## Global Constraints

- **Ràng buộc cứng (hard constraint, verbatim from the approved spec):** "không thêm dependency mới (pub package hoặc native lib), không thêm backend/server" — no new dependency of any kind (neither a pub.dev package nor a native Gradle/CocoaPods library), and no backend/server component, for any task in this plan.
- Do not break any of the existing 649 tests in `packages/ad_sdk/test/`.
- Do not change public API in a breaking way unless a finding explicitly requires it (none do).
- `flutter analyze` must stay clean on both `packages/ad_sdk` and the repo root after every task.

---

### Task 1: R10-A — run UMP consent before AppLovin/AdMob adapter init

**Files:**
- Modify: `packages/ad_sdk/lib/src/core/ad_manager.dart:1118-1133` (the `if (config.autoRequestUmpConsent) { ... }` block) and its surroundings inside `initialize()`
- Test: `packages/ad_sdk/test/consent_persistence_on_init_test.dart` (add a new test to the existing file)

**Interfaces:**
- Consumes: `ConsentManager.bootstrap()` (already called earlier in `initialize()`, unchanged), `requestUmpConsent({testMode, tagForUnderAgeOfConsent, debugGeography, testIdentifiers})` (existing method, unchanged signature), `config.autoRequestUmpConsent`/`umpTagForUnderAgeOfConsent`/`umpDebugGeography`/`umpTestIdentifiers` (existing `AdConfig` fields, unchanged), `debugLastAutoUmpParams` (existing debug field, unchanged).
- Produces: no new public symbols. Behavioral change only: when `autoRequestUmpConsent: true`, the UMP flow now completes (and `canRequestAds` reflects its result) **before** `adapter.initialize()` runs, instead of after.

**Current code (verified byte-for-byte via `sed -n`), inside `AdManager.initialize()`:**

```dart
      // T40 — bootstrap ConsentManager (loads persisted user choice from
      // prefs) BEFORE picking/initialising the adapter, so a previously
      // recorded isAgeRestrictedUser=true can gate AppLovin's init (it has
      // no runtime child-directed API — see AppLovinAdapter.initialize).
      final consentMgr = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: config.consentDialogStrings,
      );
      _consentManager = consentMgr;
      _consent = consentMgr.adConsent;

      // Pick adapter, wire its event sink, then initialise. ...
      final adapter = config.isAdMob ? AdMobAdapter() : AppLovinAdapter();
      adapter.eventSink = _emit;
      adapter.canReload = () =>
          !_isVipMember &&
          !AdSafetyConfig.dailyCapReached() &&
          canRequestAds &&
          isConnected;
      bool ok;
      try {
        ok = await adapter
            .initialize(
              config,
              deviceGaid: _currentDeviceGAID,
              isAgeRestrictedUser: _consent.isAgeRestrictedUser,
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        SafeLogger.e(_tag, 'adapter init TIMED OUT after 20s');
        ok = false;
      }
      if (!ok) {
        SafeLogger.e(_tag, 'adapter init FAILED');
        onComplete(false, _currentDeviceGAID);
        SimpleEventBus().fire(const BoolEvent(false));
        return;
      }

      _config = config;
      _adapter = adapter;
      _attachFullscreenDismissWatchers();
      initRevision.value = initRevision.value + 1;

      consentMgr.listenable.addListener(_syncConsentToAdapter);

      await consentMgr.applyToProviders(config: _config);
      _adapter?.applyConsent(consentMgr.adConsent);

      final pending = _pendingConsentSettings;
      if (pending != null) {
        _pendingConsentSettings = null;
        await consentMgr.set(pending, config: config);
        _consent = consentMgr.adConsent;
        _adapter?.applyConsent(_consent);
      }

      // T01 — SDK-owned UMP: run Google's consent flow before the first ad
      // request and gate loading on canRequestAds. Opt-in; hosts that run UMP
      // in their splash leave this false to avoid double-running.
      if (config.autoRequestUmpConsent) {
        SafeLogger.d(
            _tag, '🔐 autoRequestUmpConsent — running UMP before first load');
        debugLastAutoUmpParams = {
          'testMode': kDebugMode,
          'tagForUnderAgeOfConsent': config.umpTagForUnderAgeOfConsent,
          'debugGeography': config.umpDebugGeography,
          'testIdentifiers': config.umpTestIdentifiers,
        };
        await requestUmpConsent(
          testMode: kDebugMode,
          tagForUnderAgeOfConsent: config.umpTagForUnderAgeOfConsent,
          debugGeography: config.umpDebugGeography,
          testIdentifiers: config.umpTestIdentifiers,
        );
      }
```

**Root cause:** `requestUmpConsent()`'s own doc comment says the standard usage is to call it **before** `initialize()`. When `autoRequestUmpConsent: true` delegates that call to the SDK, it currently runs the UMP flow **after** `adapter.initialize()` has already fired the AppLovin/AdMob native SDK init — meaning the very first ad requests from AppLovin's init can go out before EEA consent is known.

**Why this is safe to move — no new buffering needed:** `_pendingConsentSettings` already exists precisely to hold a `setConsent()` call that arrives before `ConsentManager` is bootstrapped, and is drained right after `consentMgr` bootstraps (the `final pending = ...` block above). `requestUmpConsent()` internally ends by calling `setConsent()`, which already handles the case where it's called with `_consentManager` fully bootstrapped (this task's new position) via the direct `await _consentManager!.set(...)` branch — no buffering path is even needed after the move, since `consentMgr` is already bootstrapped by the time UMP runs in the new position. `isInitialised` requires **both** `_config != null` and `_adapter != null`; neither is set until after adapter init, so moving UMP earlier does not change `isInitialised`'s false state, and every other early-`initialize()` code (VIP grace grant, GAID resolution) that runs before adapter init is unaffected because nothing in the moved block touches those.

- [ ] **Step 1: Write the failing test in `packages/ad_sdk/test/consent_persistence_on_init_test.dart`**

Add this test at the end of `main()`, right after the existing `'autoRequestUmpConsent forwards umpDebugGeography/umpTestIdentifiers...'` test (reuses the file's existing `_alChannel`/`_gmaChannel`/`_umpChannel` mocks from `setUpAll`, and its `setUp`/`tearDown` that reset `AdManager`/`AdPreferences`/`ConsentManager`):

```dart
  // R10-A — autoRequestUmpConsent must resolve BEFORE the AppLovin/AdMob
  // adapter is initialised, so the very first ad request already reflects
  // the user's consent choice.
  test(
      'autoRequestUmpConsent:true runs the UMP flow before adapter.initialize()',
      () async {
    SharedPreferences.setMockInitialValues({});
    final callOrder = <String>[];

    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') {
        callOrder.add('al:${call.method}');
        return <String, dynamic>{};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          callOrder.add('ump:${call.method}');
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_alChannel, (call) async {
        if (call.method == 'initialize') return <String, dynamic>{};
        return null;
      });
      messenger.setMockMethodCallHandler(_umpChannel, (call) {
        switch (call.method) {
          case 'ConsentInformation#requestConsentInfoUpdate':
            return Future.value(null);
          case 'ConsentInformation#canRequestAds':
            return Future.value(true);
          case 'ConsentInformation#getConsentStatus':
            return Future.value(0);
          case 'ConsentInformation#isConsentFormAvailable':
            return Future.value(false);
          default:
            return Future.value(null);
        }
      });
    });

    await AdManager().initialize(
      config: const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
        safety: AdSafetyParams(dryRun: true),
        autoRequestUmpConsent: true,
      ),
      onComplete: (_, __) {},
    );

    expect(AdManager().isInitialised, isTrue);
    expect(callOrder, isNotEmpty,
        reason: 'both the UMP call and the AppLovin init call must have fired');
    final firstUmp = callOrder.indexWhere((e) => e.startsWith('ump:'));
    final firstAl = callOrder.indexWhere((e) => e.startsWith('al:'));
    expect(firstUmp, greaterThanOrEqualTo(0));
    expect(firstAl, greaterThanOrEqualTo(0));
    expect(firstUmp, lessThan(firstAl),
        reason: 'UMP consent must resolve before AppLovin adapter.initialize()');
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/ad_sdk && flutter test test/consent_persistence_on_init_test.dart`
Expected: FAIL on `expect(firstUmp, lessThan(firstAl), ...)` (currently `al:initialize` fires before `ump:ConsentInformation#requestConsentInfoUpdate`).

- [ ] **Step 3: Move the `autoRequestUmpConsent` block in `ad_manager.dart`**

In `packages/ad_sdk/lib/src/core/ad_manager.dart`, cut the whole `if (config.autoRequestUmpConsent) { ... }` block (including its preceding `// T01` comment) out of its current position (after `_pendingConsentSettings` draining, before the consent-footgun-warning check) and paste it immediately **after** the `_consent = consentMgr.adConsent;` line that follows `ConsentManager.bootstrap(...)`, and **before** the `final adapter = config.isAdMob ? AdMobAdapter() : AppLovinAdapter();` line. The result:

```dart
      final consentMgr = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: config.consentDialogStrings,
      );
      _consentManager = consentMgr;
      _consent = consentMgr.adConsent;

      // T01 — SDK-owned UMP: run Google's consent flow before the first ad
      // request and gate loading on canRequestAds. Opt-in; hosts that run UMP
      // in their splash leave this false to avoid double-running.
      //
      // R10-A — moved here (before adapter init, not after) so the very
      // first AppLovin/AdMob ad request already reflects the resolved
      // consent, instead of racing the native adapter's own first request.
      // ConsentManager is already bootstrapped above, so requestUmpConsent()
      // -> setConsent() always takes the direct `_consentManager!.set(...)`
      // path, not the `_pendingConsentSettings` buffer.
      if (config.autoRequestUmpConsent) {
        SafeLogger.d(
            _tag, '🔐 autoRequestUmpConsent — running UMP before adapter init');
        debugLastAutoUmpParams = {
          'testMode': kDebugMode,
          'tagForUnderAgeOfConsent': config.umpTagForUnderAgeOfConsent,
          'debugGeography': config.umpDebugGeography,
          'testIdentifiers': config.umpTestIdentifiers,
        };
        await requestUmpConsent(
          testMode: kDebugMode,
          tagForUnderAgeOfConsent: config.umpTagForUnderAgeOfConsent,
          debugGeography: config.umpDebugGeography,
          testIdentifiers: config.umpTestIdentifiers,
        );
      }

      // Pick adapter, wire its event sink, then initialise. The resolved
      // GAID is forwarded so the AppLovin adapter can register this device
      // as a test device in debug builds (preserves 1.x policy compliance).
      final adapter = config.isAdMob ? AdMobAdapter() : AppLovinAdapter();
      adapter.eventSink = _emit;
      adapter.canReload = () =>
          !_isVipMember &&
          !AdSafetyConfig.dailyCapReached() &&
          canRequestAds &&
          isConnected;
      bool ok;
      try {
        ok = await adapter
            .initialize(
              config,
              deviceGaid: _currentDeviceGAID,
              isAgeRestrictedUser: _consent.isAgeRestrictedUser,
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        SafeLogger.e(_tag, 'adapter init TIMED OUT after 20s');
        ok = false;
      }
      if (!ok) {
        SafeLogger.e(_tag, 'adapter init FAILED');
        onComplete(false, _currentDeviceGAID);
        SimpleEventBus().fire(const BoolEvent(false));
        return;
      }

      _config = config;
      _adapter = adapter;
      _attachFullscreenDismissWatchers();
      initRevision.value = initRevision.value + 1;

      consentMgr.listenable.addListener(_syncConsentToAdapter);

      await consentMgr.applyToProviders(config: _config);
      _adapter?.applyConsent(consentMgr.adConsent);

      final pending = _pendingConsentSettings;
      if (pending != null) {
        _pendingConsentSettings = null;
        await consentMgr.set(pending, config: config);
        _consent = consentMgr.adConsent;
        _adapter?.applyConsent(_consent);
      }
```

Note: `_consent.isAgeRestrictedUser` passed into `adapter.initialize()` now reflects the just-resolved UMP result (if the user is EEA and UMP determined COPPA applies), which is a strict improvement over the previous stale pre-UMP value — no adapter-side code change needed since `AppLovinAdapter.initialize()`/`AdMobAdapter.initialize()` already just consume this parameter.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/ad_sdk && flutter test test/consent_persistence_on_init_test.dart`
Expected: PASS, all 4 tests in the file green.

- [ ] **Step 5: Run the full `ad_sdk` test suite to check for regressions**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 649 + 1 = 650 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add packages/ad_sdk/lib/src/core/ad_manager.dart packages/ad_sdk/test/consent_persistence_on_init_test.dart
git commit -m "fix(ad_sdk): run autoRequestUmpConsent before adapter init (R10-A)"
```

---

### Task 2: R10-B — COPPA mid-session change hard-stops ad requests

**Files:**
- Modify: `packages/ad_sdk/lib/src/core/ad_manager.dart:1363-1365` (inside `setConsent()`)
- Test: `packages/ad_sdk/test/ad_manager_core_test.dart` (add a new test)

**Interfaces:**
- Consumes: `isAdMobProvider` getter (existing, `ad_manager.dart:108`, `bool get isAdMobProvider => _config?.isAdMob ?? false;`), `isInitialised` getter (existing), `_canRequestAds` field (existing, `ad_manager.dart:575`, default `true`), `canRequestAds` getter (existing, `ad_manager.dart:585`, `_canRequestAds && !_footgunBlocked`), `debugCanRequestAds` setter (existing, for tests).
- Produces: no new public symbols. Behavioral change only: setting `isAgeRestrictedUser: true` via `setConsent()` mid-session on a non-AdMob (AppLovin) provider now immediately flips `canRequestAds` to `false`.

**Root cause:** `applyConsentToProviders()` (`ad_consent.dart:82-101`, unchanged by this task) already documents that AppLovin MAX 4.x has no runtime `setIsAgeRestrictedUser` API — when a host flips `isAgeRestrictedUser` to `true` mid-session (after AppLovin already initialised), the current code only logs a warning and keeps requesting ads from AppLovin with no COPPA signal applied.

**Current code (verified byte-for-byte), `ad_manager.dart`'s `setConsent()`:**

```dart
    if (!isInitialised) {
      SafeLogger.d(_tag,
          '⏭️ setConsent: SDK not initialised — buffering for next initialize()');
      return;
    }
    await applyConsentToProviders(consent, config: _config);
    // Keep the adapter's per-request personalization (AdMob npa) in sync.
    _adapter?.applyConsent(consent);
    // N2 — the footgun block just cleared and ads may already be running;
    // refill slots that were held back while it was blocked.
    if (wasFootgunBlocked && canRequestAds && !_isVipMember) {
      SafeLogger.d(
          _tag, '🔓 consent footgun resolved → refilling held ad slots');
      _retryRefillAds();
    }
  }
```

- [ ] **Step 1: Write the failing test in `packages/ad_sdk/test/ad_manager_core_test.dart`**

Add this test inside a `group('setConsent COPPA hard-stop', ...)` block near the other `setConsent`/consent-related tests:

```dart
  group('setConsent COPPA hard-stop (R10-B)', () {
    setUp(() async {
      await AdManager().destroy();
    });

    test(
        'isAgeRestrictedUser=true mid-session on AppLovin hard-stops canRequestAds',
        () async {
      final adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
      );
      AdManager().debugCanRequestAds = true;

      expect(AdManager().canRequestAds, isTrue);

      await AdManager().setConsent(
        const AdConsent(
          hasUserConsent: true,
          isAgeRestrictedUser: true,
          doNotSell: false,
        ),
      );

      expect(AdManager().canRequestAds, isFalse,
          reason: 'AppLovin has no runtime COPPA API — must hard-stop ad '
              'requests instead of only logging a warning');
    });

    test('isAgeRestrictedUser=true mid-session on AdMob does NOT hard-stop '
        '(AdMob receives the tag via RequestConfiguration)', () async {
      final adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'ca-app-pub-9999999999999999/1111111111',
          interstitialId: 'ca-app-pub-9999999999999999/2222222222',
          appOpenId: 'ca-app-pub-9999999999999999/3333333333',
          rewardedId: 'ca-app-pub-9999999999999999/4444444444',
        ),
      );
      AdManager().debugCanRequestAds = true;

      await AdManager().setConsent(
        const AdConsent(
          hasUserConsent: true,
          isAgeRestrictedUser: true,
          doNotSell: false,
        ),
      );

      expect(AdManager().canRequestAds, isTrue,
          reason: 'AdMob already receives the COPPA tag via '
              'RequestConfiguration — no hard-stop needed for this provider');
    });
  });
```

(This reuses the file's existing `_FakeAdapter` class and `debugSetAdapter`/`debugConfig`/`debugCanRequestAds` seams, already used by neighboring tests in this file.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/ad_sdk && flutter test test/ad_manager_core_test.dart --plain-name "COPPA hard-stop"`
Expected: FAIL on the first test's `expect(AdManager().canRequestAds, isFalse, ...)` (currently stays `true`).

- [ ] **Step 3: Add the hard-stop in `setConsent()`**

In `packages/ad_sdk/lib/src/core/ad_manager.dart`, insert between the existing `await applyConsentToProviders(consent, config: _config);` and `_adapter?.applyConsent(consent);` lines:

```dart
    await applyConsentToProviders(consent, config: _config);
    // R10-B — AppLovin MAX 4.x has no runtime setIsAgeRestrictedUser API (see
    // applyConsentToProviders' warning above), so a mid-session flip to
    // isAgeRestrictedUser=true on AppLovin can't be forwarded to the SDK.
    // Hard-stop ad requests entirely instead of leaving a COPPA-relevant user
    // exposed to unflagged ads; a host must re-init to fully clear this once
    // the flag reverts (matches the init-time gate in T40).
    if (consent.isAgeRestrictedUser && !isAdMobProvider && isInitialised) {
      _canRequestAds = false;
      SafeLogger.w(_tag,
          '🛑 R10-B: isAgeRestrictedUser=true mid-session on AppLovin — hard-stopping ad requests (AppLovin has no runtime COPPA API; requires re-init to fully re-enable if flag reverts)');
    }
    // Keep the adapter's per-request personalization (AdMob npa) in sync.
    _adapter?.applyConsent(consent);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/ad_sdk && flutter test test/ad_manager_core_test.dart --plain-name "COPPA hard-stop"`
Expected: PASS, both tests green.

- [ ] **Step 5: Run the full `ad_sdk` test suite to check for regressions**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 0 failures (in particular no regression in the N2 footgun-reopen test that shares this function, since `wasFootgunBlocked && canRequestAds` is evaluated after this new block and `canRequestAds` derives from the just-updated `_canRequestAds`).

- [ ] **Step 6: Commit**

```bash
git add packages/ad_sdk/lib/src/core/ad_manager.dart packages/ad_sdk/test/ad_manager_core_test.dart
git commit -m "fix(ad_sdk): hard-stop AppLovin ad requests on mid-session COPPA flag (R10-B)"
```

---

### Task 3: VIP Android reinstall replay — Auto Backup parity for the example app + doc accuracy

**Files:**
- Create: `packages/ad_sdk/example/android/app/src/main/res/xml/full_backup_content.xml`
- Create: `packages/ad_sdk/example/android/app/src/main/res/xml/data_extraction_rules.xml`
- Modify: `packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml:8-11` (the `<application>` tag)
- Modify: `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:27-41` (class doc comment — Android bullet + bypass-result matrix row)
- Test: `packages/ad_sdk/test/first_install_guard_backup_config_test.dart` (new file)

**Interfaces:**
- Consumes: nothing new — this task changes native config files and a doc comment only, no Dart runtime code changes to `FirstInstallGuard`, `AdPreferences`, or `AdManager`.
- Produces: nothing new for other tasks to consume.

**Why this is the correct fix (not a new SHA-256 marker):** the spec's Fix 3 wording asked for "a new marker (hash of keyId+timestamp) stored via SharedPreferences under a dedicated backup-eligible key." Tracing the actual code shows this marker **already exists**: `AdPreferences.isFirstInstallGraceApplied()` (`packages/ad_sdk/lib/src/utils/ad_preferences.dart:96-97`, backed by the `ad_sdk_first_install_grace_applied` SharedPreferences boolean) is the exact gate already checked in `ad_manager.dart:1007` (`if (graceCfg.isEnabled && !prefs.isFirstInstallGraceApplied())`) before granting the trial — if this flag is `true`, no new grace is ever granted, on any platform. The host app's `android/app/src/main/res/xml/data_extraction_rules.xml` **already** documents (in its own header comment) that this exact flag, in `FlutterSharedPreferences.xml`, is meant to be Android-Auto-Backup'd so a reinstall on the same Google account restores it and short-circuits a fresh grant — and the host's `AndroidManifest.xml` already wires `android:allowBackup="true"` + `fullBackupContent`/`dataExtractionRules` pointing at these files. The **only** actual gap is that the SDK's own **example app** (`packages/ad_sdk/example/`) has none of this config — so the SDK's own demo doesn't exercise or prove out its own documented mitigation, and `FirstInstallGuard`'s class doc comment doesn't mention this mechanism at all, undersells the Android situation as "no reliable local-only signal survives uninstall," and doesn't point a host at the two XML files it needs. This task fixes both: native-config parity for the example (mirroring the host's already-correct files verbatim) and a doc-comment accuracy fix. No new dependency, no new marker, no backend.

**Limitation that must stay documented (per spec):** this is a best-effort mitigation, not attacker-proof — it fails open on factory reset + different Google account, reinstall with sync/backup disabled, or a device with Auto Backup unavailable. This is unchanged by this task and must be preserved in the updated doc comment and in the round-11 audit doc update (Task 9).

- [ ] **Step 1: Write the failing test in `packages/ad_sdk/test/first_install_guard_backup_config_test.dart`**

There is no existing precedent in this codebase for testing native manifest/XML content from Dart — this is a fresh, simple `dart:io`-based file-content assertion test (no mocking, no fixtures):

```dart
// R10 Fix 3 — the example app must mirror the host app's Android Auto
// Backup configuration for `FlutterSharedPreferences.xml` (where
// AdPreferences.isFirstInstallGraceApplied()'s flag lives), so a reinstall
// on the same Google account restores the flag and the first-install VIP
// grace guard correctly refuses to re-grant. Plain static-content assertions
// against the checked-in XML/manifest files — no Dart logic under test.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final exampleAndroidDir =
      Directory('example/android/app/src/main/').existsSync()
          ? 'example/android/app/src/main'
          : 'android/app/src/main'; // when run from packages/ad_sdk/example

  test('example AndroidManifest.xml declares Android Auto Backup', () {
    final manifest =
        File('$exampleAndroidDir/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:allowBackup="true"'));
    expect(manifest, contains('android:fullBackupContent="@xml/full_backup_content"'));
    expect(
        manifest, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
  });

  test('example full_backup_content.xml includes FlutterSharedPreferences.xml',
      () {
    final xml = File('$exampleAndroidDir/res/xml/full_backup_content.xml')
        .readAsStringSync();
    expect(
        xml,
        contains(
            '<include domain="sharedpref" path="FlutterSharedPreferences.xml" />'));
    expect(xml, isNot(contains('<exclude')),
        reason: 'an explicit <exclude> not nested under an <include> fails '
            'the Android lint FullBackupContent check');
  });

  test(
      'example data_extraction_rules.xml includes FlutterSharedPreferences.xml '
      'in both cloud-backup and device-transfer', () {
    final xml = File('$exampleAndroidDir/res/xml/data_extraction_rules.xml')
        .readAsStringSync();
    expect(xml, contains('<cloud-backup>'));
    expect(xml, contains('<device-transfer>'));
    final includeCount =
        '<include domain="sharedpref" path="FlutterSharedPreferences.xml" />'
            .allMatches(xml)
            .length;
    expect(includeCount, 2,
        reason: 'must be included in both <cloud-backup> and <device-transfer>');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/ad_sdk && flutter test test/first_install_guard_backup_config_test.dart`
Expected: FAIL — `PathNotFoundException` on `example/android/app/src/main/res/xml/full_backup_content.xml` (directory doesn't exist yet).

- [ ] **Step 3: Create the example app's `res/xml/` backup rule files (mirroring the host app verbatim)**

Create `packages/ad_sdk/example/android/app/src/main/res/xml/full_backup_content.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Auto Backup rules (legacy — Android 6 to 11, API 23-30).
  Replaced by `data_extraction_rules.xml` on API 31+.

  Same intent as the modern rules: include only the app's plain
  SharedPreferences (where the `applovin_admob_sdk` first-install grace flag
  lives). The explicit <include> means everything else in `sharedpref` —
  including the EncryptedSharedPreferences ciphertext (unrecoverable without the
  device's Keystore key) — is excluded by default. Do NOT add an explicit
  <exclude> for `FlutterSecureStorage.xml`: Android lint (FullBackupContent)
  rejects an exclude not nested under an included path and fails the release build.
-->
<full-backup-content>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
</full-backup-content>
```

Create `packages/ad_sdk/example/android/app/src/main/res/xml/data_extraction_rules.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Auto Backup + Device Transfer rules (Android 12+, API 31+).

  Required by `applovin_admob_sdk` v1.0.17+ anti-uninstall-bypass guard:
  the `prefs.isFirstInstallGraceApplied()` flag (in `FlutterSharedPreferences.xml`)
  must be cloud-backed up so a reinstall on the same Google account restores
  the flag and short-circuits a fresh first-install grace grant.

  `FlutterSecureStorage.xml` is NOT backed up: because we declare an explicit
  <include> for this domain, every other file in `sharedpref` (including the
  EncryptedSharedPreferences ciphertext) is excluded by default. Its ciphertext
  is unrecoverable without the device-bound Keystore key (not part of any
  backup), so restoring it would produce garbage. We must NOT add an explicit
  <exclude> for it — Android lint (FullBackupContent) rejects an exclude whose
  path is not nested under an included path, which fails the release build.
-->
<data-extraction-rules>
    <cloud-backup>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    </cloud-backup>
    <device-transfer>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    </device-transfer>
</data-extraction-rules>
```

- [ ] **Step 4: Wire the manifest attributes in the example app**

In `packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml`, change:

```xml
    <application
        android:label="ad_sdk_example"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
```

to:

```xml
    <application
        android:label="ad_sdk_example"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:allowBackup="true"
        android:fullBackupOnly="true"
        android:fullBackupContent="@xml/full_backup_content"
        android:dataExtractionRules="@xml/data_extraction_rules">
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/ad_sdk && flutter test test/first_install_guard_backup_config_test.dart`
Expected: PASS, all 3 tests green.

- [ ] **Step 6: Update the `_first_install_guard.dart` doc comment for accuracy**

In `packages/ad_sdk/lib/src/vip/_first_install_guard.dart`, replace the Android bullet (lines 27-35):

```dart
///   • **Android — anti-bypass intentionally disabled.** The host app
///     accepts that uninstall + reinstall on Android grants a fresh 24 h
///     grace window. Android has no reliable local-only signal that
///     survives uninstall (Keychain/EncryptedSharedPreferences wipe with
///     the app, ANDROID_ID needs companion storage), and Play Install
///     Referrer alone cannot distinguish a fresh install from a reinstall.
///     Rather than pull in a plugin (`play_install_referrer`) that adds
///     startup overhead and a small crash surface for zero anti-bypass
///     benefit, we simply allow grace on every Android first-init.
```

with:

```dart
///   • **Android — no guard-class-level check; relies on OS Auto Backup
///     of the grace flag instead.** This class (`FirstInstallGuard`) has no
///     Android-side check of its own — there's no local-only signal
///     (Keychain/EncryptedSharedPreferences wipe with the app on uninstall,
///     ANDROID_ID needs companion storage) it could check here. Instead, the
///     app declares Android Auto Backup (`android:allowBackup="true"` +
///     `fullBackupContent`/`dataExtractionRules`, see
///     `full_backup_content.xml` / `data_extraction_rules.xml`) covering
///     `FlutterSharedPreferences.xml`, the file holding
///     `AdPreferences.isFirstInstallGraceApplied()`'s flag — that flag IS
///     the marker, and the grant gate (`AdManager.initialize()`) already
///     checks it directly (`!prefs.isFirstInstallGraceApplied()`) before
///     this guard is even consulted. On a reinstall to the same
///     device+Google-account with backup/sync enabled, Android restores
///     that file automatically before the app's first run, so the flag is
///     already `true` and no fresh grace is granted — a best-effort,
///     non-attacker-proof mitigation (see limitations below). Play Install
///     Referrer alone was rejected as an alternative: it cannot distinguish
///     a fresh install from a reinstall, and a dedicated plugin
///     (`play_install_referrer`) would add startup overhead and a crash
///     surface for no better guarantee than the Auto Backup path above.
```

And update the bypass-result matrix row (line 41, inside the same doc comment):

```
/// | Uninstall + reinstall (same device)          | block (Keychain flag)      | bypass (intentional, fail-open) |
```

to:

```
/// | Uninstall + reinstall (same device+account, backup enabled) | block (Keychain flag) | mitigated (Auto Backup restores the grace flag) |
/// | Uninstall + reinstall (different account, or backup/sync disabled) | block (Keychain flag) | bypass (no signal survives) |
```

- [ ] **Step 7: Run the full `ad_sdk` test suite to check for regressions**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 0 failures (this task changes no Dart runtime logic, only a doc comment and native config/test files, so `first_install_guard_test.dart` must be unaffected).

- [ ] **Step 8: Run `flutter analyze` on the package**

Run: `cd packages/ad_sdk && flutter analyze`
Expected: no new issues (the doc comment is still valid Dart doc syntax; the new XML files aren't analyzed by `flutter analyze`).

- [ ] **Step 9: Commit**

```bash
git add packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml \
        packages/ad_sdk/example/android/app/src/main/res/xml/full_backup_content.xml \
        packages/ad_sdk/example/android/app/src/main/res/xml/data_extraction_rules.xml \
        packages/ad_sdk/lib/src/vip/_first_install_guard.dart \
        packages/ad_sdk/test/first_install_guard_backup_config_test.dart
git commit -m "fix(ad_sdk): Android Auto Backup parity for example app + doc accuracy (VIP reinstall replay)"
```

---

### Task 4: R10-F — debug-only assert against shipping AdMob's public test IDs

**Files:**
- Modify: `lib/mckimquyen/widget/splash/splash_screen.dart:228-306` (the `AdManager().initialize(config: AdConfig(...), ...)` call)
- Test: none automated (this is a debug-only `assert()` in the host app, which has no existing unit-test harness for `splash_screen.dart`; verified manually per Step 4 below — consistent with the host app being "largely UI-only and gated on `flutter analyze`" per the repo's `CLAUDE.md`)

**Interfaces:**
- Consumes: `AdConfig` (unchanged), `AdKey.adMob`/`AdKey.appLovin` (`lib/mckimquyen/common/const/ad_keys.dart`, unchanged — the warning comment for this finding, spec part 1, is **already present** at lines 44-55 with a `TODO(host-app)` marker; only the `assert()`, spec part 2, is added by this task), `AdProvider` enum (`admob`, `appLovin` — unchanged).
- Produces: nothing new for other tasks.

**Current code (verified byte-for-byte)** — `AdConfig(...)` is currently constructed **inline** inside the `AdManager().initialize(...)` call:

```dart
        AdManager().initialize(
          config: AdConfig(
            provider: AdProvider.appLovin,
            appLovin: AdKey.appLovin,
            admob: AdKey.adMob,
            vipDeviceGaids: const [ /* ... 20 GAIDs ... */ ],
            adNotReadyMessage: 'ad_not_ready'.tr,
            adLoadingMessage: 'loading'.tr,
            logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
            consentDialogStrings: ConsentDialogStrings(/* ... */),
            maxVipStackDuration: const Duration(days: 90),
            vipDialogStrings: VipDialogStrings(/* ... */),
          ),
          onComplete: (success, gaid) {
            SafeLogger.d('SplashTrace',
                'AdManager.initialize complete success=$success gaid=$gaid');
            SafeLogger.d('Splash',
                'AdManager init complete: success=$success, gaid=$gaid');
          },
        );
```

- [ ] **Step 1: Refactor the inline `AdConfig(...)` into a local variable**

In `lib/mckimquyen/widget/splash/splash_screen.dart`, change:

```dart
        AdManager().initialize(
          config: AdConfig(
            provider: AdProvider.appLovin,
```

to:

```dart
        final AdConfig adConfig = AdConfig(
          provider: AdProvider.appLovin,
```

...and change the closing of that construction plus the call site. Where the code currently reads (end of the `AdConfig(...)` argument, immediately followed by `onComplete:`):

```dart
            // Q2B: keep default firstInstallVipGrace (auto = 30s debug / 24h
            // release) — well-documented retention boost. Not overridden.
          ),
          onComplete: (success, gaid) {
```

change to:

```dart
            // Q2B: keep default firstInstallVipGrace (auto = 30s debug / 24h
            // release) — well-documented retention boost. Not overridden.
        );

        // R10-F — debug-only guard: if AdMob is ever switched back on
        // (provider: AdProvider.admob), this must fail loudly in debug/test
        // builds if AdKey.adMob still points at Google's public test ad
        // unit IDs. assert() is stripped in release, so this never blocks
        // production — it only catches the mistake early for a developer.
        assert(
          adConfig.provider != AdProvider.admob ||
              !adConfig.admob.bannerId.startsWith('ca-app-pub-3940256099942544'),
          'AdKey.adMob still uses Google\'s public test ad unit IDs — replace '
          'with production IDs before shipping with AdProvider.admob active.',
        );

        AdManager().initialize(
          config: adConfig,
          onComplete: (success, gaid) {
```

The full resulting call site becomes:

```dart
        final AdConfig adConfig = AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AdKey.appLovin,
          admob: AdKey.adMob,
          vipDeviceGaids: const [ /* ... unchanged, 20 GAIDs ... */ ],
          adNotReadyMessage: 'ad_not_ready'.tr,
          adLoadingMessage: 'loading'.tr,
          logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
          consentDialogStrings: ConsentDialogStrings(/* ... unchanged ... */),
          maxVipStackDuration: const Duration(days: 90),
          vipDialogStrings: VipDialogStrings(/* ... unchanged ... */),
          // Q2B: keep default firstInstallVipGrace (auto = 30s debug / 24h
          // release) — well-documented retention boost. Not overridden.
        );

        // R10-F — debug-only guard: if AdMob is ever switched back on
        // (provider: AdProvider.admob), this must fail loudly in debug/test
        // builds if AdKey.adMob still points at Google's public test ad
        // unit IDs. assert() is stripped in release, so this never blocks
        // production — it only catches the mistake early for a developer.
        assert(
          adConfig.provider != AdProvider.admob ||
              !adConfig.admob.bannerId.startsWith('ca-app-pub-3940256099942544'),
          'AdKey.adMob still uses Google\'s public test ad unit IDs — replace '
          'with production IDs before shipping with AdProvider.admob active.',
        );

        AdManager().initialize(
          config: adConfig,
          onComplete: (success, gaid) {
            SafeLogger.d('SplashTrace',
                'AdManager.initialize complete success=$success gaid=$gaid');
            SafeLogger.d('Splash',
                'AdManager init complete: success=$success, gaid=$gaid');
          },
        );
```

- [ ] **Step 2: Run `flutter analyze` at the repo root**

Run: `flutter analyze` (from repo root)
Expected: no new issues.

- [ ] **Step 3: Manually verify the assert fires when it should (dev-only sanity check, no automated test)**

Temporarily change `provider: AdProvider.appLovin` to `provider: AdProvider.admob` in a scratch local run (`flutter run` in debug), confirm the app crashes on the new `assert()` with the expected message, then revert the temporary change (do not commit it). This is a manual one-time verification, not a repeatable automated test, since `splash_screen.dart` has no existing widget-test harness for its ad-init call path.

- [ ] **Step 4: Commit**

```bash
git add lib/mckimquyen/widget/splash/splash_screen.dart
git commit -m "fix(host): debug-only assert against shipping AdMob's public test IDs (R10-F)"
```

---

### Task 5: R10-G — more specific `NSUserTrackingUsageDescription`

**Files:**
- Modify: `ios/Runner/Info.plist:56-57`
- Test: none (a static plist string; no test harness covers `Info.plist` content in this repo)

**Interfaces:** none — this is a standalone string change with no code dependents.

**Current text (verified byte-for-byte):**

```xml
		<key>NSUserTrackingUsageDescription</key>
		<string>This identifier is used to deliver personalized ads and measure ad performance.</string>
```

- [ ] **Step 1: Update the string**

In `ios/Runner/Info.plist`, change:

```xml
		<key>NSUserTrackingUsageDescription</key>
		<string>This identifier is used to deliver personalized ads and measure ad performance.</string>
```

to:

```xml
		<key>NSUserTrackingUsageDescription</key>
		<string>Chúng tôi dùng dữ liệu này để cá nhân hoá quảng cáo bạn thấy trong app, giúp nội dung quảng cáo phù hợp với bạn hơn.</string>
```

(matches the app's `vi_VN` default locale per `CLAUDE.md`'s "Default UI locale is `vi_VN`").

- [ ] **Step 2: Verify the plist is still well-formed XML**

Run: `plutil -lint ios/Runner/Info.plist`
Expected: `ios/Runner/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add ios/Runner/Info.plist
git commit -m "fix(host): more specific NSUserTrackingUsageDescription copy (R10-G)"
```

---

### Task 6: R10-C — `_retryRefillAds` must check `isConnected`

**Files:**
- Modify: `packages/ad_sdk/lib/src/core/ad_manager.dart:2525-2526` (start of `_retryRefillAds()`)
- Test: `packages/ad_sdk/test/connectivity_refill_test.dart`

**Interfaces:**
- Consumes: `isConnected` getter (existing, `ad_manager.dart:1617`, unchanged).
- Produces: no new public symbols. Behavioral change only: `_retryRefillAds()` now no-ops entirely while offline.

**Current code (verified byte-for-byte):**

```dart
  void _retryRefillAds() {
    final ad = _adapter;
    if (ad == null) return;
    // VIP members never load ads. Each load*() already guards on this, but
    // bailing here keeps the periodic scan from logging/iterating pointlessly
    // and is a defense-in-depth backstop if a future load*() drops its guard.
    if (_isVipMember) return;
```

- [ ] **Step 1: Write the failing test in `packages/ad_sdk/test/connectivity_refill_test.dart`**

This file already defines a module-level `_config` (AdMob, line 61), a `_CountingAdapter` class with `loadInterstitialCalls`/`loadRewardedCalls`/`loadAppOpenCalls`/`preloadBannerCalls` counters (line 15), and a `setUp()` that wires `adapter`/`debugConfig`/`debugVipManager`/`debugReconnectDebounce` (line 78) — reuse all of it. `isConnected` reads `_lastConnected` whenever `_connectivityReady` is false (the default in every test in this file, since nothing ever sets it true), so the existing `debugConnectivityChanged(bool)` seam already fully controls `isConnected`'s return value — no new connectivity-state seam is needed. Add a new group after the `'offline → online refill'` group (after line 157):

```dart
  group('_retryRefillAds offline guard (R10-C)', () {
    test('does nothing while offline', () {
      AdManager().debugConnectivityChanged(false);

      AdManager().debugRetryRefillAds();

      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.preloadBannerCalls, 0);
    });

    test('still refills while online', () {
      AdManager().debugConnectivityChanged(true);

      AdManager().debugRetryRefillAds();

      expect(adapter.loadInterstitialCalls, greaterThan(0));
      expect(adapter.loadRewardedCalls, greaterThan(0));
    });
  });
```

`AdManager` does not yet expose a `debugRetryRefillAds()` seam (confirmed: `grep -n "debugRetryRefillAds" packages/ad_sdk/lib/src/core/ad_manager.dart` returns nothing). Add it as a thin `@visibleForTesting` wrapper directly below the existing `debugConnectivityReady` setter (`ad_manager.dart:567`):

```dart
  @visibleForTesting
  void debugRetryRefillAds() => _retryRefillAds();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/ad_sdk && flutter test test/connectivity_refill_test.dart --plain-name "R10-C"`
Expected: FAIL — `loadInterstitialCalls`/`loadRewardedCalls` are non-zero because the current code doesn't check `isConnected`.

- [ ] **Step 3: Add the `isConnected` guard**

In `packages/ad_sdk/lib/src/core/ad_manager.dart`, change:

```dart
  void _retryRefillAds() {
    final ad = _adapter;
    if (ad == null) return;
```

to:

```dart
  void _retryRefillAds() {
    // R10-C — don't even attempt a refill scan while offline; every load*()
    // call below would just fail immediately and log noise.
    if (!isConnected) return;
    final ad = _adapter;
    if (ad == null) return;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/ad_sdk && flutter test test/connectivity_refill_test.dart`
Expected: PASS, all tests in the file green.

- [ ] **Step 5: Run the full `ad_sdk` test suite to check for regressions**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add packages/ad_sdk/lib/src/core/ad_manager.dart packages/ad_sdk/test/connectivity_refill_test.dart
git commit -m "fix(ad_sdk): _retryRefillAds() skips entirely while offline (R10-C)"
```

---

### Task 7: R10-D — timeout on `ConnectionNotifierTools.initialize()`

**Files:**
- Modify: `packages/ad_sdk/lib/src/core/ad_manager.dart:521` (new field next to `_connectivityReady`), `:567` (new setter next to `debugConnectivityReady`, after Task 6's `debugRetryRefillAds()`), `:2480-2486` (`_startConnectivityWatch()` body)
- Test: `packages/ad_sdk/test/connectivity_refill_test.dart` (has the established `SafeLogger.configure`/warning-capture pattern this test needs — see the existing `'isConnected pre-ready guard'` group at line 182; `connectivity_resilience_test.dart` does not have this pattern)

**Interfaces:**
- Consumes: `dart:async`'s `TimeoutException` (already imported in `ad_manager.dart` — used by the existing adapter-init timeout at line ~1095), `package:fake_async/fake_async.dart`'s `fakeAsync()` (already a dependency, used the same way in `ump_consent_test.dart`'s T43/T44 tests — confirmed via `grep -n "fake_async" pubspec.yaml`).
- Produces: `AdManager._connectivityInit` (private field, type `Future<void> Function()`, default `ConnectionNotifierTools.initialize`), `AdManager.debugConnectivityInit` (`@visibleForTesting` setter for `_connectivityInit`), `AdManager.debugStartConnectivityWatch()` (`@visibleForTesting`, returns `Future<void>`, calls `_startConnectivityWatch()`), `AdManager.debugConnectivityReady` getter (`@visibleForTesting bool`, new — only a setter of this name currently exists at line 567).

**Why a new seam is needed:** `ConnectionNotifierTools` is the real third-party plugin from `package:connection_notifier` (`ad_manager.dart:5`), not an internal SDK abstraction. No test anywhere in the suite mocks or controls its timing — every existing connectivity test (`connectivity_refill_test.dart`, `connectivity_resilience_test.dart`, `banner_ad_widget_test.dart`) deliberately routes around it via the `debugConnectivityChanged()` seam (see `connectivity_refill_test.dart:1-6`'s header comment). Without a platform-channel mock registered, calling the real `ConnectionNotifierTools.initialize()` in a test throws almost immediately (`MissingPluginException`) rather than hanging — so there is no existing way to drive a controlled 20-second-hang scenario. `_connectivityInit` makes the call point injectable, exactly like the existing `debug*` seam pattern elsewhere in this file (no new dependency — plain internal Dart).

**Current code (verified byte-for-byte):**

```dart
  Future<void> _startConnectivityWatch() async {
    // ConnectionNotifierTools must be initialised before its stream/isConnected
    // are usable. Nobody else calls this, so the SDK owns it. Best-effort: on
    // platforms/tests without the plugin we simply skip the live watch.
    try {
      await ConnectionNotifierTools.initialize();
      _connectivityReady = true;
      _lastConnected = ConnectionNotifierTools.isConnected;
      _offlineNotifier.value = !_lastConnected;
      _connectivitySub =
          ConnectionNotifierTools.onStatusChange.listen(_onConnectivityChanged);
      SafeLogger.d(_tag,
          () => '📶 connectivity watch started (connected=$_lastConnected)');
    } catch (e) {
      SafeLogger.w(_tag, 'connectivity watch unavailable: $e');
    }
  }
```

Note the existing `catch (e)` is a generic catch (not `on TimeoutException` specifically) — a `TimeoutException` thrown by `.timeout()` is already handled correctly by this existing branch, so no changes to the catch block are needed.

- [ ] **Step 1: Write the failing test in `packages/ad_sdk/test/connectivity_refill_test.dart`**

Add two imports at the top of the file (before the existing `package:applovin_admob_sdk/...` import, matching how other test files order `dart:` imports first): `import 'dart:async';` (for `Completer`) and `import 'package:fake_async/fake_async.dart';`. Add this new group immediately after the `'isConnected pre-ready guard'` group closes (after line 252, before the `'widget: banner reacts to reconnect via initRevision'` group):

```dart
  group('_startConnectivityWatch timeout (R10-D)', () {
    tearDown(() {
      AdManager().debugConnectivityInit = ConnectionNotifierTools.initialize;
      AdManager().debugConnectivityReady = false;
      SafeLogger.resetForTest();
    });

    test(
        'degrades to unavailable after 20s if the native init call never '
        'completes, instead of hanging forever', () {
      final warnings = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.verbose,
        onLog: (level, tag, message) {
          if (level == AdLogLevel.warning) warnings.add(message);
        },
      );
      AdManager().debugConnectivityInit = () => Completer<void>().future;

      fakeAsync((async) {
        AdManager().debugStartConnectivityWatch();
        async.elapse(const Duration(seconds: 20));

        expect(AdManager().debugConnectivityReady, isFalse,
            reason: '_startConnectivityWatch must give up after 20s instead '
                'of hanging forever on a stuck native plugin call');
        expect(warnings.any((w) => w.contains('connectivity watch unavailable')),
            isTrue,
            reason: 'the existing catch(e) branch must still log once '
                '.timeout() throws TimeoutException');
      });
    });
  });
```

`AdManager` does not yet expose `debugConnectivityInit`, `debugStartConnectivityWatch()`, or a `debugConnectivityReady` *getter* (confirmed via `grep -n "debugConnectivityInit\|debugStartConnectivityWatch" packages/ad_sdk/lib/src/core/ad_manager.dart` — no matches; only a setter exists for `debugConnectivityReady` at line 567). Add all three to `ad_manager.dart`:

1. Next to the `_connectivityReady` field declaration (line 521), add the injectable init function:

```dart
  bool _connectivityReady = false;
  Future<void> Function() _connectivityInit = ConnectionNotifierTools.initialize;
```

2. Immediately after the `debugRetryRefillAds()` seam added in Task 6 (which sits directly below the existing `debugConnectivityReady` setter at line 567), add:

```dart
  @visibleForTesting
  set debugConnectivityInit(Future<void> Function() fn) =>
      _connectivityInit = fn;

  @visibleForTesting
  bool get debugConnectivityReady => _connectivityReady;

  @visibleForTesting
  Future<void> debugStartConnectivityWatch() => _startConnectivityWatch();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/ad_sdk && flutter test test/connectivity_refill_test.dart --plain-name "R10-D"`
Expected: FAIL — either a test-runner timeout (current code awaits the real `ConnectionNotifierTools.initialize()` forever, ignoring the injected `_connectivityInit` entirely since it doesn't exist yet) or a compile error if the seams referenced in the test don't exist yet. Confirm it's a real behavioral failure once the seams compile: `debugConnectivityReady` stays `isFalse` is expected either way at this point, but the test hangs/times out because nothing bounds the awaited `Completer` future.

- [ ] **Step 3: Add the injectable field, seams, and timeout**

In `packages/ad_sdk/lib/src/core/ad_manager.dart`, change:

```dart
  Future<void> _startConnectivityWatch() async {
    // ConnectionNotifierTools must be initialised before its stream/isConnected
    // are usable. Nobody else calls this, so the SDK owns it. Best-effort: on
    // platforms/tests without the plugin we simply skip the live watch.
    try {
      await ConnectionNotifierTools.initialize();
      _connectivityReady = true;
```

to:

```dart
  Future<void> _startConnectivityWatch() async {
    // ConnectionNotifierTools must be initialised before its stream/isConnected
    // are usable. Nobody else calls this, so the SDK owns it. Best-effort: on
    // platforms/tests without the plugin we simply skip the live watch.
    try {
      // R10-D — bound this native call the same way adapter.initialize() is
      // bounded above: an unresponsive connectivity plugin must not hang the
      // SDK forever. The existing generic `catch (e)` below already handles
      // TimeoutException correctly (same optimistic-fallback behavior as any
      // other failure here). Routed through _connectivityInit (not the
      // static call directly) so tests can simulate a hang without a real
      // platform channel.
      await _connectivityInit().timeout(const Duration(seconds: 20));
      _connectivityReady = true;
```

Also apply the field and seam additions from Step 1 (the `_connectivityInit` field at line 521, and the three `debug*` seams after line 567).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/ad_sdk && flutter test test/connectivity_refill_test.dart`
Expected: PASS, all tests in the file green.

- [ ] **Step 5: Run the full `ad_sdk` test suite to check for regressions**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add packages/ad_sdk/lib/src/core/ad_manager.dart packages/ad_sdk/test/connectivity_refill_test.dart
git commit -m "fix(ad_sdk): bound ConnectionNotifierTools.initialize() with a 20s timeout (R10-D)"
```

---

### Task 8: R10-E — document why interstitial/rewarded have no watchdog

**Files:**
- Modify: `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:772-780` (doc comment on `debugSimulateInterstitialShowAndDismiss`)
- Test: none (doc-only change, no logic change — nothing to regress)

**Interfaces:** none — this task changes zero executable code.

**Current text (verified byte-for-byte):**

```dart
  /// Test seam: put interstitial slot into `showing`, [onDone]
  /// captured, immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` if [dismissed] is `false`) — same
  /// callback path `_wireInterstitialListener` drives in production. Unlike
  /// App Open, there is no watchdog/timer here: AppLovin's fullscreen
  /// interstitial callbacks are treated as reliable, so this hook only
  /// exercises the plain `beginShow()` → `markDismissed()`/`markShowFailed()`
  /// transition — the exact path a zombie-`showing` bug would corrupt.
  @visibleForTesting
  void debugSimulateInterstitialShowAndDismiss(
```

- [ ] **Step 1: Expand the comment with the architectural rationale**

Change the comment to:

```dart
  /// Test seam: put interstitial slot into `showing`, [onDone]
  /// captured, immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` if [dismissed] is `false`) — same
  /// callback path `_wireInterstitialListener` drives in production.
  ///
  /// Unlike App Open, there is no watchdog/timer here — **a deliberate
  /// choice, not an oversight (R10-E)**. App Open's watchdog exists because
  /// it fires automatically on app foreground with no user-visible loading
  /// state, so a hang there is silent and needs a forced timeout to recover.
  /// Interstitial/rewarded loads are triggered by explicit app flow (level
  /// complete, reward request) with load times that are longer and far more
  /// variable than App Open's (rewarded in particular can legitimately take
  /// many seconds while AppLovin's waterfall mediates across networks) — a
  /// symmetric watchdog here risks killing a slow-but-healthy load far more
  /// often than it would recover a genuinely hung one, absent concrete
  /// evidence of real interstitial/rewarded hangs in production telemetry.
  /// AppLovin's fullscreen callbacks are treated as reliable for these two
  /// surfaces, so this hook only exercises the plain `beginShow()` →
  /// `markDismissed()`/`markShowFailed()` transition — the exact path a
  /// zombie-`showing` bug would corrupt.
  @visibleForTesting
  void debugSimulateInterstitialShowAndDismiss(
```

(The rewarded doc comment at `applovin_adapter.dart:965-970`, which already cross-references this one with "mirrors [debugSimulateInterstitialShowAndDismiss]", is left untouched — it inherits the fuller rationale by reference.)

- [ ] **Step 2: Run `flutter analyze` on the package**

Run: `cd packages/ad_sdk && flutter analyze`
Expected: no new issues (doc-comment-only change).

- [ ] **Step 3: Run the full `ad_sdk` test suite to confirm zero regression**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS, 0 failures (no executable code changed).

- [ ] **Step 4: Commit**

```bash
git add packages/ad_sdk/lib/src/adapters/applovin_adapter.dart
git commit -m "docs(ad_sdk): explain why interstitial/rewarded have no watchdog (R10-E)"
```

---

### Task 9: Full regression pass + Round 11 audit documentation

**Files:**
- Modify: `doc/audit/audit_claude.md` (append a "Round 11" section)
- No code changes in this task.

**Interfaces:** none.

- [ ] **Step 1: Run the full `ad_sdk` package test suite**

Run: `cd packages/ad_sdk && flutter test`
Expected: PASS — 649 (pre-existing) + new tests added in Tasks 1/2/3/6/7 of this plan, 0 failures.

- [ ] **Step 2: Run `flutter analyze` on both the package and the repo root**

Run:
```bash
cd packages/ad_sdk && flutter analyze
cd /Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025 && flutter analyze
```
Expected: no issues in either.

- [ ] **Step 3: Confirm CI is green on all 4 jobs**

Push the branch (or open/update the PR) and run:

```bash
gh run list --limit 5
```

Expected: `sdk`, `sdk-integration`, `sdk-integration-ios`, and `host` jobs all pass for the latest commit — do not consider the fixes complete until this is confirmed (per this repo's own past incident where a green local run did not guarantee CI was green).

- [ ] **Step 4: Append the "Round 11" section to `doc/audit/audit_claude.md`**

Read the file first (it already has an uncommitted "Round 10" section from before this plan was written), then append a new "Round 11" section confirming each of the 8 findings closed:

```markdown
## Round 11 (2026-07-22 or later — date of this task's execution)

All 8 findings from Round 10 closed:

- **R10-A (High)** — `autoRequestUmpConsent` now resolves before AppLovin/AdMob
  adapter init. Fixed in `ad_manager.dart`'s `initialize()`; regression test
  in `consent_persistence_on_init_test.dart`.
- **R10-B (Medium)** — mid-session `isAgeRestrictedUser=true` on AppLovin now
  hard-stops `canRequestAds` immediately (AppLovin has no runtime COPPA API).
  Fixed in `ad_manager.dart`'s `setConsent()`; regression test in
  `ad_manager_core_test.dart`.
- **VIP Android reinstall replay (Medium, architectural)** — the example app
  now mirrors the host app's Android Auto Backup configuration
  (`full_backup_content.xml` / `data_extraction_rules.xml` covering
  `FlutterSharedPreferences.xml`), and `_first_install_guard.dart`'s doc
  comment now accurately describes this as the intended (best-effort,
  non-attacker-proof) mitigation instead of describing Android as
  unmitigated. **This remains a documented limitation, not a 100% fix**: a
  reinstall on a different Google account, or with backup/sync disabled,
  still bypasses the grace guard — there is no backend/server and no new
  dependency involved, per the project's hard constraint.
- **R10-F (Medium)** — a debug-only `assert()` in `splash_screen.dart` now
  fails loudly if `AdProvider.admob` is ever activated while `AdKey.adMob`
  still points at Google's public test ad unit IDs (the warning comment was
  already present).
- **R10-G (Low)** — `NSUserTrackingUsageDescription` in `Info.plist` rewritten
  with specific, localized (vi_VN) copy instead of generic phrasing.
- **R10-C (Low)** — `_retryRefillAds()` now no-ops entirely while offline.
- **R10-D (Info)** — `ConnectionNotifierTools.initialize()` now bounded by a
  20s timeout, matching the existing adapter-init timeout pattern.
- **R10-E (Info)** — doc comment on
  `debugSimulateInterstitialShowAndDismiss` expanded to explain why
  interstitial/rewarded intentionally have no watchdog (App Open's hang risk
  is silent-on-foreground; interstitial/rewarded loads are explicit-flow and
  far more variable in duration).

All 649+ pre-existing tests plus new regression tests for R10-A/B/C/D and
the VIP Android reinstall-replay parity fix pass. CI (`sdk`,
`sdk-integration`, `sdk-integration-ios`, `host`) green.
```

- [ ] **Step 5: Commit**

```bash
git add doc/audit/audit_claude.md
git commit -m "docs(audit): record Round 11 — all 8 round-10 findings closed"
```
