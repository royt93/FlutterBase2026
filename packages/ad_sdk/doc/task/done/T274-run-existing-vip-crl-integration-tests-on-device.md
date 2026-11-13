# T274 — Chạy các integration test VIP/CRL hiện có trên thiết bị thật (không sửa mã)

- **Loại:** Verification
- **Priority:** P2 · **Severity:** LOW
- **Status:** done (2026-11-13; 5/5 file pass 2 lần với `pm clear` trước mỗi lượt; giới hạn ghi bên dưới)
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

## Cập nhật (2026-11-12)
`round39` chạy 20 lượt liên tiếp: 19 pass, 1 fail; nguyên nhân là test phụ thuộc cài sạch (không có trial thì App Open che màn hình), có đối chứng; chi tiết ở T279. Bốn file còn lại mỗi file mới chạy 1 lần.

## Chạy lại với quy trình `pm clear` (2026-11-13, TECNO KJ7, gói tạm `.t274b`)
- Mỗi file chạy 2 lần liên tiếp, `pm clear` trước từng lượt (đúng `example/integration_test/README.md`): `vip_revocation_list_test`, `vip_api_playground_test`, `round39_vip_crl_demo_button_test`, `r23_crl_selfsigned_cache_test`, `t220_owner_decisions_device_test` -> **10/10 pass**, không lượt nào bắt đầu trên dữ liệu VIP còn sót.
- **Giới hạn:** mỗi file chỉ 2 lượt nên không chứng minh ổn định (round39 flaky ~1/20 khi KHÔNG dọn, xem T279); chưa chạy trên CI; một máy, một phiên. Không kiểm trường hợp "quên pm clear".
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t274/with_pm_clear/`.
