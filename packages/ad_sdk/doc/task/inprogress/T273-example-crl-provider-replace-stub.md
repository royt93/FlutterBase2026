# T273 — Example: thay stub `_DemoCrlProvider` bằng provider mẫu gọi URL cấu hình được

- **Loại:** Example / Documentation
- **Priority:** P2 · **Severity:** LOW
- **Status:** done-pending-review (2026-11-13; đủ tiêu chí, các giới hạn ghi bên dưới)
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

## Chạy tay trên thiết bị (2026-11-13, TECNO KJ7, gói tạm `.t273run`) — tiêu chí cuối
- `DemoCrlProvider` được build với `--dart-define=VIP_CRL_URL=http://<ip-mac>:8768/crl.txt`; HTTP thường chỉ bật trong BẢN SAO /tmp (`allowInsecureHttp: true`, `usesCleartextTraffic` trong manifest bản sao); repo không đổi.
- Bấm "Refresh revocation list (CRL)": server tạm ghi nhận một `GET /crl.txt` từ địa chỉ điện thoại và SDK log `refreshRevocationList: applied 1 revoked kid(s)`. Key bị liệt kê (DA) -> `kid DA is revoked`; key khác (DB) -> redeem được. Không crash/ANR; khóa tạm, server, gói tạm đã xóa.
- **Giới hạn:** (1) lượt này dùng HTTP thường; đường HTTPS mặc định chỉ được phủ bởi unit test loopback, chưa chạy với CA thật; (2) `DemoCrlProvider` không log gì khi fetch thành công nên bằng chứng là log server + log SDK; (3) một máy, một lần, mạng LAN.
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t273/`.
- Tiêu chí còn lại: `round39` có thể flaky nếu không `pm clear` (xem T279, đã đóng); không phải lỗi của T273.
