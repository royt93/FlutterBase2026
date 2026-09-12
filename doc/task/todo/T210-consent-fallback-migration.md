# T210 — Offline-first consent fallback và migration (ENHANCE)
Priority P1 · Status todo.

Định nghĩa policy khi UMP/ATT timeout, plugin lỗi, cache cũ hoặc policy revision thay đổi; lưu lý do fallback và bảo toàn conservative default. Khuyến nghị versioned state machine; hard-coded bool nhanh nhưng khó audit.

Tests: unit timeout/error/revision/migration; widget dialog retry/status; integration offline→online; Android+iOS device smoke theo geography.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
