# T203 — Delta/Merkle VIP revocation transparency (EXCLUSIVE)
Priority P3 · Status research-only.

Full signed CRL không scale tốt. Thiết kế signed Merkle root + delta membership/non-membership proofs, anti-rollback, offline cache; Phase 1 threat-model/benchmark, Phase 2 dual-read AVP3 fallback AVP2. Gzip full CRL dễ hơn nhưng không giải quyết dài hạn; online API phá offline promise.

DoD: canonical encoding, rotation, root pinning, downgrade/privacy analysis, migration plan, test vectors/benchmark. Unit proof/rollback/corruption; widget VIP status; integration offline redemption; airplane-mode device smoke. Chưa thay production CRL nếu owner chưa duyệt.

Loop prompt: audit design+score /10, unit/widget/integration test vectors và device smoke prototype; >9/10 mới commit+push prototype, ngược lại loop.
