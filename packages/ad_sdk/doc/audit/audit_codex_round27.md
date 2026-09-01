# Independent audit round 27 — Codex

**Date:** 2026-09-01  
**Audited tree:** `HEAD` (`d25e43d`), package version 2.9.4  
**Baseline:** `doc/audit/audit_round26_consolidated.md` read in full before reviewing changes  
**Scope:** source/history review from `de9c40a..HEAD`, changelog entries 2.4.0–2.9.4, targeted lifecycle/consent/VIP/policy review. Pub.dev was explicitly out of scope and was not re-checked.

## Executive verdict

The round-26 architecture remains intact, and the T101–T130 work is generally careful and well tested. T115's `AsyncEpoch` migration is behavior-preserving. T102 does close the event-loss race it claims to close, but introduces one **new MAJOR availability risk**: `destroy()` now awaits an unbounded platform-storage persistence chain. A hung `SharedPreferences` write can therefore leave `_destroyInFlight` set forever and make every future `initialize()` wait forever.

The two explicitly deferred round-26 MAJOR findings remain open. The historical AppLovin credential incident also remains a BLOCKER until dashboard rotation/revocation is manually confirmed; source review cannot confirm that action.

**Ready for production use in a real consuming app: NO**  
**Score: 7/10**

## Findings

### Existing BLOCKER — AppLovin credentials remain in reachable git history; rotation unverified

- The deleted file still exists at `11d7421:packages/ad_sdk/doc/archive/AD.MD` and is absent at current `HEAD`.
- A current tracked-tree scan and added-line scan over `de9c40a..HEAD` found no newly introduced likely production AppLovin SDK key/ad-unit secret. Long-token and AdMob-pattern matches inspected were documentation placeholders, official test IDs, or example/test configuration—not a newly added production secret.
- This audit cannot determine whether the AppLovin SDK key and eight ad-unit IDs were rotated/revoked in the AppLovin dashboard. Repo privacy reduces exposure but does not remediate already committed credentials.
- **Status: OPEN BLOCKER (not new).** Required action remains dashboard rotation/revocation plus history scrub before broadening repository access/publication.

### Existing MAJOR #1 — iOS redeemed-key durable ledger has an unlocked RMW

`RedeemedKeyLedger.markRedeemed()` reads the Keychain JSON set, mutates it, then writes it with no serialization primitive (`lib/src/vip/_redeemed_key_ledger.dart:66-75`). Two concurrent redemptions can both read the same set and the later write can erase the other new `kid`. This weakens durable one-time-use protection but does not permit signature forgery.

**Status: OPEN, unchanged from round 26.**

### Existing MAJOR #2 — late AdMob fullscreen failures mutate/emit after disposal

The successful callbacks use `_discardIfDisposed(...)` (`lib/src/adapters/admob_adapter.dart:898`, `:1196`, `:1384`, `:1594`), but the corresponding `onFailed` callbacks do not (`:913-924`, `:1215-1226`, `:1399-1410`, `:1614-1625`). A failure delivered after adapter teardown still changes slot state and emits through the retained sink.

**Status: OPEN, unchanged from round 26.**

### NEW MAJOR — T102 makes teardown availability depend on an unbounded storage write

`AdManager.destroy()` publishes `_destroyInFlight` and only clears/completes it after `_destroy()` returns (`lib/src/core/ad_manager.dart:5157-5189`). T102 changed teardown to `await _eventLog?.flush()` without a timeout (`:5406-5417`). `flush()` schedules and awaits `_persistChain` (`lib/src/compliance/ad_event_log.dart:126-131`), whose terminal operation awaits the platform-backed `setComplianceLogRaw` (`:117-121`). If that platform call never returns, `destroy()` never completes and later `initialize()` calls remain serialized behind it.

This is inconsistent with adjacent teardown defenses: event-stream close is explicitly capped at two seconds (`lib/src/core/ad_manager.dart:5309-5327`) and showing-fullscreen drain is explicitly bounded. T102 correctly closes the old destroy→initialize lost-log race—the old log is now persisted before it is nulled—but trades silent audit-log loss for a possible permanent SDK outage.

**Recommendation:** bound the flush wait. On timeout, detach/null the old log and continue teardown while logging/recording a diagnostic. Add a test with a never-completing persistence seam, not merely `debugPersistDelay`, proving both `destroy()` and a queued `initialize()` recover.

### No other new rated findings

I found no new consent, VIP-verification, first-install-grace, rewarded-credit, click-after-dispose, or widget timer/controller regression in the reviewed T101–T130 paths.

## High-risk change verification

### T102 / `destroy()` event-log flush

- **Race claimed by changelog: closed.** The old event log is awaited before `_eventLog = null` (`lib/src/core/ad_manager.dart:5406-5417`), so a caller that awaits `destroy()` cannot initialize a replacement log against the pre-flush persisted snapshot.
- **New risk: unbounded hang.** See NEW MAJOR above.
- The focused test verifies ordering with a finite artificial delay (`test/destroy_awaits_event_log_flush_test.dart`), but does not exercise a write that never resolves.

### T115 / `AsyncEpoch` migration into `AdLoadingDialog`

**PASS — behavior equivalent to the old `_generation` counter.** A new buffer invalidates once then captures the current token (`lib/src/widget/ad_loading_dialog.dart:192-200`), while `dismiss()` and `resetState()` invalidate outstanding work (`:63-77`, `:132-153`). The delayed continuation checks `isCurrent` before touching route/global state and still calls `onComplete` on the stale path (`:212-223`). `AsyncEpoch.invalidate()` increments exactly once and `isCurrent()` compares token equality (`lib/src/utils/async_epoch.dart:20-31`), matching the former increment/compare semantics. The static epoch is deliberately never `dispose()`d, which is correct because this static dialog subsystem is reusable after manager destroy/re-init.

### T103–T105 lifecycle fixes

- Splash callback guard is a plain disposed boolean, avoiding writes to a disposed notifier; SDK splash controller also marks navigation terminal and cancels its hard-cap timer (`lib/src/widget/ad_readiness_splash_controller.dart:144-175`).
- AppLovin native tombstones are bounded and preserve late-callback protection.
- AdMob inline click/open callbacks now use identity checks, and AppLovin clears `eventSink` on disposal. These changes do not close the separate fullscreen `onFailed` gap above.

### T106 bootstrap and consent ordering

`bootstrap()` awaits ATT, then UMP, then invokes/awaits initialization completion (`lib/src/core/ad_bootstrap.dart:66-77`, `:89-126`). The tightening-consent apply gap remains closed by `canRequestAds` including `_consentProviderApplyInFlight` (`lib/src/core/ad_manager.dart:1361-1388`) and by setting/clearing that flag around provider application in `setConsent()`.

### T108 reconnect retry policy

Reconnect processing exits while offline and clears only opted-in slot cooldown state before routing recovery through the ordinary public load gates (`lib/src/core/ad_manager.dart:7337-7387`). It does not bypass VIP, consent, cap, or connectivity checks.

### T111/T121 safety refresh/ramp

Remote refresh discards a response if teardown occurred while the fetch was in flight; local ramp applies before remote overrides. I found no new route around the existing show/load gates.

### T123 smart prefetch and T124 adaptive surface

Journey prefetch routes through normal manager load methods. `AdaptiveAdSurface` owns one debounce timer and cancels it on replacement and disposal (`lib/src/widget/adaptive_ad_surface.dart:55-86`); it freezes surface changes while fullscreen is busy. No new timer leak found.

## Seven-point product checklist

| # | Result | Evidence and caveat |
|---|---|---|
| 1 | **PASS** | Package explicitly supports Android/iOS (`pubspec.yaml:22-29`), depends on both native provider plugins (`:61-66`), validates provider-specific config (`lib/src/config/ad_config.dart:384-423`), and constructs `AdMobAdapter` or `AppLovinAdapter` (`lib/src/core/ad_manager.dart:2854`). Both implement the common provider interface and the shared contract matrix exists in `test/adapter_contract_test.dart`. |
| 2 | **PASS-WITH-CAVEAT** | Load paths fail cleanly while offline (`lib/src/core/ad_manager.dart:6113-6116` is representative), connectivity recovery refills all fullscreen slots through gated loaders (`:7337-7387`), and UMP has reconnect/backstop handling. Caveat: the new unbounded event-log flush can brick teardown/re-init independently of ad-network connectivity (NEW MAJOR). |
| 3 | **PASS-WITH-CAVEAT** | App-open/interstitial/rewarded and inline instances have explicit disposal; AdMob cancels the app-open watchdog and disposes native ads/slots (`lib/src/adapters/admob_adapter.dart:556-652`), AppLovin clears listeners, cancels retry/watchdog timers, destroys views, and disposes slots (`lib/src/adapters/applovin_adapter.dart:788-919`), dialog animation is disposed (`lib/src/widget/ad_loading_dialog.dart:260-299`), and adaptive debounce is cancelled (`lib/src/widget/adaptive_ad_surface.dart:55-86`). Caveat: deferred AdMob fullscreen failure-after-dispose MAJOR remains open. |
| 4 | **PASS-WITH-CAVEAT** | First-install grant is guarded before application in manager initialization (`lib/src/core/ad_manager.dart:2565-2635`); the iOS Keychain marker survives reinstall (`lib/src/vip/_first_install_guard.dart:8-25`, `:116-125`) and clock high-water protection remains in `lib/src/vip/vip_manager.dart:286-389`. Android resistance is explicitly best-effort via host Auto Backup and is bypassable if backup/sync is disabled (`lib/src/vip/_first_install_guard.dart:27-56`, `:114-130`), so “resists trivial reinstall” is conditional on correct consuming-app manifest/backup configuration. |
| 5 | **PASS-WITH-CAVEAT** | Offline AVP2 verification signs duration, key id, expiry, and bundle id (`lib/src/vip/signed_vip_key.dart:86-120`) and verifies against 32-byte Ed25519 public keys without shipping the private key (`:121-180`). No new cryptographic weakness found. Caveat: deferred unlocked redeemed-ledger RMW remains the only newly relevant weakness; global cross-device one-time use is impossible without a backend and is documented. |
| 6 | **PASS-WITH-CAVEAT** | T106 enforces ATT→UMP→init (`lib/src/core/ad_bootstrap.dart:66-126`). Consent maps GDPR, COPPA/TFUA and CCPA signals (`lib/src/core/ad_consent.dart:15-31`, `:111-121`, `:135-190`); AppLovin receives consent/do-not-sell and AdMob receives child/under-age configuration plus per-request RDP. Caveat: AppLovin MAX exposes no runtime COPPA flag, so known child-directed mode is handled by refusing AppLovin initialization; a mid-session flip requires destroy/re-init (`lib/src/core/ad_consent.dart:145-160`). “Every country” means the global conservative/UMP behavior plus US-state signals, not automatic country-law classification by this SDK. |
| 7 | **PASS-WITH-CAVEAT** | Fullscreen formats share a busy mutex (`lib/src/core/ad_manager.dart:1443-1497`, `:6154-6160`), resume app-open does not bypass shared caps (`:6063-6073`), interstitial/rewarded use safety and placement gates (`:6092-6117`, `:6449-6465`), and reward success comes only from native earned callbacks (AdMob `lib/src/adapters/admob_adapter.dart:1467-1548`; AppLovin `lib/src/adapters/applovin_adapter.dart:1579-1626`). Inline widget instances dispose their subscriptions/notifiers/native instances. Caveat: production approval remains blocked by the unconfirmed AppLovin credential rotation, and consuming-app layout is still responsible for allocating banner space rather than overlaying content. |

## Verification performed and limitations

- Read `audit_round26_consolidated.md` in full.
- Read `git log --oneline de9c40a..HEAD -- packages/ad_sdk` and changelog entries 2.4.0–2.9.4.
- Inspected source/diffs for T102, T103–T106, T108, T111/T121, T115, T123/T124 and the consent/VIP/lifecycle-related manager/adapter changes.
- `flutter analyze`: **PASS, no issues**.
- A full `flutter test` run was started and progressed through the suite; tool output was truncated before its final summary. A clean rerun could not be completed because the managed sandbox denied Flutter writing `/Users/LoiTP/development/flutter/bin/cache/engine.stamp`. I therefore do **not** independently claim the changelog's “1476 pass” count, although no failing test was observed in the captured run.
- No pub.dev/network verification was performed, per request.
- Dashboard rotation, real-device ad fill, App Store/Play policy review, host banner layout, and the consuming app's Android Auto Backup manifest are outside source-only verification.

## Prioritized actions

1. Rotate/revoke the exposed AppLovin SDK key and all eight ad-unit IDs; record dashboard confirmation.
2. Scrub the historical secret commit before making the repository public or widening access.
3. Add a bounded timeout/fallback to the T102 event-log flush and test a never-completing write.
4. Serialize `RedeemedKeyLedger.markRedeemed()` read-modify-write operations.
5. Add disposed/generation guards to all four AdMob fullscreen `onFailed` callbacks and clear the sink on teardown.
6. Verify the consuming Android app opts into and correctly scopes Auto Backup for the grace marker.
7. Run the complete unit/widget suite in an unrestricted Flutter environment and archive the final count.
8. Perform a real-device Android+iOS smoke pass for ATT→UMP→init, offline reconnect, teardown/re-init, and all four requested ad formats.
