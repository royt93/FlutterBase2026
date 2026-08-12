# P25 — Idea: Bufferbloat score

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận mạnh 3 nguồn]** codex CLI + agy CLI + claude CLI
- **Files:** `lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart` (đã có latency probe lúc idle + lúc tải)

## Ý tưởng
So sánh latency lúc idle (trước khi bắt đầu download) với latency lúc đang tải nặng (during stress test) — đo được ngay trong 1 lần chạy stress test hiện có, không cần thêm hạ tầng đo mới. Chênh lệch lớn = bufferbloat cao (ảnh hưởng gaming/video call khi ai đó trong nhà đang tải nặng).

## Việc cần làm (đề xuất, chưa code — cần thiết kế UI/thang điểm trước khi code)
- Đo latency baseline trước khi bắt đầu download loop.
- Đo latency liên tục trong lúc download đang chạy (có thể tái dùng probe hiện có nếu đã tồn tại).
- Định nghĩa thang điểm (A+ đến F, theo chuẩn phổ biến như DSLReports bufferbloat test) dựa trên độ tăng latency.
- Hiển thị điểm này trong `test_detail_screen.dart` hoặc màn kết quả chính.

## Acceptance criteria
- [ ] Thang điểm bufferbloat được định nghĩa rõ (ngưỡng ms cho từng grade), có tài liệu tham khảo.
- [ ] Điểm số hiển thị đúng, phản ánh đúng chênh lệch latency idle vs under-load thực tế.
