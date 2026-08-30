# Round 23 (agy) — VIP, trial, consent

**Auditor:** Senior Mobile Security & Ads Engineer (agy CLI — Google Antigravity)  
**Date:** 2026-08-25  
**Target Package:** `applovin_admob_sdk` v2.3.4 (pub.dev package source at `/Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/`)  
**Assigned Scope:** Requirements 4 (Trial Mode: 1 Day), 5 (VIP Activation with Zero Backend), 6 (Global Consent & Privacy for AdMob + AppLovin MAX)

---

## 1. Executive Summary & Verification Gate

| Gate Check | Command / Target | Result | Detail |
|---|---|---|---|
| Static Analysis | `flutter analyze packages/ad_sdk/` | **PASS (0 issues)** | Zero lint/analyzer issues across `lib/`, `test/`, `example/`. |
| Test Suite | `flutter test packages/ad_sdk/` | **PASS (1111/1111 passed)** | All 1,111 unit & widget tests pass (~44s). |
| Platform Code | `packages/ad_sdk/` | **PASS (Pure Dart)** | Pure-Dart package wrapping 8 pub dependencies; no custom native code. |

---

## 2. BLOCKER Findings (0)

*No Blocker findings identified in Round 23.*  
All critical issues from previous rounds regarding UMP gate lockouts (BL1), consent footgun fail-open (BL2), fullscreen ad mutex concurrency, TCF purpose bitfield derivation, and process-wide save-queue ordering remain verified and locked with unit tests.

---

## 3. MAJOR Findings (2)

### 🟡 MJ1 — `VipEntry` local ISO-8601 timestamp serialization breaks VIP validity and triggers permanent grant purge upon westward timezone travel or Daylight Saving Time fallback

- **Location:** `packages/ad_sdk/lib/src/vip/vip_entry.dart:64-65`, `packages/ad_sdk/lib/src/vip/vip_entry.dart:38-41`, `packages/ad_sdk/lib/src/vip/vip_manager.dart:734-742`
- **What breaks:**  
  `VipEntry.toJson()` serializes `expiresAt` and `grantedAt` using plain `DateTime.toIso8601String()`. Because `VipManager` creates entries using local `DateTime.now()`, the resulting JSON string has no timezone offset and no `Z` UTC suffix (e.g., `"2026-08-25T12:00:00.000"`).
  
  When the device changes to a time zone with a smaller UTC offset (e.g. user travels west from Tokyo UTC+9 to London UTC+0, or from Vietnam UTC+7 to Europe UTC+1, or US Eastern to US Pacific, or standard autumn DST fallback occurs), `DateTime.parse` in `VipEntry.fromJson` parses the zoneless timestamp as *local time in the new time zone*. This shifts `grantedAt` forward in absolute UTC time.
  
  When `VipEntry.isActiveAt(now)` runs against current time `now` (`_effectiveNow()`), the anti-clock-rollback check:
  ```dart
  if (now.isBefore(grantedAt)) return false;
  ```
  evaluates to `true` because the device's local clock in the new western zone is earlier than the shifted `grantedAt` hour (e.g. 04:00 local < 12:00 parsed).
  
  Consequently:
  1. `isActiveAt(now)` returns `false`.
  2. `remainingAt(now)` returns `Duration.zero`.
  3. On app launch, `VipManager.load()` executes `_purgeExpired()`:
     ```dart
     _entries.removeWhere((e) => !e.isActiveAt(now));
     ```
     which treats the valid grant as expired, permanently deletes it from `_entries`, and overwrites encrypted storage with an empty list via `_save()`.
  4. The user's paid VIP entitlement or active trial is permanently lost upon opening the app in the new time zone.

- **Concrete Scenario:**  
  1. A user in Tokyo (UTC+9) redeems a 30-day VIP key at 12:00 local time (03:00 UTC). `grantedAt` is written to secure storage as `"2026-08-25T12:00:00.000"`.
  2. The user boards a flight and lands in London (UTC+0) 1 hour later (04:00 UTC, 04:00 local London).
  3. The user opens the app. `VipManager.load()` reads storage. `DateTime.parse("2026-08-25T12:00:00.000")` produces `2026-08-25 12:00:00` London time (12:00 UTC).
  4. Current local time `now` is `2026-08-25 04:00:00` (04:00 UTC).
  5. `now.isBefore(grantedAt)` evaluates `04:00 < 12:00` → `true`.
  6. `_purgeExpired()` deletes the entry and saves `[]` to disk. The 30-day VIP is permanently gone.

- **Smallest Correct Fix:**  
  In `packages/ad_sdk/lib/src/vip/vip_entry.dart:64-65`, always serialize timestamps in UTC (`toUtc().toIso8601String()`) so that the ISO-8601 string includes the `Z` suffix (`"2026-08-25T03:00:00.000Z"`):
  ```dart
  Map<String, dynamic> toJson() => {
        'key': key,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'grantedAt': grantedAt.toUtc().toIso8601String(),
      };
  ```
  In `packages/ad_sdk/lib/src/vip/vip_entry.dart:38-41`, compare using UTC timestamps:
  ```dart
  bool isActiveAt(DateTime now) {
    final n = now.toUtc();
    if (n.isBefore(grantedAt.toUtc())) return false;
    return n.isBefore(expiresAt.toUtc());
  }
  ```

---

### 🟡 MJ2 — Default 1-day (24h) first-install VIP grace triggers premature `graceNudgeDueListenable = true` immediately upon first launch

- **Location:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:393-405`, `packages/ad_sdk/lib/src/config/ad_config.dart:48-53`
- **What breaks:**  
  `FirstInstallVipGrace.day` defaults to 24 hours (`Duration(days: 1)`), and `VipManager.graceNudgeThreshold` defaults to 24 hours (`Duration(hours: 24)`).
  
  When `AdManager.initialize()` grants the first-install grace, `addVip()` creates an entry expiring in 24 hours (`exp = now + 24h`) and calls `_refreshActive()`, which invokes `_refreshGraceNudge()`.
  
  In `_refreshGraceNudge()`:
  ```dart
  final due = isActive &&
      exp != null &&
      exp.isAfter(now) &&
      exp.difference(now) <= graceNudgeThreshold &&
      _prefs.getVipGraceNudgeAckExpiryMs() != exp.millisecondsSinceEpoch;
  ```
  `exp.difference(now) <= graceNudgeThreshold` (`24h <= 24h`) evaluates to `true` on the very first second of install.
  
  This causes `graceNudgeDueListenable` ("Your VIP expires soon, renew now!") to fire `true` simultaneously with `firstInstallGrantDueListenable` ("Welcome gift: You got 24h VIP!"). Host apps wiring the grace-nudge listener to display an expiration reminder / renewal SnackBar will show an expiration warning to users the moment they install the app.

- **Concrete Scenario:**  
  1. A user installs the app with default settings (`AdConfig()`).
  2. `AdManager.initialize()` grants 24h first-install VIP.
  3. `firstInstallGrantDueListenable` flips to `true` (welcome banner).
  4. Simultaneously, `graceNudgeDueListenable` flips to `true` (expiring soon warning).
  5. UI displays an "expiring soon" alert to a user who just received a 24-hour welcome grant.

- **Smallest Correct Fix:**  
  In `packages/ad_sdk/lib/src/vip/vip_manager.dart:393-405`, suppress the grace nudge when an entry was granted recently (e.g. within the first hour) and its total duration is less than or equal to `graceNudgeThreshold`:
  ```dart
  final due = isActive &&
      exp != null &&
      exp.isAfter(now) &&
      exp.difference(now) <= graceNudgeThreshold &&
      !_entries.any((e) =>
          e.isActiveAt(now) &&
          e.expiresAt.difference(e.grantedAt) <= graceNudgeThreshold &&
          now.difference(e.grantedAt) < const Duration(hours: 1)) &&
      _prefs.getVipGraceNudgeAckExpiryMs() != exp.millisecondsSinceEpoch;
  ```

---

## 4. MINOR Findings (1)

### ⚪ MN1 — `VipManager.normaliseKey` forces uppercase, causing potential key collisions on case-sensitive key IDs in CRL revocation

- **Location:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:409`, `packages/ad_sdk/lib/src/vip/vip_manager.dart:1268-1272`
- **What breaks:**  
  `VipManager.normaliseKey` transforms key identifiers to uppercase (`raw.trim().toUpperCase()`). When `redeemSignedKey` creates entry keys as `SIGNED_<kid>`, two distinct key IDs differing only by case (e.g., `kid="abc"` and `kid="ABC"`) map to the same entry key `SIGNED_ABC`. Revoking one via CRL clamps both grants.
- **Smallest Correct Fix:**  
  Document or enforce in `tool/vip_mint.dart` that minted `keyId` strings must be uppercase alphanumeric / hex, or preserve exact case in `VipEntry.key`.

---

## 5. Requirement Verification Deep-Dive

### Requirement 4: Trial Mode (1 Day)
- **Implementation:** `AdConfig.firstInstallVipGrace` (`FirstInstallVipGrace.day` = 24h, `ad_config.dart:48-53`), `AdManager.initialize()` (`ad_manager.dart:1999-2059`), `FirstInstallGuard` (`_first_install_guard.dart`).
- **Exact Window & Boundary:** `singleExpiry = now.add(duration)`. At `now == expiresAt`, `now.isBefore(expiresAt)` turns `false`. Expiry timer `_scheduleNextExpiry` purges the entry and flips `activeNotifier` to `false`, resuming ad loading immediately.
- **Reinstall & Uninstall Farming:**
  - **iOS:** Anti-bypass uses iOS Keychain flag `ad_sdk_first_install_granted_v1` (`FirstInstallGuard.hasAlreadyGranted`). Survives uninstall/reinstall.
  - **Android:** Relies on Google Cloud Auto Backup (`FlutterSharedPreferences.xml`). Sideload/manual wipe without backup bypasses local storage (documented deliberate trade-off).
- **Clock Rollback (Backward Moving):** Handled via `_effectiveNow()`. `_prefs.getVipMaxObservedClockMs()` persists the monotonic high-water mark; setting clock backward returns the high-water mark, preventing trial re-arming.

### Requirement 5: Zero-Backend VIP Activation (Ed25519)
- **Cryptography & Public Key:** Ed25519 signature verification in `signed_vip_key.dart` via `cryptography` package. App embeds only public key (`publicKeyBase64`); private key is offline (`tool/vip_mint.dart`). Keys cannot be forged.
- **Key Formats:**
  - `AVP1`: `<seconds>|<keyId>`
  - `AVP2`: `<seconds>|<keyId>|<expEpoch>|<bundleId>` (binds absolute expiration date and package/bundle ID).
- **Revocation (CRL):** `CRL1.<b64(issuedAt|kids)>.<b64(sig)>` with domain-separated signature (`CRL1|` prepended). Prevents signature cross-protocol replay. Replay of older CRL rejected via `issuedAt` comparison.
- **Replay / One-Time Use:**
  - Synchronous in-flight set: `_signedKidsInFlight.add(parsed.keyId)`.
  - SharedPreferences ledger: `_prefs.isVipKeyIdRedeemed(parsed.keyId)`.
  - iOS Keychain durable ledger: `_redeemedKeyLedger.isRedeemed(parsed.keyId)` surviving uninstall/reinstall.
- **Storage Security:** `VipEntriesStore` stores VIP entries in encrypted storage (`flutter_secure_storage`). Plaintext fallback tampering (M6) is detected via `_secureStorageWorks()` probe and clamped to 24h.
- **Stacking & Limits:** Stacks onto latest active expiry (`addVip(stack: true)`). Clamped by `maxStackDuration` (e.g. 90 days).

### Requirement 6: Global Consent & Privacy (AdMob + AppLovin MAX)
- **GDPR / EEA + UK:** UMP CMP flow (`requestUmpConsentFlow`, `requestPrivacyOptionsFlow`) with 180s human-reading timeout and `onLateDismiss` handler.
- **IAB TCF v2.2/v2.3 Parsing:** `IabStorage` reads `IABTCF_TCString`, `IABTCF_gdprApplies`, and `IABTCF_PurposeConsents` from correct platform stores (`SharedPreferencesAsync` on iOS; `<pkg>_preferences` on Android). Checks Purpose 1, 3, 4 before permitting personalization.
- **CCPA / US State Privacy:** `doNotSell` propagated to AppLovin (`AppLovinMAX.setDoNotSell`) and AdMob (`rdp=1` extras). Reads `IABUSPrivacy_String` and `IABGPP_HDR_GppString`.
- **COPPA:** `isAgeRestrictedUser: true` sets AdMob `tagForChildDirectedTreatment: yes`. For AppLovin MAX 4.x (which removed `setIsAgeRestrictedUser`), `AppLovinAdapter` aborts initialization (`_disabledForChildUser = true`), hard-stopping AppLovin ads for child audiences.
- **ATT (iOS):** GAID/IDFA fetch deferred when ATT is pending.
- **Consent Withdrawal Reactivity:**
  - `_syncConsentToAdapter` detects tightening (`downgraded == true`).
  - Calls `_adapter.discardCachedFullscreenAds()`: drops cached AdMob fullscreen ads, resets AppLovin slots, bumps `AdSlot.consentEpoch`.
  - Increments `personalisationRevision`: forces inline banner/MREC/native widgets to rebuild with non-personalized requests.
  - In-flight ad loads completing after withdrawal are rejected via `_discardIfConsentStale`.

---

## 6. UNVERIFIABLE Items

### ❓ UNV1 — Physical iOS Device Keychain & ATT Interaction
- **Unverifiable Aspect:** Behavior of `flutter_secure_storage` (`first_unlock` accessibility) and `app_tracking_transparency` across physical iOS app uninstall and reinstall cycles.
- **Settlement Evidence:** Execution of `integration_test/` on a physical iPhone running iOS 17/18 with real TestFlight/developer-signed builds.

---

## 7. Final Score & Verdict

- **Score:** **8.8 / 10**
- **Production Verdict:** **Conditionally Safe for Production.** The cryptographic architecture, consent propagation pipeline, and offline resilience are exceptionally solid; fixing **MJ1** (UTC timestamp serialization in `VipEntry.toJson`) and **MJ2** (grace nudge suppression during first-hour trial) is strongly advised before shipping to international travelers and global app stores.
