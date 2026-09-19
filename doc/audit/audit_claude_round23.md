# Round 23 (claude) — docs truth, example app, published listing

Scope: every markdown file in `packages/ad_sdk` + root `CLAUDE.md`, the `example/` app as a
copyable reference implementation, and the live pub.dev listing for `applovin_admob_sdk` 2.3.4.
Code correctness (adapters, safety, consent, VIP logic) is out of scope — two other auditors
own that. Every finding below was independently re-verified against the real file after the
research pass (grep/read), not taken on trust.

Known-deliberate items (VipManager offline Ed25519 verification, `kQaTestDeviceHashes`, MJ9
clock drift, m25 native-ad lifecycle, `shared_preferences_android` unbounded) are **not**
re-reported here — none of the findings below touch them.

---

## BLOCKER

### B1 — `README.md:1538` shows a call to `buildAdmobNativeView()` that doesn't compile

```dart
AdManager().adapter?.buildAdmobNativeView()
```

Real signature requires a positional arg on both the interface and both implementations:

- `packages/ad_sdk/lib/src/core/ad_provider_adapter.dart:390` — `Widget? buildAdmobNativeView(Object key);`
- `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:2084` — `Widget? buildAdmobNativeView(Object key) {`
- `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:1899` — `Widget? buildAdmobNativeView(Object key) => null;`

Copy-pasting the README snippet throws `Too few positional arguments: 1 required, 0 given`.

**Fix:** README.md:1538 → `AdManager().adapter?.buildAdmobNativeView(someStableKey)` with a one-line note on what `key` should be (it keys the underlying ad widget across rebuilds).

---

### B2 — `README.md:731` and `:866` document `AdLogLevel.verbose` as the unconditional default; real default is build-mode-gated

- README.md:731 (in the "authoritative" `AdConfig` reference fence) — `AdLogLevel logLevel = AdLogLevel.verbose,`
- README.md:866 — `AdLogLevel.verbose   // everything (DEFAULT)`
- Real code, `packages/ad_sdk/lib/src/config/ad_config.dart:387` — `this.logLevel = kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,`

This isn't stale wording, it's a behavioral contradiction: a **release build** actually defaults to `warning`, not `verbose`. A developer following the README's own "Verbose logs" debugging section and expecting full logs by default in a release build (e.g. reproducing a field issue via `flutter build ... --release` + log capture) gets a silent gap — only warnings/errors show.

**Fix:** `AdLogLevel logLevel = AdLogLevel.verbose,  // debug builds only — release defaults to .warning` in both places.

---

### B3 — `doc/AD_PROMPT_FLUTTER.MD:231` — the flagship splash-bootstrap snippet uses a parameter name that doesn't compile

Step 4.2, the block this file explicitly tells an integrating dev/AI agent to copy verbatim:

```dart
adMob: AdKey.adMob,
```

Real `AdConfig` parameter is lowercase `admob` — `packages/ad_sdk/lib/src/config/ad_config.dart:380` (`this.admob,`) and `:418` (`final AdMobConfig? admob;`). `The named parameter 'adMob' isn't defined` on copy-paste.

Confusingly self-inconsistent: the *same file* gets it right elsewhere — `AD_PROMPT_FLUTTER.MD:683` and `:949` both use `admob: AdKey.adMob` correctly, and `README.md:477,569,1004` are consistent throughout. Only the one flagship Step 4.2 block has the typo — the single place most likely to be copied first.

**Fix:** `doc/AD_PROMPT_FLUTTER.MD:231` — `adMob:` → `admob:`.

---

### B4 — `pubspec.yaml` repository/homepage/issue_tracker point at a 404'd GitHub repo; propagates to pub.dev and one doc file

```yaml
# packages/ad_sdk/pubspec.yaml:11-13
repository: https://github.com/royt93/FlutterBase2025/tree/main/packages/ad_sdk
homepage: https://github.com/royt93/FlutterBase2025
issue_tracker: https://github.com/royt93/FlutterBase2025/issues
```

Actual origin (`git remote -v`): `https://github.com/royt93/FlutterBase2026.git`. `curl -I https://github.com/royt93/FlutterBase2025` → **404**.

Confirmed downstream on the live pub.dev listing: pana's own pubspec check reports *"Homepage URL doesn't exist" / "Repository URL doesn't exist" / "Issue tracker URL doesn't exist"* for these three fields (doesn't cost points yet — the sub-check is still 10/10 — but it is a live, user-facing dead link: pub.dev's "verified repository" badge and the repo/homepage links on the package page are broken today). `doc/AD_PROMPT_FLUTTER.MD:1543` ("Open an issue on GitHub … FlutterBase2025/issues") repeats the same dead URL for anyone told to file a bug.

**Fix:** update all three `pubspec.yaml` fields (and `AD_PROMPT_FLUTTER.MD:1543`) to `FlutterBase2026`, then republish so pub.dev re-crawls and the badge/links go live.

---

## MAJOR

### M1 — README's copy-paste splash sample leaks a `SimpleEventBus` listener; the shipped example silently fixes it without saying so

README.md:537-541 (Step 5 `dispose()`):

```dart
@override
void dispose() {
  _hardCap?.cancel();
  super.dispose();
}
```

No `SimpleEventBus().remove(...)`. `SimpleEventBus` (`lib/src/core/event_bus.dart:7-38`) is a permanent singleton holding `List<void Function(BoolEvent)> _listeners` that only shrinks via explicit `remove()`/`clearAll()`. A developer who follows the README's own Step 5 verbatim accumulates a dangling closure that captures the splash `State` every time the splash is rebuilt/disposed without navigating away (hot reload, re-entrant splash paths). `fire()` swallows callback errors in a try/catch (`event_bus.dart:44-50`), so it never crashes — just leaks silently.

The real example (`example/lib/main.dart:539-546`) keeps the listener in a field and calls `SimpleEventBus().remove(cb)` in both `_goHome()` (`:530`) and `dispose()` (`:543`) — correct, but a reader who trusts the README's own code block (rather than digging into `example/`) copies the buggy version.

**Fix:** update README.md's Step 5 `dispose()` to match the example: store the listener callback in a field at registration time, call `SimpleEventBus().remove(...)` in `dispose()`.

### M2 — README's Step 5 splash sample omits ATT/UMP; a dev who copies only that block ships without consent prompts

`example/lib/main.dart:443-498` does ATT → UMP → `initialize()` with an explicit ordering comment (`:444`). README's literal Step 5 `_SplashScreenState.initState` block (`README.md:429-497`) jumps straight to `AdManager().initialize(...)`, no ATT/UMP calls. Those steps exist in the README, but in separate "Option 0"/"Option 2" sections (`README.md:1612`, `:1637`) and a checklist (`:1786`) — easy to miss if a reader treats Step 5 as "the splash screen, done." Given requirement #6 (consent for every country, applied to both providers), a dev shipping the literal Step 5 sample ships without a UMP/ATT prompt — a legal-compliance gap, not just a UX one.

**Fix:** inline a one-line ATT/UMP call (or a pointer comment: "see Compliance checklist below — call this before `initialize()`") directly in the Step 5 code block, not just prose further down.

### M3 — pana loses 20 points to a real static-analysis warning invisible to this repo's own CI gate

`packages/ad_sdk/lib/src/compliance/compliance_signing.dart:83` — `return _ed25519.newKeyPairFromSeed(seed);` inside a `try` block (`:79-85`), no `await`, no `// ignore:` comment. Confirmed live in the file. pub.dev's pana score (130/160 total) shows "Pass static analysis: 30/50" citing exactly this: *"Returning a 'Future' without 'await' inside a try block."* Local `flutter analyze` reports "No issues found!" — pana runs a stricter/different lint set than this repo's `analysis_options.yaml`, so this genuinely never surfaces in CI. Not a functional bug (the `Future` still gets returned and awaited by the caller either way), but it's 20 free pub.dev points sitting on a one-line fix.

**Fix:** `return await _ed25519.newKeyPairFromSeed(seed);` at compliance_signing.dart:83.

---

## MINOR

### N1 — `README.md:704-755` `AdConfig` "Configuration reference" fence omits real constructor params the rest of the README itself relies on

Missing from the fence: `maxVipStackDuration` (`ad_config.dart:396`, referenced later at README.md:957), `onPrivacyPolicyTap` (`ad_config.dart:402`), `disableAppLovinCmpFlow` (`ad_config.dart:409`, default `true`), `enableCrashGuard` (`ad_config.dart:410`, default `true`). Nothing breaks — defaults still apply — but the block reads as exhaustive and isn't, and it's internally inconsistent with its own later reference to `maxVipStackDuration`.

**Fix:** add the four missing params to the reference fence with their real defaults.

### N2 — `README.md:260-261` pins the recommended floor at `^2.0.0`, three minor+patch releases behind `2.3.4`

Still resolves correctly (`flutter pub get` picks `2.3.4`), so not wrong — just under-recommends and misses calling out fixes like the 2.3.4 rewarded-ad-reload fix.

**Fix:** bump the quick-start floor to `^2.3.0` (or current) periodically at release time.

### N3 — `CLAUDE.md:17-18` test-count claims have drifted upward

Claims `packages/ad_sdk/test/`: "78 files, ~890 tests"; actual today: **96 files, 1111 `test(`/`testWidgets(` calls**. Claims `example/integration_test/`: "27 files (26 suites + scroll_helpers.dart)"; actual: **31 files (30 suites + scroll_helpers.dart)**. Structural claim ("flat, no subfolders") still correct. `.github/workflows/test.yml:99`'s inline comment ("20 file `integration_test/`") has the same drift. Harmless — nobody's integration breaks over a stale count — but worth a find-and-replace next time these are touched.

### N4 — `doc/README_TESTING.md:9-14` and `doc/feature.md:3,21,41` and `doc/architecture.md:395-412` are version-pointer-stale

- `README_TESTING.md` self-labels "OUTDATED / ASPIRATIONAL" already, but still says "860/860 … 76 files … SDK v2.1.0"; actual 1111/1111, 96 files, v2.3.4. Lists only 3 of the 4 CI jobs (omits `pinning-wall`).
- `feature.md` header says "Updated: 2026-08-19", "current: 2.1.0" (×2); actual 2.3.4, six releases and a "rounds 13-22" consent-hardening arc later. File is an explicit historical log, so low risk.
- `architecture.md`'s "Versioning" table stops at "2.1.0 | Current stable"; six releases missing, "Current stable" label now false. Every *behavioral* claim in this file (safety-gate defaults, VIP stacking) was independently re-verified against `lib/` and is still accurate — only the version table is stale.

Low severity (self-aware/historical framing throughout, and none of it contradicts current `lib/` behavior), but all three are the kind of thing that erodes trust in the newest reader who doesn't know which banners are "deliberately historical" vs. accidentally forgotten.

### N5 — `README.md:147` references a doc file that doesn't exist

`` `doc/audit/audit_claude_20260802.md` `` — no such file in `packages/ad_sdk/doc/audit/` (closest match is `audit_claude.md`, no date suffix). Plain inline code text, not a hyperlink, so it doesn't render broken on pub.dev, but it's a dead pointer for anyone reading source.

### N6 — `README.md:2106` points `doc/architecture.md` without noting it's excluded from the published package

`packages/ad_sdk/.pubignore` excludes `doc/*` (except `doc/screenshots/`) from the pub.dev tarball. The README's UMP reference (`README.md:1673`) is already self-aware and annotated "(in host app repo)"; the `doc/architecture.md` reference at `:2106` is not similarly annotated, so a reader on pub.dev (not git) following that link gets nothing.

### N7 — `flutter_secure_storage` due to go stale on pub.dev within ~11 days of this audit

pana currently doesn't dock points for it (grace period), but flags `flutter_secure_storage ^10.0.0` doesn't support the already-published stable `11.0.0`, with an explicit note that points get docked once it's 30+ days old. Not urgent, but a second, previously-undocumented dependency-freshness clock is now running alongside the known `google_mobile_ads` 10-point loss.

---

## UNVERIFIABLE

- Whether the `[License: MIT](LICENSE)` relative link (`README.md:5`) actually renders broken on the live pub.dev page. Deduced from the 404'd repository URL (pub.dev resolves README relative links via the `repository` field), but not directly click-through-confirmed. **Evidence that would settle it:** open `https://pub.dev/packages/applovin_admob_sdk` in a browser and click the License badge/link.
- Exact pana point breakdown beyond what was quoted (WebFetch summarizes via a smaller model). The two load-bearing findings pulled from it (dead repo URLs, the `compliance_signing.dart:83` static-analysis warning) were independently cross-checked against real files/curl and are solid; anything not explicitly re-verified above should be treated as secondhand.

---

## Already confirmed CURRENT (spot-checked, no action needed)

`setNavigatorKey`, `adRouteObserver`/`AdScreenRouteLogger`, `AdManager().initialize(...)` signature, `AdScreen`/`AdScreenState` (`buildBanner`/`buildMrec`/`buildNative`/`showInterstitialAd`/`showRewardedAd`), `AdReadinessSplashController`, full VIP API (`redeemSignedKey`/`addVip`/`bypassVipGuard`), consent API (`requestAtt`/`requestUmpConsent`/`setConsent`/`showPrivacyOptions`/`tcfConsentString`), arbitrator/fill-rate-monitor APIs, event classes, package name/import path, Flutter version floor in Prerequisites, CHANGELOG `[2.3.4]` matches `pubspec.yaml`, CI job names/count/Flutter pin/iOS sharding in `.github/workflows/test.yml`, `doc/SPLASH_SETUP.md`/`doc/UMP_SETUP.md`/`doc/init.md`/`doc/TODO.md` (self-flagged stale host-app leftovers, banners themselves accurate), `doc/AD_PROMPT_FLUTTER.MD` Appendix D merge claim and Appendix A Android→Flutter cheat sheet, `example/` 5-step integration contract (all present, correctly ordered), all QA/debug seams in `example/` (dart-define gated, explicitly commented "do not copy into production", nothing accidentally shippable), `VipRedeemScreen` reference implementation (genuinely parameterized, not hardcoded), `doc/task/**` (self-flagged pre-split scope, doesn't contradict current `lib/`).

---

## Score and verdict

**7/10.**

Nothing here is a runtime crash or a security hole — every BLOCKER is a *documentation* defect: four are actively-wrong instructions/config that a consuming developer or the pub.dev listing itself will hit (a compile error, a compliance-relevant logging assumption, a copy-paste compile error in the flagship prompt doc, and a dead repository link visible on the live package page). Combined with two MAJOR gaps that make it easy to accidentally ship a leaked listener or a missing consent prompt by trusting the README's own code samples over the (correct) `example/` app, this is a "fix four one-line things and republish" state, not a "redesign the docs" state. The actual SDK code, the example app's structure, and the CI/test claims are all in good shape — the gap is entirely between what's written and what's true.

**Verdict: not yet safe to point a new integrator at the README/AD_PROMPT_FLUTTER.MD as-is — B1/B2/B3 are copy-paste traps and B4 is a live broken link on the pub.dev page today; fix the four BLOCKERs (all ≤1 line each) and republish before treating docs as trustworthy, code/example app underneath them is solid.**
