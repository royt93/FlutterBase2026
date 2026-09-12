# T205 — Không để private VIP key trong argv/stdout (FIX/SECURITY)
Priority P0 · Status todo · Source audit Codex: `tool/vip_keygen.dart:15`, `tool/vip_mint.dart:28`, `tool/vip_crl_mint.dart:25`.

CLI hiện có thể in private material và nhận key qua command-line, lộ shell history/process inspection/CI logs. Khuyến nghị stdin hoặc permission-checked file/secret descriptor; keygen ghi file 0600, stdout chỉ khi có unsafe flag rõ ràng.

Tests: unit parser/redaction/permissions; widget test tool wrapper (không echo); integration subprocess với stdin/file và lỗi; device/CI smoke kiểm tra argv/stdout không chứa key.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke proof; >9/10 mới commit+push, nếu không loop.
