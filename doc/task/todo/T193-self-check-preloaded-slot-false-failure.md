# T193 — Self-check false fail khi slot đã preload (FIX)
Priority P1 · Status todo · Source `lib/src/core/ad_manager.dart:1130-1150`.

`_selfCheckLoad` chờ event mới sau `load()`. Slot ready/preloaded có thể short-circuit, không phát event và bị fail sau timeout. Khuyến nghị readiness-first, sau đó event fallback có generation/slot correlation. Option B force reload tốn quota; C tăng timeout không sửa gốc.

Scrum: xác định readiness API; sửa helper; cập nhật diagnostics. DoD: analyzer/test sạch, không request thừa.

Test bắt buộc: unit ready/loading-success/failure/stale/timeout cho mọi fullscreen format; widget health panel; integration initialize→preload→self-check; smoke Android+iOS.

Loop prompt: Implement T193; end loop hãy audit lại code changes và chấm điểm /10, bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh. Nếu work và điểm >9/10 thì commit và push code; nếu không thì sửa và loop.
