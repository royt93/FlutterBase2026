# T202 — Consent provenance journal (IDEA)
Priority P2 · Status todo.

Lưu append-only lịch sử consent tối thiểu (source UMP/host/manual, policy revision, timestamp, region signal, hash chain), export cùng compliance report nhưng không raw PII. Khuyến nghị local-only, retention cap, opt-in export; server mạnh hơn nhưng tăng privacy/infra risk.

Research/DoD: threat model, schema/migration/redaction, T200 erase integration, regulator review. Tests unit tamper/rotation/erase; widget history; integration restart/export; offline/storage-full device smoke.

Loop prompt: audit thiết kế+score /10, test vectors unit/widget/integration và prototype smoke; >9/10 commit+push prototype, nếu research-only ghi rõ không push production.
