# T215 — Automated Flutter/platform/provider compatibility matrix (NEW)
Priority P2 · Status todo.

Tự động kiểm tra Flutter/Dart, Android API, iOS version và AdMob/AppLovin SDK combinations; phát hiện breaking behavior trước release. Khuyến nghị matrix tối thiểu + nightly extended để kiểm soát chi phí.

Tests: unit matrix generator; widget golden per platform; integration adapter scenarios; physical/emulator smoke trên supported floor/latest.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.
