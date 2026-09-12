# T217 — Public API stability và deprecation policy (ENHANCE)
Priority P3 · Status todo.

Đánh dấu `@experimental`, deprecation timeline, changelog tự động và API golden test để tránh phá host. Khuyến nghị policy semver + CI API diff; tài liệu thủ công dễ bị bỏ quên.

Tests: unit API manifest; widget compile consumer samples; integration package upgrade fixture; device smoke sample app trên supported platforms.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.
