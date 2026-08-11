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
