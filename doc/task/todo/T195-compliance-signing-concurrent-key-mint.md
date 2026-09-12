# T195 — Serialize mint signing key đầu tiên (FIX)
Priority P1 · Status todo · Source `lib/src/compliance/compliance_signing.dart:62-103,166-178`.

Concurrent exports cùng đọc null, mint hai Ed25519 key rồi ghi đè; bundle vẫn verify nhưng stable public-key contract bị phá. Khuyến nghị process-wide async mutex + double-check storage. Native CAS mạnh hơn nhưng platform-specific.

Tests: unit concurrent cả hai API, corrupt/read-write failure; widget double-tap export; integration concurrent exports; smoke Android+iOS xác nhận cùng public key.

Loop prompt: audit+score /10; unit/widget/integration mọi case; device smoke; >9/10 mới commit+push, nếu không loop.
