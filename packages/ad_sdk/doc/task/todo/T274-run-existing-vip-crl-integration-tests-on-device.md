# T274 — Chạy các integration test VIP/CRL hiện có trên thiết bị thật (không sửa mã)

- **Loại:** Verification
- **Priority:** P2 · **Severity:** LOW
- **Status:** done-pending-review (4/5 file pass 1 lần; file thứ 5 flaky, xem T279)
- **Nguồn:** audit round 79

## Mục tiêu
Xác nhận 5 file integration đã có còn pass trên máy thật: `vip_revocation_list_test.dart`, `vip_api_playground_test.dart`, `round39_vip_crl_demo_button_test.dart`, `r23_crl_selfsigned_cache_test.dart`, `t220_owner_decisions_device_test.dart`.

## Điều kiện
- Chạy từ `packages/ad_sdk/example` với `--dart-define=AD_PROVIDER_ADMOB=true` (không có thì test chạy với placeholder AppLovin và treo).
- Thiết bị: máy đang cắm theo `adb devices -l` (hiện TECNO KJ7). Cần người dùng đồng ý cài/ghi đè example `com.roy.admobwrapper` (đã có trên máy).
- Ghi log liên tục ra file, không `logcat -c` giữa các test.

## Tiêu chí hoàn thành
- Mỗi file: pass/fail + lệnh + thời gian + model/Android.
- Fail được ghi nguyên văn, không đổi thành pass. Không sửa test để xanh.
- Kết quả lưu ở `doc/audit/evidence/` kèm checksum đường dẫn tương đối.

## Kết quả (2026-11-12, TECNO KJ7 Android 14, gói tạm `.t274test`)
- `vip_revocation_list_test` PASS (1 test), `vip_api_playground_test` PASS (2), `r23_crl_selfsigned_cache_test` PASS (2), `t220_owner_decisions_device_test` PASS (1), `round39_vip_crl_demo_button_test`: xem T279 (flaky có sẵn từ trước).
- Mỗi file chạy 1 lần (riêng round39 chạy nhiều lần). Một lần pass không chứng minh ổn định. Log: `doc/audit/evidence/round79_tecno_manual/t274/`.
