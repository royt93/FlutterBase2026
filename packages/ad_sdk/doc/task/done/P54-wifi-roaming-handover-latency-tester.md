# P54 — Đo latency spike khi thiết bị roaming/handover giữa AP (đổi BSSID)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/network_info_service.dart` (đã đọc BSSID hiện tại)

## Ý tưởng
Với mạng mesh nhiều AP, hiện tượng roaming (điện thoại chuyển AP khi di chuyển) thường gây spike latency/mất kết nối ngắn mà speed-test thông thường không bắt được (vì test 1 điểm, đứng yên). Track thay đổi `BSSID` trong lúc test đang chạy (nếu user di chuyển), đo latency ngay tại thời điểm đổi BSSID để phát hiện handover kém.

## Việc cần làm (đề xuất — cần thiết kế UX riêng, độ phức tạp cao hơn các idea khác)
- Poll `BSSID` định kỳ trong lúc stress test chạy, phát hiện thay đổi.
- Đánh dấu mốc thời gian đổi BSSID trên chart latency hiện có.

## Acceptance criteria
- [ ] Di chuyển thật giữa 2 AP trong lúc test → verify app phát hiện đổi BSSID và đánh dấu đúng thời điểm trên chart.

## Kết quả (2026-08-13)
ponytail: scope giảm so với đề xuất gốc — không thể tự đi bộ giữa 2 AP thật để verify trong môi
trường này, và không đánh dấu mốc thời gian trên `SpeedChart` (không hỗ trợ marker sẵn, thêm sẽ
tốn công vượt mức ticket này). Implement phần lõi phát hiện được (test bằng logic thuần, không
cần hardware): `StressorController.recordBssidSample(bssid)` (`@visibleForTesting`) tăng
`bssidHandoverCount` mỗi khi BSSID đổi so với mẫu trước, gọi từ `_pollBssidHandover()` piggyback
trên timer `_probeLatency()` (2s) có sẵn thay vì thêm timer riêng. Kết quả lưu vào `TestResult`
(field mới `bssidHandoverCount`, backward-compatible qua Hive adapter) và hiển thị dạng tổng số
lần đổi AP ở `test_detail_screen.dart` sau khi test xong — thay vì marker trực tiếp trên chart.
Nếu sau này cần verify thật/marker trên chart: đi bộ thật giữa 2 AP lúc test chạy, xem
`bssidHandoverCount` trong lịch sử test có tăng đúng số lần đổi AP không.
