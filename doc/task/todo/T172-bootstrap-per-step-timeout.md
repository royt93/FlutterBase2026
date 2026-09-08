# T172 — Khởi động SDK không có giới hạn thời gian riêng cho từng việc

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Lúc mở app lần đầu, SDK khởi động nhiều việc cùng lúc (tải cấu hình an toàn từ server, hỏi quyền quảng cáo...) nhưng chưa có giới hạn thời gian riêng cho từng việc — nếu 1 việc bị mạng chậm, có thể làm chậm toàn bộ quá trình khởi động, người dùng chờ lâu hơn ở màn hình chờ đầu tiên (splash).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_bootstrap.dart:180-210` — `AdBootstrap.init` khởi động song song các dịch vụ nhưng chưa có timeout từng chặng (per-step granular timeout) cho network-dependent steps (Remote Safety Config, CMP Consent load).

## Việc cần làm
1. Thêm timeout riêng cho từng bước network-dependent trong `AdBootstrap.init` (VD dùng `.timeout(Duration(...))` cho từng Future con), giá trị mặc định hợp lý (không quá ngắn gây fail giả, không quá dài mất tác dụng).
2. Khi 1 bước timeout: tiếp tục khởi động các bước khác bình thường (không để 1 bước chậm chặn toàn bộ splash), log rõ bước nào bị timeout.
3. Viết test: mock 1 bước (VD remote safety config) chậm/không bao giờ resolve, xác nhận toàn bộ `init()` vẫn hoàn tất trong thời gian hợp lý, các bước khác không bị ảnh hưởng.
4. Cập nhật CHANGELOG.md và README.md (mục splash/init contract) nếu có thay đổi hành vi cần biết.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_bootstrap.dart dòng ~180-210: AdBootstrap.init khởi động song song nhiều dịch vụ network-dependent (Remote Safety Config, CMP Consent load) nhưng không có timeout riêng cho từng bước — nếu 1 bước mạng chậm, có thể kéo dài toàn bộ splash. Thêm .timeout(Duration(...)) cho từng Future con network-dependent, chọn giá trị mặc định hợp lý dựa trên timeout hiện có ở nơi khác trong SDK (đối chiếu timeout patterns đã dùng, VD watchdog timeout của native ad). Khi 1 bước timeout, log qua SafeLogger và tiếp tục các bước khác bình thường, không chặn toàn bộ init(). Viết unit test: mock 1 service chậm/không resolve, xác nhận init() vẫn hoàn tất, các service khác không bị ảnh hưởng.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho 1 bước bị timeout, xác nhận không chặn toàn bộ init; integration test đo thời gian init tổng khi có 1 bước chậm.
3. Log SafeLogger đầy đủ + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với mạng cố ý làm chậm (throttle network), xác nhận splash không bị treo quá lâu.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
