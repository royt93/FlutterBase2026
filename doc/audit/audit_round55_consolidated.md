# Audit round 55 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `1911077` (round 54's fixes on top of
unreleased round-49 fixes; published pub.dev **3.0.1**; `pubspec.yaml`
still `3.0.1`, CHANGELOG has `[Unreleased]` section).

## Method

Three-way split, each disjoint from every prior round's scope:

1. **`codex exec` (external CLI)** — assigned `packages/ad_sdk/tool/`
   (never audited as its own scope in 5 prior rounds; security-sensitive
   Ed25519 VIP-key CLI tooling). **Hit its usage limit again mid-run**
   (`ERROR: You've hit your usage limit ... try again at 4:55 PM`) —
   produced no findings. Same recurring pattern as rounds 47-49: codex's
   usage resets and re-hits limits unpredictably within a single session.
2. **In-session Claude fork, slice K** — doc-vs-code contract drift: the
   7-point "Integration contract" in `CLAUDE.md` plus the VIP stack
   formula, checked against the actual current code (not just re-reading
   the docs).
3. **In-session Claude fork, slice L** — re-verification (not fresh-file
   audit): picked 6 specific "fixed, verified" claims from rounds 45-54's
   own consolidated docs and re-read the CURRENT code to confirm each fix
   is still actually present and not silently reverted/lost by a later
   merge.
4. **In-session Claude fork (ad-hoc fallback)** — launched to cover
   `tool/` after codex's quota failure, using the identical brief codex
   would have gotten.

## Findings — 1 real (MINOR), in the tool/ fallback pass

**Slice K**: all 6 contract points checked (`SimpleEventBus` replay, App
Open resume's dialog-on-top guard, `_retryRefillAds`'s VIP early-return,
the VIP stack/clamp formula, "only the public key ships", and "no bypass
besides `bypassSafety`/`bypassVipGuard`") matched the documented contract
exactly. No drift found.

**Slice L**: all 6 sampled fix-claims (R45-01, R46-01, M49-03, round-51
`_openedAt` persistence, round-52 crash-guard null-guard, round-54
`resetInMemoryState` wiring) still present in current code exactly as
documented, with the 140 corresponding tests still passing. No regression,
no doc drift.

### MINOR — `tool/vip_keygen.dart` had a TOCTOU window on the private-key file's permissions

**Found by:** in-session fork (codex's replacement pass for `tool/`).
**File:** `tool/vip_keygen.dart`.

The tool wrote the freshly-generated Ed25519 private key to disk via
`File.writeAsString()` (creating it at whatever permissions the process's
umask gives a new file — commonly group/world-readable), then ran
`chmod 600` on it **afterward**. Between those two steps, any other
process already running as a different local user on the same machine
could read the file. `dart:io` has no API to set file permissions at
creation time, so this was a genuine, if low-severity, gap: reachable only
by a co-resident local attacker with precise timing during the one-time
key-minting step, on a developer's own machine — not reachable by an end
user or over a network, and the tool's own header comment already
instructs moving the key to a password manager immediately.

**Fix:** the private-key write now shells out to `sh -c 'umask 077 && cat
> "$0"' <path>`, piping the key bytes over stdin — the subprocess's own
`umask 077` applies from the very moment the file is created, so no window
where it's readable by anyone else ever exists. Windows path unchanged
(no POSIX permission model to race). **Verification:** ran the tool
manually against a temp path, confirmed output unchanged and the file
lands at `600` immediately; ran the full `test/vip_cli_security_test.dart`
suite (6 tests, including the existing assertion that the final mode is
exactly `0600`) — all pass, no regression. The race window itself isn't
practically unit-testable (no deterministic way to observe an OS-level
permission state mid-syscall from Dart), so coverage relies on the
existing final-state assertion plus the structural guarantee the fix
provides.

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder.
- `ConsentProvenanceJournal`'s local-only hash chain still cannot detect
  truncation/forgery by whoever controls the device's own storage.
- `codex`'s usage-limit resets are unpredictable within a session — it
  worked for rounds 50-54, then hit the limit mid-round-55. Future rounds
  should budget for this rather than assume availability just because a
  recent round succeeded.

## Test status

Full `packages/ad_sdk` suite: **2184/2184 passing** (no new automated
test — the fix's own regression coverage is the existing final-permission
assertion in `vip_cli_security_test.dart`, confirmed still passing).
`flutter analyze`: 0 issues.

## Publish-gate status

Round 55 found 1 real MINOR (fixed same round). Round 54 also found 2
MINORs. The two-consecutive-clean-rounds bar remains unmet — round 53 is
still the only fully clean round since round 50.

## Recommendation

No blockers. This round's one finding is dev-tooling-only (never runs on
an end-user device), fixed, and verified. `tool/` has now had one adversarial
pass; `CLAUDE.md`'s integration contract has been independently checked
against current code and holds.
