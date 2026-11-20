# T287 — Verify CRL refresh overlap across public-key rotation

- **Type:** Security follow-up / race verification
- **Priority:** P3 · **Severity:** LOW / theoretical
- **Status:** Open — not reproduced with a real host/key-rotation flow; no runtime fix approved.
- **Evidence:** `lib/src/vip/vip_manager.dart` (`_ensureCachedRevocationLoaded`, `refreshRevocationList`); prior same-manager stale-list race fixed in 3.7.6 and covered by `test/vip_crl_dispose_rollback_test.dart`.

## Hypothesis and boundary

`refreshRevocationList()` uses `_revocationIssuedAt` both as fetched-list freshness state and as a generation check after `_clampRevokedEntries()`. If two overlapping refreshes on the same live `VipManager` use **different** `publicKeyBase64` values, `_ensureCachedRevocationLoaded(newKey)` can reset/reload the cached CRL while the first key's request is parked in clamp. The first continuation may then see a different generation and skip a write that was otherwise valid under its key, or have its in-memory list replaced by the other key's cache.

This is not a confirmed production defect: normal host contract uses one stable key per manager/refresh sequence; no supported concurrent key-rotation workflow or real reproduction is known. Keep distinct from the fixed stale-old-list rollback race; do not weaken the existing stale-write guard.

## Acceptance criteria before changing runtime

- [ ] Build deterministic same-manager interleaving: refresh under key A parks during clamp; refresh under key B loads/accepts its own cache; release A. Assert in-memory and persisted cache behavior against explicitly chosen key-transition contract.
- [ ] Establish whether hosts may rotate `publicKeyBase64` concurrently without dispose/reinitialize; if no supported case exists, document and close no-change.
- [ ] Any proposed fix must preserve fail-open verification, stale issuedAt rejection and same-key overlapping-refresh protection; no global queue may let a stalled network fetch block newer refreshes.
- [ ] Add red regression before runtime change, independent review and targeted/full tests. No release until user approves.

## Out of scope

No key management, signature format, expiry, offline-redemption or CRL transport changes. Do not claim confirmed redeem-after-revoke exposure; none reproduced for this key-rotation hypothesis.
