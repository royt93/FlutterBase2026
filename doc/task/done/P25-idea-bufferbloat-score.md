# P25 — Idea: Bufferbloat score

- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-08-11)
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
- [x] Thang điểm bufferbloat được định nghĩa rõ (ngưỡng ms cho từng grade), có tài liệu tham khảo.
- [x] Điểm số hiển thị đúng, phản ánh đúng chênh lệch latency idle vs under-load thực tế.

## Kết quả (2026-08-11)
- Hạ tầng đo (idle latency trước download loop + latency dưới tải liên tục) đã có sẵn từ [[P50-idle-baseline-latency-probe]] — ticket này chỉ cần thêm thang điểm + hiển thị.
- `test_result.dart`: thêm getter `bufferbloatGrade` (A+/A/B/C/D/F) dựa trên `bufferbloatMs` (= `avgLatencyMs - idleLatencyMs`), theo thang điểm phổ biến của **Waveform bufferbloat test** (waveform.com/tools/bufferbloat): A+ &lt;5ms, A &lt;30ms, B &lt;60ms, C &lt;200ms, D &lt;400ms, F &gt;=400ms độ tăng latency. Chênh lệch âm (nhiễu đo, hiếm) clamp về 0 → A+ (tốt nhất), không trả grade sai. `null` nếu thiếu 1 trong 2 mốc đo. Thêm `bufferbloatFormattedWithGrade` ("+42 ms (B)" / "N/A").
- `test_detail_screen.dart`: dòng info `bufferbloat` (đã thêm ở P50) đổi sang dùng `bufferbloatFormattedWithGrade` — hiển thị cả chênh lệch và grade trên cùng 1 dòng, không cần thêm UI mới.
- Test: `test/p25_bufferbloat_score_test.dart` (mới) — cover đủ biên mỗi grade (4.9/5.0, 29.9/30.0, 59.9/60.0, 199.9/200.0, 399.9/400.0ms), chênh lệch âm, thiếu mốc đo, và format string. `flutter analyze` sạch, `flutter test` 157/157 pass.
