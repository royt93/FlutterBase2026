# T287 — Verify CRL refresh overlap across public-key rotation

- **Type:** Security follow-up / race verification
- **Priority:** P3 · **Severity:** LOW / theoretical
- **Status:** closed — deterministic fake-key probe found no stale write (2026-11-20); no runtime fix justified.
- **Evidence:** `lib/src/vip/vip_manager.dart` (`_ensureCachedRevocationLoaded`, `refreshRevocationList`); prior same-manager stale-list race fixed in 3.7.6 and covered by `test/vip_crl_dispose_rollback_test.dart`.

## Hypothesis and boundary

`refreshRevocationList()` uses `_revocationIssuedAt` both as fetched-list freshness state and as a generation check after `_clampRevokedEntries()`. If two overlapping refreshes on the same live `VipManager` use **different** `publicKeyBase64` values, `_ensureCachedRevocationLoaded(newKey)` can reset/reload the cached CRL while the first key's request is parked in clamp. The first continuation may then see a different generation and skip a write that was otherwise valid under its key, or have its in-memory list replaced by the other key's cache.

This is not a confirmed production defect: normal host contract uses one stable key per manager/refresh sequence; no supported concurrent key-rotation workflow or real reproduction is known. Keep distinct from the fixed stale-old-list rollback race; do not weaken the existing stale-write guard.

## Reproduction result (2026-11-20)

- Two overlapping refreshes on the same live manager using different public keys were tried with valid signed lists. The fresh (new-key) fetch/cache completes while the old-key verification is in flight; when old-key verification resumes, `_ensureCachedRevocationLoaded` reloads the newer cache and sets `_revocationIssuedAt`, then the old response is rejected by the existing freshness check before clamp/cache write.
- This setup does **not** enter the reported state “older list accepted, then newer list accepted while the older clamp write is held.” Once a list is accepted it immediately updates RAM and clamps; a newer accepted refresh only skips persistence if `_clampRevokedEntries()` performs no save. No deterministic interleaving found that makes the older `setVipRevocationCache` wait while another public key changes the cache.
- Result: no stale write, no runtime regression test retained, no fix justified. Keep this record as a closed negative probe; reopen only with a production trace or a deterministic fixture that proves a CRL under key A can still be written after a key-B cache supersedes it.

## Acceptance criteria before changing runtime

- [ ] Build deterministic same-manager interleaving: refresh under key A parks during clamp; refresh under key B loads/accepts its own cache; release A. Assert in-memory and persisted cache behavior against explicitly chosen key-transition contract.
- [ ] Establish whether hosts may rotate `publicKeyBase64` concurrently without dispose/reinitialize; if no supported case exists, document and close no-change.
- [ ] Any proposed fix must preserve fail-open verification, stale issuedAt rejection and same-key overlapping-refresh protection; no global queue may let a stalled network fetch block newer refreshes.
- [ ] Add red regression before runtime change, independent review and targeted/full tests. No release until user approves.

## Out of scope

No key management, signature format, expiry, offline-redemption or CRL transport changes. Do not claim confirmed redeem-after-revoke exposure; none reproduced for this key-rotation hypothesis.
