# P28 — Idea: tự chạy test khi đổi SSID WiFi

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/network_info_service.dart`

## Ý tưởng
Tự động phát hiện đổi SSID (qua `NetworkInfoService`) để gợi ý chạy test — hữu ích so sánh nhà/công ty/quán cà phê tự động, không cần user tự nhớ mở app mỗi nơi.

## Việc cần làm (đề xuất, chưa code — cần thiết kế trước, liên quan tới permission background giống P18)
- Đánh giá khả thi lắng nghe SSID change ở background (giới hạn platform tương tự P18).
- Bản nhỏ hơn, khả thi ngay: khi mở app, nếu phát hiện SSID khác lần test gần nhất, hiện gợi ý (không tự chạy) "SSID đã đổi, chạy test mới?".

## Acceptance criteria
- [ ] (Bản nhỏ) Mở app với SSID mới → có gợi ý test, không tự động chạy nếu chưa xác nhận với user.
- [ ] Không tốn pin/data bất thường do polling SSID quá thường xuyên.
