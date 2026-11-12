# T276 — Smoke test bản RELEASE của example trên thiết bị (guard test-ID, R8, first-install)

- **Loại:** Verification
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done-pending-review (chạy máy xong; các giới hạn ghi rõ bên dưới)
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

## Kết quả (2026-11-12, TECNO KJ7 Android 14, gói tạm `.t276test`, ký bằng debug key)
- `flutter build apk --release` (61,1 MB) thành công; app khởi động, vào màn chính, không crash/ANR.
- **Guard test-ID hoạt động ở release:** SDK log cảnh báo "AdMob provider is active in RELEASE with Google TEST ad unit IDs"; trong cả phiên (~35k dòng logcat) có 0 dòng request/load quảng cáo từ tiến trình app; màn Interstitial báo "skipped/blocked"; màn Banner không có banner. Kiểm cả khi có trial lẫn sau khi gỡ trial.
- **Trial first-install ở release ~24 giờ** (VIP screen: hết hạn 13/11 21:24 khi mở lúc 12/11 21:24); debug chỉ 30 giây.
- **Không chứng minh được:** quảng cáo thật hiển thị ở release (không dùng ad unit production, theo thiết kế); luồng ký/Play App Signing; R8 chỉ ở mức "app chạy" (chưa xem mapping/keep-rule). "Không có request" là kiểm bằng grep log, chưa bắt lưu lượng mạng.
- Build đầu in 24 dòng `e:` Kotlin metadata (play-services-ads 2.3.0 vs 2.1.0 mong đợi); build debug và build release thứ hai (bản sao mới) in 0 dòng, **không tái tạo được, chưa rõ nguyên nhân**.
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t276/` (README.txt có giới hạn).
