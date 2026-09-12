# T201 — InlineAdController imperative lifecycle (NEW)
Priority P2 · Status todo.

Inline host hiện phải tự phối hợp rebuild/manager calls; đề xuất controller gắn một slot để refresh/pause/resume/status, idempotent dispose, không bypass policy. Manager singleton methods là option nhưng dễ tác động placement khác.

Tests: unit command serialization; widget attach/detach/rebuild; integration scroll/background/consent; Android+iOS device smoke banner/MREC/native.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
