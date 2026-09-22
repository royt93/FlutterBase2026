# Audit Round 72 — Consolidated (Claude + Codex + Gemini, independent, parallel)

Full read-only source audit of `packages/ad_sdk/` + example, run by three independent
AI CLIs (Claude subagent, `codex exec`, `agy`/Gemini) in parallel with the same brief,
each blind to the others' conclusions and to prior audit rounds' verdicts on the
fraud-suspicion question. Individual reports:

- `audit_claude_round72.md`
- `audit_codex_round72.md`
- `audit_gemini_round72.md`

## Fraud / covert ad-injection investigation — **NO EVIDENCE FOUND (3/3 agree)**

All three independently read the full `lib/`/`example/lib/` tree, every native
manifest/Podfile, and every hardcoded string/URL. Findings converge:

- No HTTP client, WebView, or network call exists in package source outside the
  official `applovin_max` / `google_mobile_ads` / `google_mobile_ads_ump` plugins.
- No undisclosed dependency, git-dependency override, or unofficial fork.
- No dynamic code loading, no hidden/off-screen ad views, no synthetic click dispatch.
- Every click/impression/revenue event traces to a genuine native SDK callback.
- The oddly-named `monetization/` classes (`DigitalTwin`, `WaterfallTuner`,
  `RevenueIntegrityLedger`) are on-device, read-only, no-network analytics — not a
  hidden ad network.

**Verdict on the suspicion: unfounded.** This SDK does not inject or swap in another
ad network's code, and does not skim/redirect revenue.

## Production-readiness verdict

**Yes, with conditions.** No auditor found a code-quality or lifecycle BLOCKER in the
ad-serving path itself (banner/interstitial/rewarded/app-open lifecycle, consent
plumbing, offline handling for ad loading are all judged solid/defensive). The real
BLOCKER/MAJOR findings all cluster around one structural fact: **the VIP/trial system
is a zero-backend, offline-only entitlement system**, which mathematically cannot
provide true global single-use codes or a tamper-proof trial clock. That's a design
trade-off the project already made deliberately (see `[[vip-offline-gate-and-qa-hashes-are-features]]`
memory) — but two auditors (Codex: BLOCKER, Gemini: MAJOR) flag that if VIP codes are
ever sold as single-use paid licenses rather than given away as promotions, the current
design cannot honor that promise.

## Consolidated findings requiring a decision (converged across 2-3 auditors)

| # | Severity (by auditor) | Issue | File:line |
|---|---|---|---|
| 1 | Codex: BLOCKER, Gemini: MAJOR, Claude: MINOR | Signed VIP key (`AVP2`) has no global single-use — one leaked code redeems once *per device*, unlimited devices | `lib/src/vip/signed_vip_key.dart:86-120`, `lib/src/vip/vip_manager.dart:1246-1265` |
| 2 | Codex: MAJOR, Gemini: MINOR, Claude: MAJOR | Android has no durable anti-reinstall guard for the 1-day trial (iOS has Keychain; Android relies on OS Auto Backup only) | `lib/src/vip/_first_install_guard.dart` |
| 3 | Codex: MAJOR | Offline-verifiable VIP redemption is still gated on a live-connectivity check — genuine offline activation of a valid code is refused | `lib/src/vip/vip_manager.dart:1246-1337`, `lib/src/vip/signed_vip_key.dart:62-83` |
| 4 | Codex: MAJOR | AppLovin has no runtime signal on mid-session age-restriction change; UMP-skip host misconfig only warns, doesn't hard-fail | `lib/src/core/ad_consent.dart:170-185`, `lib/src/core/ad_manager.dart:379-409` |
| 5 | Gemini: MAJOR | Some `@visibleForTesting` test seams remain callable in release builds — could override anti-uninstall guard or force consent errors in production | (see `audit_gemini_round72.md` for exact seam list) |
| 6 | Gemini: MINOR, Claude: MINOR | Legacy `AVP1` VIP key format is accepted unconditionally — no bundle-ID check, no expiry, no opt-out | `lib/src/vip/signed_vip_key.dart:135,210` |

Independent single-auditor MINOR/NIT items are in each report; none were rated
BLOCKER/MAJOR by more than one auditor and are lower priority than the six above.

Decisions for #1–#5 are being routed to the project owner now (interactive
AskUserQuestion), since each has real architectural trade-offs rather than a single
obviously-correct fix.
