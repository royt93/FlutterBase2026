# T199 — Incident timeline dùng monotonic clock (ENHANCE)
Priority P3 · Status todo · Source `lib/src/monetization/incident_recorder.dart:99-107`.

DateTime.now rollback bởi NTP/timezone có thể tạo delta âm. Khuyến nghị inject clock, lưu monotonic elapsed + wall-clock display và đánh dấu clock jump; clamp-only che giấu nguyên nhân.

Tests: unit rollback/forward/injected clock; widget timeline; integration restart; device smoke đổi timezone/NTP.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
