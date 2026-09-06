# Audit round 41 — risk/TODO/doc-accuracy sweep

Scope: re-audit of `packages/ad_sdk` (SDK + example + integration docs) after
round 40 (GPP privacy shadow fix, 2 new example demo pages — see
`doc/audit/audit_round40_consolidated.md`). Focus: risks, actionable TODOs,
and doc/code mismatches — not a re-litigation of round 1-40's
already-accepted findings (see `CLAUDE.md`'s pending-debt section and the
`vip-offline-gate-and-qa-hashes-are-features` / `avoid-hardcoded-version-numbers-in-docs`
project memories for what's already decided).

## Baseline (this session)

- `flutter analyze` (packages/ad_sdk): **No issues found.**
- `flutter test` (packages/ad_sdk): **1662/1662 passed.**
- `grep -rn "TODO\|FIXME\|HACK\|XXX" lib/ example/lib/`: **zero matches.** No
  actionable code-level TODO debt anywhere in the SDK or example source.

## Findings

### MINOR — README.md:2389 demo-page count is stale

```
- **Demo app**: `packages/ad_sdk/example/lib/main.dart` — 15 self-contained demo pages, one per feature
```

`HomePage`'s tile list is asserted at 21 tiles by
`example/test/home_page_test.dart` (`findsNWidgets(21)`, bumped from 19 in
round 40's commit). "15" was already stale *before* round 40 (19→21 this
round; the prior 19 already didn't match "15") — this number has drifted for
at least two prior rounds without anyone updating the README line. Low
impact (doesn't affect integration), but a maintainer or new reader sizing
up example coverage from this line gets the wrong picture. Fix: either
state the real current count or drop the number entirely (say "one demo
page per feature" — self-updating, no number to go stale again).

**Fixed** — updated to "21 self-contained demo pages" (the current, correct
count) rather than dropping the number, matching this line's own existing
style.

### RETRACTED — README.md:2390 "references a file that does not exist" (false positive)

Original finding checked `find`/`ls` against the **repo-root** `doc/`
(which only holds `doc/audit/` — the audit-report directory used
throughout this session). This repo has two separate `doc/` directories:
repo-root `doc/audit/` and **`packages/ad_sdk/doc/`** (package-level docs:
`init.md`, `feature.md`, `AD_PROMPT_FLUTTER.MD`, `TODO.md`,
`README_TESTING.md`, `SPLASH_SETUP.md`, `UMP_SETUP.md`, and
**`architecture.md`**). Since `README.md` lives in `packages/ad_sdk/`, its
relative link `doc/architecture.md` correctly resolves to
`packages/ad_sdk/doc/architecture.md`, which exists. Not a bug — verified
and struck from the findings list.

## Confirmed clean (checked, no new finding — listed so the picture is complete)

- **`ad_manager.dart`'s timer/subscription lifecycle**: all 7 `Timer`/
  `StreamSubscription` fields (`_initRetryTimer`, `_connectivitySub`,
  `_reconnectDebounceTimer`, `_resumeFallbackTimer`, `_splashBudgetTimer`,
  `_consentDialogTimer`, `_consentGateRecoveryRetry`) are cancelled on
  teardown — most through `_resetGuardState()` (`ad_manager.dart:5680`),
  called from both `_destroy()` (`ad_manager.dart:5626`) and the
  reinit-without-destroy() branch of `initialize()`, per that function's
  own "single source of truth" comment and its round 5/6/14/25/26/27 audit
  history. No leak found — this class of bug already has 6+ rounds of prior
  fixes layered in and it shows.
- **VIP/Ed25519 area**: no raw `Random`/`math.Random` usage found in
  `lib/src/vip/` or `lib/src/core/` — no weak-randomness smell. Did not
  re-derive the signature scheme itself; no new finding beyond what's
  already documented as accepted (README's VIP section limitations).
- **`pubspec.yaml`**: `applovin_max: ^4.6.4` still matches CLAUDE.md's
  documented pinning-wall constraint; no new drift found in this pass.
- **Code-level TODO/FIXME/HACK/XXX markers**: none exist. Every known
  limitation in this codebase is written as prose (README "Known
  limitation" callouts, or an in-code audit-round comment), not a bare
  TODO — consistent with how this repo has operated for 40 rounds.

## Not covered this round (scope/time-boxed, flag for a future round if wanted)

- Did not do a line-by-line read of all 7851 lines of `ad_manager.dart` or
  1800 lines of `vip_manager.dart` — targeted the timer/subscription
  lifecycle and VIP randomness only. A full adversarial line-by-line pass
  (per `audit-must-be-slow-and-adversarial` project memory) on either file
  specifically would need its own dedicated round.
- Did not cross-check every README API signature against code symbol-by-
  symbol (round 40 already did a spot-check pass and found no mismatch);
  this round only checked the two numeric/reference items above.
- Did not re-verify `doc/AD_PROMPT_FLUTTER.MD`'s Appendix D migration guide
  against current code.

## Correction to the above (verified independently)

The `doc/architecture.md` "does not exist" finding above is a **false
positive** — it checked the repo-root `doc/` (which only holds
`doc/audit/`), not `packages/ad_sdk/doc/`, where `architecture.md` actually
lives alongside `init.md`, `feature.md`, `AD_PROMPT_FLUTTER.MD`, `TODO.md`,
`README_TESTING.md`, `SPLASH_SETUP.md`, `UMP_SETUP.md`. Since `README.md`
lives in `packages/ad_sdk/`, its relative link resolves correctly. Struck
from the findings; see this file's earlier retraction note for detail.

The "15 → 21 demo pages" finding was real and has been fixed in
`README.md`.

## ad_manager.dart deep read (round 41, follow-up)

Read in full detail: lines 1–2100 (singleton init, footgun warnings,
opt-in feature toggles + their generation-token guards, self-check,
`experimentBucket`, event/compliance exports, splash budget, navigator
key, banner/MREC/native accessors) and lines 2100–3000 (`initialize()`'s
entire body — GAID resolution, VIP load + first-install grace + config
whitelist, ConsentManager bootstrap, auto-UMP flow, adapter pick/init
with 20s timeout, every `_initSuperseded` abort point). Also read
`destroy()`/`_destroy()` in full (lines 5368–5588+). Remaining ~4850
lines (3000–7851: show/load paths for each ad type, VIP active-state
listener, connectivity watch, consent-apply pipeline, resume/lifecycle
handling, compliance export) were swept via targeted `grep` rather than
read verbatim — see below — given time budget and the density of
already-fixed findings found in the portions read in full.

**Targeted whole-file scans (not just the portion read in full):**
- `!`/force-unwrap non-null assertions: 8 occurrences, all in the
  portions read directly or trivially guarded (e.g. `_eventLog!` right
  after `_eventLog ??= ...`; `_consentManager!` inside `if
  (_consentManager != null)`; `debugForceAutoUmpError!` is a
  `@visibleForTesting` seam only reached when the same field was just
  null-checked). No unguarded unwrap found.
- `Timer(`/`Timer.periodic(`/`.listen(` creation sites: 17. `.cancel()`
  call sites: 20 (more cancels than creates — consistent with the
  documented pattern of cancelling defensively at multiple exit points,
  e.g. both re-arm and `destroy()`). Not a leak signal.
- Empty catch blocks (`catch (_) {}`): exactly 1, at
  `_detachFullscreenDismissWatchers()` (line ~3712) — a best-effort
  listener-removal loop during teardown; swallowing a "listener already
  gone" exception there is correct, not a silent-failure risk.

**Finding: none new.** Every subsystem read in full is already covered by
its own multi-round audit trail inline (explicit `Round-N QC` / `agy`/
`codex` comments at nearly every non-trivial branch — the `initialize()`/
`destroy()` pair alone cites rounds 5, 6, 7, 8, 10, 11, 13, 18, 23, 25,
31, and 37 by name for specific races already found and fixed). The
density of "here's the exact bug this used to be, here's the fix, here's
why it's safe now" comments at every guard checked is itself evidence
this file has had far more adversarial attention than a fresh read in
this round could realistically add on top of.

**Verdict: `ad_manager.dart` is in excellent shape.** No BLOCKER/MAJOR/
MINOR finding from this round's read. Full read coverage: ~2860/7851
lines (36%) plus whole-file pattern scans for the three highest-risk
categories (unguarded unwraps, timer/subscription leaks, silent
failures) — not 100% line-by-line coverage of the remaining 64%, which
should be disclosed rather than implied.

## vip_manager.dart deep read (this round's follow-up)

Read all **1800/1800 lines** of `lib/src/vip/vip_manager.dart`, plus the
files it directly depends on for the actual crypto/persistence:
`signed_vip_key.dart` (379 lines — Ed25519 verify for both AVP1/AVP2 keys
and CRLs), `_redeemed_key_ledger.dart` (139 lines — durable iOS Keychain
one-time-use backstop), `vip_entry.dart` (144 lines), and
`tool/vip_mint.dart`/`tool/vip_crl_mint.dart` (private-key-holding CLI
tools, dev-only). Checked specifically for: signature-verify bypass,
weak/non-constant-time comparisons, nonce/random weakness, redeem/revoke
races, and private-key handling in the mint tools.

**Verdict: no new finding.** This is, by a wide margin, the most heavily
self-documented file in the codebase — nearly every non-trivial line
carries an inline comment naming which audit round (6 through 39) found
and fixed the exact race/edge-case it now guards against (queue-based
save/load serialization surviving `destroy()`+`initialize()`, the MJ9
clock-rollback mark with its round-24 start/expiry asymmetry fix, CRL
domain-separation via a `"CRL1|"` prefix so a public CRL can't be
relabeled and redeemed as a VIP key, atomic in-flight `kid` claiming with
no `await` between check and insert, disposed-manager guards re-checked
after every `await` rather than only at the top of each method). Every
scenario this pass specifically went looking for was already found and
closed in a prior round:

- **Signature bypass**: none — `Ed25519().verify()` (the `cryptography`
  package) is the only verify path for both keys (`signed_vip_key.dart:182`)
  and CRLs (`:335`); no early-return short-circuits it.
- **Timing attack**: no hand-rolled byte/string comparison exists anywhere
  in the verify path — `kid` comparisons are plain `Set`/`String` equality,
  which is fine because `kid` is documented NOT secret
  (`signed_vip_key.dart:31-32`); the actual signature check goes through
  the crypto library, not application code.
- **Weak randomness**: no `Random()` (seeded or otherwise) anywhere in
  scope — `vip_mint.dart`'s default `kid` is a wall-clock timestamp
  (non-secret, collision-avoidance only, not security-bearing).
- **Redeem/revoke races**: `_signedKidsInFlight` (synchronous check+claim,
  `vip_manager.dart:218-222`, `:1405-1413`) and the static, process-wide
  `_saveQueue`/`RedeemedKeyLedger._writeChain` both already close the
  double-redeem and destroy()-mid-redeem windows a prior round (25, QC
  rounds 14-22) found.
- **Private-key handling in `vip_mint.dart`/`vip_crl_mint.dart`**: private
  key is passed via `--priv` CLI arg (shell-history/`ps`-visible on a
  shared machine) — inherent to any offline keygen CLI's UX, not a code
  bug, and no private-key material is written to any file the tool
  touches. No repeat of the committed-`.pepk`-key class of leak
  (`CLAUDE.md`'s pending-debt section) found anywhere in `tool/`.
- Baseline: all 20 VIP-related test files (191 tests —
  `vip_manager_robustness_test.dart`, `vip_crl_dispose_rollback_test.dart`,
  `vip_dispose_mid_redeem_test.dart`, `signed_vip_key_v2_test.dart`, etc.)
  pass together.

The 4 known-and-accepted VIP tradeoffs (network-gated redeem, always-on QA
test-device hashes, trial/VIP-replay-via-reinstall, cross-device key
replay — see `vip-offline-gate-and-qa-hashes-are-features` project memory
and `redeemSignedKey`'s own doc comment at `vip_manager.dart:1243-1256`)
are unchanged and correctly still documented as deliberate, not re-flagged
here.

## Docs deep cross-check (README + AD_PROMPT_FLUTTER.MD)

Cross-checked ~25 named API/behavior claims in `README.md` (Quick Start
steps 1-6, `bootstrap()`/`AdBootstrapOptions`/`AdBootstrapResult`,
`AdReadinessSplashController`, `AdScreen`/`AdScreenState`'s
`buildBanner`/`showInterstitialAd`/`showRewardedAd`, the `AdManager`/
`VipManager`/`ConsentManager` cheat-sheets in "Public API", SSV's
`ssvCustomData`/`ssvUserId`) directly against `lib/` source. All matched —
parameter names, defaults, and described behavior are accurate. Read
`doc/AD_PROMPT_FLUTTER.MD`'s Appendix D (D.1-D.8) structurally; did not
re-verify every code snippet inside it line-by-line (time-boxed — see
below).

### MINOR — README.md:338 Quick Start pins a stale example version

```yaml
dependencies:
  applovin_admob_sdk: ^2.4.0
```

Actual `pubspec.yaml` version is `2.9.20` (40 rounds of fixes since 2.4.0,
including this session's round-40 GPP privacy fix). This is the exact
pattern the `avoid-hardcoded-version-numbers-in-docs` project memory
already warns about — a brand-new integrator following "Quick start" step
1 verbatim pins to a 6-rounds-old release. `AD_PROMPT_FLUTTER.MD`'s own
version-diff snippets (`^1.0.15` → `^1.0.16` etc., lines 1368-1400) are
fine to leave as-is — those are historical upgrade diffs *illustrating* a
past migration, not a "do this now" instruction, which is the distinction
that memory itself draws. Not fixed by this fork (out of scope — reported
for the parent session to fix, per the "audit only, don't self-fix" scope
given for this task). Suggested fix: `applovin_admob_sdk: ^2.9.20` or,
per the same memory's own recommendation, drop the pin to the latest
pattern pub.dev itself suggests (`flutter pub add applovin_admob_sdk`)
instead of a hand-typed version.

### MINOR (observation, not clearly a bug) — no migration entries between "2.x" and the current 2.9.20

Both `README.md`'s "Migration" section (line 2382: `**1.x → 2.x** —
backwards-compatible... Old call sites compile and behave the same.`) and
`doc/AD_PROMPT_FLUTTER.MD` Appendix D (D.1-D.6, last dated entry "audit
rounds 2026-08-19/2026-08-20") stop there — nothing documents 2.1 through
2.9.20, despite dozens of releases and 40 audit rounds in between (T88
`RemoteAdSafetyProvider`, T94 `AdReadinessSplashController`, T106
`bootstrap()`, VIP AVP2, this round's GPP union fix, ...). Every one of
those CHANGELOG entries this fork spot-checked describes itself as
non-breaking, so "nothing to migrate" may be the accurate reason no
entries exist — but that's inferred, not stated anywhere, so it reads
identically to "nobody kept this section updated." Suggested fix (low
urgency): either add a one-line "2.x → 2.9.x: no breaking changes, see
CHANGELOG.md for the fix list" entry so the gap reads as a deliberate
statement instead of neglect, or leave as-is if the maintainer considers
the ambiguity harmless.

### Not covered (time-boxed, same caveat as the rest of this file)

Did not re-verify every code snippet inside Appendix D's D.1-D.8 line by
line against current source (only checked the section headers/dates and
the version-pin distinction above); did not diff the "Public API" cheat
sheet against every symbol actually exported from `lib/applovin_admob_sdk.dart`
(spot-checked ~25 named claims instead, all matched — see above).
