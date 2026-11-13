# T279 — `round39_vip_crl_demo_button_test` flaky: App Open che màn hình nên không tìm thấy tile

- **Loại:** Test reliability
- **Priority:** P2 · **Severity:** LOW (chỉ test, không phải SDK)
- **Status:** done-partial (2026-11-13; đã rõ cơ chế và đã ghi quy trình `pm clear`; KHÔNG sửa test vì bản sửa thử chưa chứng minh hiệu quả)
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

## Kiểm chứng bản sửa (2026-11-13, TECNO KJ7) — KẾT QUẢ: CHƯA chứng minh được
- Sửa thử (chưa commit): `round39` chờ `AdManager().fullscreenBusy` về `false` (tối đa 60 s) trước khi tìm tile. Qua analyzer; **chưa có bằng chứng thiết bị rằng nó hoạt động.**
- Thí nghiệm 24 lượt (mỗi bản 6 cặp: lượt `a` cài mới, lượt `b` chạy ngay không dọn). Lượt `a` cả hai bản 12/12 pass (đều có trial). Lượt `b`: bản cũ 5 pass / 1 fail; bản mới 6 pass / 0 fail.
- **Chỉ cặp 1 của mỗi bản thật sự rơi vào trạng thái lỗi** (dữ liệu cũ, không có trial). Cặp 1 bản cũ FAIL (App Open hiện). Cặp 1 bản mới PASS nhưng **App Open không hiện** trong lượt đó (splash hết 8 s trước khi App Open kịp hiện), nên vòng chờ `fullscreenBusy` chưa hề phải chờ. Ở cặp 2-6 gói bị gỡ giữa `a` và `b` nên `b` lại là cài mới, không kiểm bản sửa.
- **Kết luận:** mẫu không phân biệt được "bản sửa hiệu quả" với "may mắn". Muốn kiểm thật phải ép trạng thái lỗi (ví dụ chạy `b` trên dữ liệu còn sót nhiều lần mà không gỡ gói), một thí nghiệm khác.
- **Đề xuất:** KHÔNG commit bản sửa như đã kiểm chứng. Chọn một: (1) viết thí nghiệm ép trạng thái lỗi rồi mới quyết định; (2) chỉ giữ README `pm clear` (đã commit `e7e3b56`) và đóng T279 ở mức "đã rõ cơ chế, đã ghi quy trình, chưa sửa test".
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t279/fixcheck/` (README.txt có số liệu và giới hạn).

## Quyết định đóng (2026-11-13)
Chủ sản phẩm chọn **đóng T279, bỏ bản sửa chưa kiểm chứng**. Đã làm: nguyên nhân xác lập có đối chứng (test cần cài sạch; xem mục cập nhật 2026-11-12), quy trình `pm clear` ghi ở `example/integration_test/README.md` (commit `e7e3b56`). **Không làm:** sửa `round39`. Bản sửa thử (chờ `AdManager().fullscreenBusy` về `false` trước khi tìm tile) đã bỏ khỏi working tree; thí nghiệm 24 lượt không chứng minh được hiệu quả vì chỉ 1 lượt rơi vào trạng thái lỗi và lượt đó App Open không hiện (xem `t279/fixcheck/README.txt`). Hệ quả còn lại: nếu ai đó quên `pm clear`, test vẫn có thể flaky (~5% trên một máy). Mở lại nếu cần: thí nghiệm ép trạng thái lỗi (chạy lượt `b` nhiều lần trên dữ liệu còn sót, không gỡ gói) trước khi đổi test.
