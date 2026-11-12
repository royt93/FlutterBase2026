# T276 — Smoke test bản RELEASE của example trên thiết bị (guard test-ID, R8, first-install)

- **Loại:** Verification
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo
- **Nguồn:** audit round 79. Toàn bộ test tay chạy bản DEBUG; log ghi `FirstInstallGuard: debug build — anti-bypass guard bypassed (test on release builds)` và trial 24h chỉ chạy 30 giây ở debug.

## Mục tiêu
Kiểm các hành vi chỉ có ở release: (1) guard chặn Google test ID (`_applyTestIdFootgunGuard`), (2) R8/minify không làm hỏng quảng cáo/UMP/VIP, (3) trial first-install thật (24h, không 30s), (4) không lộ log nhạy cảm.

## Giới hạn bắt buộc
- Không dùng ad unit production. Với test ID, release PHẢI bị chặn request — đó chính là kết quả cần thấy.
- Ký bằng debug keystore tạm; không dùng khoá thật.

## Tiêu chí hoàn thành
- `flutter build apk --release` thành công; ghi lệnh, dung lượng, cảnh báo R8.
- Log + ảnh: request bị chặn với test ID; app không crash; VIP/UMP màn hình mở được.
- Ghi rõ những gì KHÔNG kiểm được (không có ad unit thật → không chứng minh được quảng cáo thật hiển thị ở release).
