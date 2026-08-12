# P44 — `LatencyService` không có endpoint dự phòng khi Cloudflare bị chặn

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/latency_service.dart`

## Ý tưởng
Latency/DNS lookup hiện chỉ dùng 1 host cố định (Cloudflare). Nếu ISP/mạng chặn riêng Cloudflare (không hiếm ở 1 số mạng doanh nghiệp/trường học), toàn bộ đo latency/jitter trả `null` liên tục, làm sai lệch kết luận "mạng chậm" thành false do bị chặn 1 endpoint cụ thể.

## Việc cần làm (đề xuất, chưa code)
- Thêm 1-2 endpoint dự phòng (VD Google DNS `8.8.8.8`, hoặc CDN khác đã dùng cho tốc độ download), thử endpoint chính trước, fallback nếu timeout/lỗi liên tục.

## Acceptance criteria
- [ ] Mock endpoint chính luôn fail → verify service tự chuyển sang fallback, vẫn trả kết quả latency hợp lệ.
