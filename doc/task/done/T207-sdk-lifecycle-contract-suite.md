# T207 — End-to-end lifecycle contract suite (NEW)
Priority P1 · Status done.

Tạo contract suite cho `initialize→load→show→background→destroy→reinitialize`, concurrent calls, double destroy và mọi format. Khuyến nghị fake adapter deterministic + integration scenario thật; chỉ unit không bắt được ordering native.

Tests bắt buộc: unit state machine; widget lifecycle/navigation; integration full sequence; Android+iOS smoke lưu log và screenshot.

Loop prompt: audit+score /10, test mọi case, smoke device; >9/10 commit+push.

## Completion (2026-09-12)

Added deterministic lifecycle contract tests for load/show reuse, concurrent/idempotent destroy, destroy during showing, fresh adapter replacement, widget unmount and Android device smoke. Full suite: 1,905 tests pass; analyzer has no errors (one pre-existing info). Audit score: 9.3/10. iOS device unavailable.
