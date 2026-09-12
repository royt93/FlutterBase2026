# T212 — Memory/backpressure stress harness (NEW)
Priority P2 · Status todo.

Xây harness stress hàng nghìn events, route transitions, widget mount/unmount và destroy/re-init; đo stream backlog, timer/controller và heap. Khuyến nghị deterministic fake clock + leak assertions trước device profile.

Tests: unit bounded buffers; widget mount storm; integration 10k-event scenario; Android+iOS profile smoke với memory budget.

Loop prompt: audit+score /10, test mọi case, device smoke chứng minh; >9/10 commit+push.
