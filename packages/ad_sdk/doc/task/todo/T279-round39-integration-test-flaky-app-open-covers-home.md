# T279 — `round39_vip_crl_demo_button_test` flaky: App Open che màn hình nên không tìm thấy tile

- **Loại:** Test reliability
- **Priority:** P2 · **Severity:** LOW (chỉ test, không phải SDK)
- **Status:** todo (đã điều tra; nguyên nhân gốc chưa xác lập, chưa sửa test)
- **Nguồn:** T274, 2026-11-12, TECNO KJ7.

## Bằng chứng
Cùng một test, bản HEAD sạch (không có thay đổi T273): 4 pass / 1 fail trong 5 lần. Lỗi: `HomePage must list the VIP API playground tile` (round39_vip_crl_demo_button_test.dart dòng ~54). Log của lần fail có `showAppOpen [AdMob] shown` ngay trước đó: quảng cáo App Open ở splash che màn hình, vòng chờ 40 x 500 ms không thấy tile. Các file integration khác không gặp lỗi này trong lượt chạy (mỗi file chạy 1 lần).

## Việc cần làm
- Xác minh nguyên nhân: test không chờ/đóng App Open ở splash (trong khi `FirstInstallVipGrace` ở debug chỉ 30 giây nên VIP chặn App Open lúc đầu, rồi hết hạn).
- Sửa test (không sửa SDK): chờ App Open kết thúc hoặc tắt App Open/VIP grace trong test; không nới thời gian chờ mù quáng.
- Chạy lại >= 10 lần liên tiếp trên thiết bị, ghi pass/fail.

## Lưu ý
Không kết luận "test ổn" từ vài lần pass. Không đổi hành vi SDK để test xanh.

## Điều tra (2026-11-12, TECNO KJ7)
- 6 lần chạy liên tiếp bản sao: 5 pass, 1 fail (run_2). Cộng các lượt T274: tổng ~16 lần, 3 fail, cả 3 đều cùng kiểu (App Open hiện, không thấy tile).
- Lần fail duy nhất có log đầy đủ khác mọi lần pass ở ba điểm: bắt đầu bằng `VipManager purgeExpired: removed 1` (còn dữ liệu VIP cũ), **không** cấp trial first-install (30 giây ở debug), nên VIP không chặn App Open ở splash -> App Open hiện -> không thấy tile trong 40 x 500 ms.
- **Chưa xác lập được vì sao lần đó còn dữ liệu cũ.** `flutter test` gỡ `com.example.ad_sdk_example` (namespace) chứ không phải applicationId đang cài, nên không xóa app giữa các lượt; nhưng 5/6 lượt vẫn bắt đầu sạch. Tôi cố tái tạo bằng cách cố ý để lại dữ liệu VIP đã hết hạn (3 lần): cả 3 đều pass. Nên "dữ liệu cũ" chỉ là tương quan quan sát được từ MỘT lần fail, không phải nguyên nhân đã chứng minh.
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t279/` (README.txt có số liệu và giới hạn).

## Hướng xử lý còn lại (chưa làm)
1. Test nên không phụ thuộc trạng thái trial/VIP: như `vip_api_playground_test`, gọi `AdManager().vip!.revokeAll()` sau khi tile xuất hiện (nhưng tile là thứ không xuất hiện khi App Open che màn hình), hoặc chờ `AdManager().fullscreenBusy` về `false` (ValueNotifier công khai) trước khi tìm tile. Cần thử chạy >= 10 lần liên tiếp sau khi sửa.
2. Chưa kết luận lỗi của SDK: trong lần fail, SDK cư xử đúng như thiết kế (không có VIP thì App Open ở splash hiện).
