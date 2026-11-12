# T273 — Example: thay stub `_DemoCrlProvider` bằng provider mẫu gọi URL cấu hình được

- **Loại:** Example / Documentation
- **Priority:** P2 · **Severity:** LOW
- **Status:** inprogress (code + unit test + 19/20 lượt round39 pass; còn 1 tiêu chí chưa làm: chạy tay DemoCrlProvider với VIP_CRL_URL thật trên máy)
- **Nguồn:** audit round 79 (bằng chứng: `doc/audit/evidence/round79_tecno_manual/screens9..13`, `NOTES.txt`)

## Vấn đề
`example/lib/main.dart` có `_DemoCrlProvider.fetchSignedCrl()` trả `null`; chính comment trong file cảnh báo partner chép nguyên example có thể ship tính năng thu hồi VIP "không hoạt động mà không biết". README và `doc/AD_PROMPT_FLUTTER.MD` đã có mẫu `MyCrlProvider`/`PartnerCrlProvider`, nhưng example (thứ partner chạy thử) thì không.

## Việc cần làm
1. Thay stub bằng provider mẫu: `HttpClient` với timeout, chỉ chấp nhận HTTPS (cho phép HTTP khi cờ debug), URL lấy từ `--dart-define=VIP_CRL_URL=...`.
2. Khi `VIP_CRL_URL` rỗng: giữ hành vi cũ (trả `null`, log rõ "no CRL URL configured") — không đổi mặc định của example.
3. Không đổi API công khai của SDK, không sửa `lib/`.
4. Cập nhật comment trong `main.dart` cho khớp.

## Tiêu chí hoàn thành
- `flutter analyze` sạch (SDK + example).
- `round39_vip_crl_demo_button_test.dart` vẫn pass trên thiết bị khi không có `VIP_CRL_URL`.
- Một lượt chạy tay với URL trỏ tới server tạm cho thấy `applied N revoked kid(s)` (ghi rõ là thử nghiệm, không phải bằng chứng production).
- Không thêm dependency.

## Test
- Test widget/unit cho nhánh: URL rỗng, URL HTTP khi không bật debug (từ chối), phản hồi 200, lỗi mạng (ném, SDK fail-open).

## Kết quả (2026-11-12)
- Thêm `example/lib/demo_crl_provider.dart` (`DemoCrlProvider`, `kDemoCrlUrl` từ `--dart-define=VIP_CRL_URL`); `main.dart` dùng nó, bỏ stub riêng; snackbar nói đúng hai trường hợp (có/không URL). Không sửa `lib/` của SDK, không đổi API công khai.
- 6 unit test mới (`example/test/demo_crl_provider_test.dart`, server loopback thật): URL rỗng, HTTP bị từ chối mặc định, scheme lạ/URL rác, HTTP khi bật cờ + trim body, non-200, lỗi kết nối ném. Mutation check: cho provider nuốt lỗi thì test "connection failure throws" đỏ.
- `flutter analyze` sạch (SDK + example); `flutter test` của example 80/80.
- Thiết bị (TECNO KJ7, gói tạm `.t274test`): `round39_vip_crl_demo_button_test` đã sửa assertion cho khớp snackbar mới (lần đầu fail do chính tôi đổi chữ). Sau sửa: 3/3 pass. **Phát hiện flaky có sẵn từ trước T273:** bản HEAD sạch cũng fail 1/5 lần (App Open che màn hình nên không tìm thấy tile). Chi tiết: `doc/audit/evidence/round79_tecno_manual/t274/README.txt`.
- Chưa làm: chạy với `VIP_CRL_URL` thật trên thiết bị (chỉ có unit test loopback); thêm vào guide nếu cần.

## Còn thiếu so với tiêu chí (2026-11-12)
- "Một lượt chạy tay với URL trỏ tới server tạm cho thấy `applied N revoked kid(s)`" **chưa làm qua `DemoCrlProvider`**: các lượt CRL qua mạng trước đó (lượt 13/14) dùng provider thử nghiệm của tôi, không phải `DemoCrlProvider`. `DemoCrlProvider` mới có 6 unit test loopback (HTTP bị từ chối mặc định, 200, non-200, lỗi kết nối).
- `round39` đã chạy 20 lượt liên tiếp trên TECNO: 19 pass, 1 fail; lỗi do trạng thái dữ liệu còn sót của test, không phải do T273 (xem T279; bản HEAD sạch cũng fail tương tự).
