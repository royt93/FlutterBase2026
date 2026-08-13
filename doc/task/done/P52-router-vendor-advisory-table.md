# P52 — Bảng khuyến nghị theo vendor router (dùng OUI lookup đã có)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source (idea)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/network_dashboard_screen.dart` (hiện đã có vendor lookup từ BSSID/OUI)

## Ý tưởng
Dashboard đã hiển thị vendor router (suy ra từ OUI của BSSID). Thêm bảng khuyến nghị đơn giản theo vendor phổ biến (VD: "TP-Link Archer series thường yếu 5GHz ở band edge, cân nhắc kênh X") — dùng bảng tra tĩnh (rule-based), không cần dịch vụ ngoài.

## Việc cần làm (đề xuất, chưa code)
- Soạn bảng tra vendor → khuyến nghị (nội dung cụ thể cần research riêng, không phải việc code).
- Hiển thị khuyến nghị khớp vendor trong dashboard nếu có trong bảng, ẩn nếu không khớp.

## Acceptance criteria
- [ ] Vendor có trong bảng tra → hiển thị đúng khuyến nghị tương ứng.
- [ ] Vendor không có trong bảng → không hiển thị gì (không đoán bừa).
