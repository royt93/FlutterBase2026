# T198 — JourneyPrefetcher route lifecycle đầy đủ (ENHANCE)
Priority P2 · Status todo · Source `lib/src/monetization/journey_prefetcher.dart:219-235`.

Observer chỉ `didPush`; pop/replace bỏ lỡ journey và có thể giữ prefetch stale. Khuyến nghị typed events didPush/didReplace/didPop + dedupe policy, giữ API cũ. Chỉ thêm didPop rẻ hơn nhưng replace vẫn thiếu.

Tests: unit callbacks/dedupe/dispose; widget Navigator push/pop/replace; integration route stack; device smoke không request trùng.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.
