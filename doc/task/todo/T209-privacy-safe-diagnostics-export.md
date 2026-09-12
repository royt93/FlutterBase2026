# T209 — Privacy-safe diagnostics export (ENHANCE)
Priority P1 · Status todo · Depends on T200/T204.

Xuất diagnostics cần schema/version, bounded size, checksum và redact identifier/entitlement secrets. Khuyến nghị shared redaction registry với logger; option per-caller redact dễ lệch policy.

Tests: unit schema/size/redaction/corruption; widget export/share UI; integration import/verify; Android+iOS device smoke + CI secret scan.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.
