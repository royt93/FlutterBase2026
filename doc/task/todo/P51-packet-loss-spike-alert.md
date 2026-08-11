# P51 — Cảnh báo packet loss/latency-spike ngay trong lúc test (không chỉ xem sau)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source (idea)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/` (dùng lại các pure function đo latency/packet-loss đã có)

## Ý tưởng
App đã có pure function tính packet loss/latency, nhưng chỉ hiển thị sau khi test xong (`test_detail_screen.dart`). Thêm cảnh báo real-time trong lúc test đang chạy (VD: banner nhỏ "phát hiện packet loss cao") giúp user biết ngay có vấn đề mà không cần đợi xong test.

## Việc cần làm (đề xuất, chưa code)
- Xác định ngưỡng cảnh báo hợp lý (cần dữ liệu thực tế, không đoán số).
- Thêm reactive state (`.obs`) trong `StressorController` cho cảnh báo, hiển thị banner trong `wifi_stressor_screen.dart` khi vượt ngưỡng.

## Acceptance criteria
- [ ] Mock packet loss cao trong lúc test → banner cảnh báo hiện đúng lúc, không cần đợi test xong.
