# Audit — pub.dev score, docs-for-any-dev, and public-repo readiness

**Date:** 2026-09-20
**Trigger:** user asked for a professional audit of the pub.dev listing,
README, `example/lib/main.dart`, and `doc/AD_PROMPT_FLUTTER.MD` to (a) raise
pub.dev's score, (b) make sure "any dev" can use the SDK, and (c) evaluate
readiness for the GitHub repo (`royt93/FlutterBase2026`) to go from private
to **public**.

## 0 — Read this first: a NEW finding, not previously documented anywhere

`CLAUDE.md`'s "Known pending security debt" section already documents one
leaked secret: `android/app/private_key.pepk` (a Play App Signing key
export), committed at `60a1f3d` (2024-12-20), removed from HEAD since, but
still retrievable via `git cat-file -p 60a1f3d:android/app/private_key.pepk`.
The plan on file: check Play Console whether it was ever live, rotate if so,
purge from history only after rotating.

**This audit found a second, previously undocumented instance of the same
class of risk:**

- **File:** `android/app/keystore.jks` — a Java KeyStore (2540 bytes),
  which is a different and generally *more directly usable* kind of secret
  than a `.pepk` export: a `.pepk` file is encrypted with **Google's** public
  key (only Google can decrypt it — it's the transport format for Play App
  Signing enrollment), whereas a `.jks` keystore contains the signing private
  key itself, protected only by whatever password was set on it. If that
  password is weak, reused, or itself sitting in a build script or CI config
  anywhere in this repo's history, this file alone is enough to sign an APK
  that Android would trust as a legitimate update from the same developer.
- **Committed:** `266bd012` (2025-04-19, "up"), alongside real
  `AndroidManifest.xml` signing-adjacent changes — not a throwaway test file.
- **Still reachable right now:** not present at the *tip* of any branch, but
  the commit that added it is an ancestor of **four branches still pushed to
  GitHub**: `origin/audit-round9-n1-n6-f7`, `origin/release20260322`,
  `origin/release20260616`, `origin/release20260814`. Anyone who can clone
  this repo can run `git show 266bd012:android/app/keystore.jks` today.
- A broader sweep (`git log --all -G` across all 1183 commits on all refs)
  for PEM private-key headers, Google/AWS/Slack/Stripe API-key shapes, and
  `.env`/`google-services.json`/`GoogleService-Info.plist`/service-account
  files found **nothing else**. This appears to be the only other exposure of
  this kind.
- The doc `doc/task/todo/T205-vip-cli-secret-input.md` (now
  `doc/task/done/`) matched a filename grep for "secret" but is a planning
  doc about *preventing* a different, unrelated CLI-argv leak — not itself a
  secret. Ruled out.

**Why this matters more than anything else in this audit:** `CLAUDE.md`
itself says, in plain text, exactly which commit hash holds the pepk key and
exactly how to extract it — a genuinely useful runbook for *this team*, but a
ready-made attack recipe for anyone if the repo goes public before the key
question is resolved. The same is now true of `keystore.jks` once this audit
doc is committed. **Making the repo public is not just "the code becomes
visible" — it's "these two recipes become visible too."**

**Status: `keystore.jks` purged from git history — 2026-09-20, same session.**
User made an informed, explicit decision (via two separate confirmations,
after the check-Play-Console-first recommendation and its risk were stated
plainly twice) to purge without checking Play Console first, accepting that
this does not neutralize the key if it was ever live — only rotation would.
Executed: mirror-cloned the real repo into an isolated scratch copy,
`git filter-repo --path android/app/keystore.jks --invert-paths --force`,
verified the blob is gone from every commit in the rewritten copy, confirmed
`main`'s tip hash was unchanged (the file was never in `main`'s ancestry —
only `audit-round9-n1-n6-f7`, `release20260322`, `release20260616`,
`release20260814` were affected), force-pushed those 4 rewritten branches to
`origin`, then fetched and re-verified from the real remote that the blob is
gone from all 4. The two `worktree-*` branches on origin were checked and
never contained this file — no action needed there.

**`private_key.pepk` is unaffected by this — still exactly as `CLAUDE.md`
already documents** (committed `60a1f3d`, removed from HEAD, still
retrievable from history, decision already on file from audit round 34:
check Play Console, rotate if it was ever live, purge only after). This
audit did not change that plan or that file.

**Before flipping the repo to public, still outstanding:**
1. Check Google Play Console: was `keystore.jks` or `private_key.pepk` ever
   used to sign a build that reached real users? (Purging `keystore.jks`
   from git does not answer this — if it was live, the key itself is
   unchanged and still exploitable by anyone who already has a copy from
   before today.)
2. If yes for either: rotate that signing identity via Play Console's
   key-upload-key rotation.
3. `private_key.pepk` still needs its own `git filter-repo` pass (not done
   in this session — scope was `keystore.jks` only).
4. Anyone else with an existing local clone of the 4 rewritten branches will
   hit a diverged-history error on their next `git pull` there — they need
   `git fetch` + reset to the new tips, not a plain pull.

## 1 — pub.dev score: what's actually gating it right now

Score analysis for the just-published 3.0.7 is still pending as of this
audit (pub.dev needs some time after each publish), so this is based on
running the same checks pana runs, directly:

- **`flutter analyze`: 0 issues.** Static-analysis category is already maxed.
- **`LICENSE` present at the package root, MIT, well-formed.** File-conventions
  category already gets credit for this.
- **`pubspec.yaml` `description`: 152 characters** — under both the 160-char
  pana-scoring limit and the 200-char upload-API hard limit (there's a
  standing comment in `pubspec.yaml` explaining why this matters and that
  `--dry-run` won't catch it). No action needed.
- **"Support up-to-date dependencies" — `flutter pub outdated` shows 5 direct
  dependencies behind latest:**
  | Package | Current | Resolvable | Latest | Gap |
  |---|---|---|---|---|
  | `connection_notifier` | 4.1.0 | 4.1.1 | 4.1.1 | patch — **free win, no known blocker** |
  | `shared_preferences_android` | 2.4.23 | 2.4.23 | 2.4.28 | patch, but constraint is already unbounded (`>=2.4.0`) — a lockfile-refresh issue, not a pubspec issue |
  | `flutter_secure_storage` | 10.3.1 | 11.2.0 | 11.2.0 | major — capped at `<12.0.0` on purpose (`win32`/`package_info_plus` conflict, documented in `pubspec.yaml`) |
  | `package_info_plus` | 9.0.1 | 10.2.1 | 10.2.1 | major — same Dart/Flutter-floor wall as below |
  | `google_mobile_ads` | 7.0.0 | 9.1.0 | 9.1.0 | 2 majors — needs Dart ≥3.10/Flutter ≥3.38, which would raise this package's own environment floor and break every current consumer (this is the gap `CLAUDE.md` already quantifies as "the last 10 pub.dev points") |

  **Only `connection_notifier` is a free, no-downside bump right now** — it
  wasn't applied in this audit since it's a code change and this round was
  scoped to assessment, not fixes. Everything else genuinely requires the
  Flutter-floor decision `CLAUDE.md` already flags as a breaking, deliberate
  future step, not something to rush for a few pub.dev points.
- **`dart pub publish --dry-run`: 1 standing warning** —
  `shared_preferences_android` has no upper bound. Confirmed intentional
  (comment in `pubspec.yaml` explains the alternative, a pinning wall, is
  worse) — not a real gap, pana likely already treats this as informational
  rather than points-losing for this specific case, but can't be fully
  confirmed until the pending analysis completes.

**Bottom line on score:** there is no quick, safe way to meaningfully move
the number beyond the one patch bump above. The real ceiling is the
documented Flutter/Dart floor decision, which is a product decision (breaking
change for consumers) far bigger than a docs audit.

## 2 — Docs and example: already substantially fixed this session

Before this round, the same session already found and fixed (published as
3.0.5–3.0.7, see `CHANGELOG.md`):
- `README.md` was over pub.dev's ~128KB render cap, silently truncating the
  live page — condensed under the limit without touching Quick Start,
  Consent & compliance, or Known limitations.
- Quick Start's splash sample didn't explain its implicit UMP-consent call.
- pub.dev's Example tab priority order (`example/example.md` >
  `example/lib/main.dart` > ... > `example/README.md`) meant
  `example/README.md` was never actually shown regardless of quality — first
  "fixed" by adding `example/example.md`, then reverted on user review
  because that traded away real, runnable code for prose, which the file's
  own top comment records as a previously-rejected tradeoff.
- `example/lib/main.dart` had ~124 lines of internal task-shorthand (`T117`,
  `Round-27 audit fix`, ...) in comments — stripped, 4949 lines and 48 demo
  pages unchanged.
- Added a bold "don't copy this whole file into your app" warning as the
  first lines of `main.dart`, after reasoning through a support scenario
  where a developer did exactly that and concluded the SDK was broken (root
  cause: replaced their own UI, kept placeholder ad IDs, skipped native
  config — none of which any doc can automate away).
- `doc/AD_PROMPT_FLUTTER.MD` had ~25 dangling `Q10`/`Q14A`/`Q27`-style
  references to a lost numbered list — removed.

Re-reading both documents fresh for this round, against the bar "any dev,
not just an AI agent, can use this":

- `AD_PROMPT_FLUTTER.MD` remains, by its own explicit first-page statement,
  **not meant for a human to read start-to-finish** — it's a prompt template
  for an AI coding agent, and redirects a human without one to
  `README.md`'s Quick Start. This is a reasonable, intentional split, not a
  gap — the two documents serve different audiences, and grading the prompt
  template against "step-by-step for anyone" would be grading it against a
  job it explicitly declines.
- `README.md`'s "Quick start" (6 numbered steps: dependency, Android config,
  iOS config, bootstrap, splash init, show ads) reads as genuinely
  followable by an unfamiliar Flutter developer, with one caveat: it still
  assumes the reader already knows how to obtain an AppLovin SDK key and
  AdMob App ID/ad-unit IDs from their own dashboards — reasonable to assume,
  since the SDK has no way to provision those for anyone, but worth a reader
  keeping in mind before concluding a stall there is the SDK's fault.
- No further broken cross-references, dangling placeholders, or contradicted
  claims were found across the three documents in this pass.

## 3 — Other public-repo-readiness notes (beyond secrets)

- `README.md`'s Support section currently reads: *"this package's source
  repo is private, so there's no public issue tracker — email
  `loitp@skyjoy.vn`..."* — this becomes stale the moment the repo goes
  public (a public repo should point to GitHub Issues first). Small, easy
  fix, but only worth doing at the same time as the actual switch to public,
  not before.
- The **root**-level `LICENSE` (GPLv3, likely a leftover from when the former
  host app lived in this repo — see `CLAUDE.md`'s note that the host app has
  since moved to its own repo) has a cosmetic oddity: the name "McKimQuyen"
  is spliced into the middle of the standard FSF copyright line. Harmless,
  but looks like a stray find-replace artifact and would look unprofessional
  to any outside visitor browsing repo root. The **package-level**
  `packages/ad_sdk/LICENSE` (MIT, what actually governs the published pub.dev
  package) is clean and unaffected.
- No personal names, other internal project names, or non-package emails
  found anywhere in `README.md`, `AD_PROMPT_FLUTTER.MD`, or `CHANGELOG.md`
  beyond the one intentional support-contact email above.

## Objective assessment

**Docs and example, for pub.dev score and general-developer usability:**
in good shape after this session's fixes — no further high-value, low-risk
change identified beyond the one free dependency bump (§1) and the
stale-support-line fix to do at publish time (§3). The score ceiling below
100 is a known, quantified, deliberate tradeoff (Flutter/Dart floor), not an
oversight.

**Readiness to make the GitHub repo public: not yet.** The `keystore.jks`
finding in §0 is a real, previously-unknown gap in the repo's own documented
remediation plan, and it needs the same Play-Console-check-then-rotate
sequence already planned for the `pepk` key before any history rewrite or
visibility change — not because the docs aren't good enough, but because
going public would hand out the exact recipe to retrieve both keys, and one
of them is directly usable to sign an APK if it ever was.
