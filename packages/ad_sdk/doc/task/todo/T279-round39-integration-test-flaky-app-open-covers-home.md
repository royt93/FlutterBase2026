# T279 — `round39_vip_crl_demo_button_test` flaky: App Open che màn hình nên không tìm thấy tile

- **Loại:** Test reliability
- **Priority:** P2 · **Severity:** LOW (chỉ test, không phải SDK)
- **Status:** todo
- **Nguồn:** T274, 2026-11-12, TECNO KJ7.

## Bằng chứng
Cùng một test, bản HEAD sạch (không có thay đổi T273): 4 pass / 1 fail trong 5 lần. Lỗi: `HomePage must list the VIP API playground tile` (round39_vip_crl_demo_button_test.dart dòng ~54). Log của lần fail có `showAppOpen [AdMob] shown` ngay trước đó: quảng cáo App Open ở splash che màn hình, vòng chờ 40 x 500 ms không thấy tile. Các file integration khác không gặp lỗi này trong lượt chạy (mỗi file chạy 1 lần).

## Việc cần làm
- Xác minh nguyên nhân: test không chờ/đóng App Open ở splash (trong khi `FirstInstallVipGrace` ở debug chỉ 30 giây nên VIP chặn App Open lúc đầu, rồi hết hạn).
- Sửa test (không sửa SDK): chờ App Open kết thúc hoặc tắt App Open/VIP grace trong test; không nới thời gian chờ mù quáng.
- Chạy lại >= 10 lần liên tiếp trên thiết bị, ghi pass/fail.

## Lưu ý
Không kết luận "test ổn" từ vài lần pass. Không đổi hành vi SDK để test xanh.
