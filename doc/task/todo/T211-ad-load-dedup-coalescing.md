# T211 — Coalesce duplicate ad-load requests (ENHANCE)
Priority P2 · Status todo.

Nhiều widget/callback có thể gọi load cùng slot gần như đồng thời. Khuyến nghị per-slot in-flight future và request generation, vẫn tôn trọng placement/policy; debounce toàn cục có thể làm trễ ad hợp lệ.

Tests: unit concurrent success/failure/cancel/stale; widget mount storm; integration lifecycle burst; device smoke đo native request count.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
