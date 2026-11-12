# T279 — `round39_vip_crl_demo_button_test` flaky: App Open che màn hình nên không tìm thấy tile

- **Loại:** Test reliability
- **Priority:** P2 · **Severity:** LOW (chỉ test, không phải SDK)
- **Status:** todo (nguyên nhân đã xác lập bằng thí nghiệm đối chứng; chờ chủ sản phẩm duyệt cách sửa)
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

## Cập nhật (2026-11-12, đo 20 lượt + thí nghiệm đối chứng) — thay thế phần "chưa xác lập" ở trên
- **20 lượt liên tiếp trên TECNO:** 19 pass, 1 fail (run 2). Tần suất ~5% trên máy này (mẫu nhỏ).
- **Cơ chế (quan sát được, có đối chứng):** test giả định app vừa cài mới nên được cấp trial first-install (30 giây ở debug) giữ App Open bị chặn ở splash. Khi dữ liệu app của lượt trước còn sót, **không** cấp trial (`purgeExpired: removed 1`, không có `first-install VIP grace granted`), App Open hiện và che danh sách, nên không thấy tile.
- **Vì sao dữ liệu có thể còn sót:** `flutter test` gỡ `com.example.ad_sdk_example` (namespace Gradle) chứ không phải applicationId đang cài (`com.roy.admobwrapper`), nên bước dọn cuối mỗi lượt không xóa dữ liệu app thật. Trong chuỗi 20 lượt, 18/19 chuyển tiếp có một bước gỡ gói thật ở giữa (harness tạm), riêng lượt 1->2 thì không (lượt 1 kết thúc bằng gỡ thất bại).
- **Đối chứng:** `c1` pass rồi `c2` ngay (không dọn) -> `c2` FAIL đúng dấu hiệu trên; `d1` pass, `pm clear`, `d2` -> PASS. Tái tạo trạng thái lỗi theo yêu cầu 1 lần và ngăn được 1 lần (mẫu 2 + 2).
- **Kết luận:** lỗi nằm ở **giả định của test/quy trình chạy** (cần cài sạch), không phải lỗi SDK; SDK cư xử đúng thiết kế (không cấp trial khi không phải lần cài đầu).
- **Hướng sửa đề xuất (CHƯA làm, cần chủ sản phẩm duyệt vì sửa integration test):** (a) quy trình: `pm clear` gói trước mỗi lượt; hoặc (b) test: không phụ thuộc trial, ví dụ chờ `AdManager().fullscreenBusy` về `false` rồi mới tìm tile, hoặc `revokeAll()` + chờ App Open xong; sau khi sửa phải chạy >= 20 lượt liên tiếp có xen kẽ lượt không dọn.
- **Giới hạn:** một máy; không kiểm chứng vì sao đúng một chuyển tiếp trong chuỗi 20 lượt không có bước gỡ gói thật; cơ chế "dọn cuối không đáng tin" là quan sát, chưa thử toàn diện.
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t279/` (`series20/`, `controlled/`, README.txt).
