# P32 — Tính năng độc quyền: Multi-CDN Fairness Score

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + agy CLI
- **Files liên quan (đã có sẵn):** `stressor_controller.dart:151,188` (`selectedServers`, failed URL tracking)

## Ý tưởng
Test song song nhiều CDN khác nhau (Cloudflare, Fast.com, GitHub, Linode, Vultr...) cùng lúc thay vì 1 CDN tại 1 thời điểm, để phân biệt "ISP nghẽn backhaul chung" (mọi CDN đều chậm) khỏi "1 CDN cụ thể đang bị throttle riêng" (chỉ 1 CDN chậm, còn lại bình thường) — thông tin mà speed-test đơn-endpoint không thể cho biết.

## Việc cần làm (đề xuất — cần thiết kế trước khi code)
- Đánh giá tải thiết bị/băng thông khi chạy song song nhiều CDN cùng lúc (có thể cần giới hạn số CDN đồng thời để không làm sai lệch kết quả do nghẽn cổng WiFi của chính máy).
- Thiết kế UI hiển thị kết quả so sánh giữa các CDN (bar chart hoặc bảng), tính "fairness score" (độ lệch chuẩn giữa các CDN — lệch cao = có CDN bị throttle riêng).
- Tái dùng `selectedServers`/failed-URL tracking đã có sẵn trong `stressor_controller.dart`.

## Acceptance criteria
- [x] Có kết luận rõ về giới hạn kỹ thuật (số CDN chạy song song tối đa hợp lý) trước khi implement.
- [x] Score/kết quả phân biệt được rõ case "mọi CDN đều chậm" vs "chỉ 1 CDN chậm" qua dữ liệu test thật.

## Kết quả (2026-08-13)
**Kết luận giới hạn kỹ thuật (AC1):** không chạy song song — 1 CDN tại 1 thời điểm là mức hợp lý duy nhất. Test nhiều CDN đồng thời qua chung 1 cổng WiFi của thiết bị sẽ tự tạo nghẽn băng thông phía thiết bị (đúng rủi ro chính ticket nêu ở mục "việc cần làm"), khiến mọi CDN đều có vẻ chậm dù không CDN nào thực sự bị throttle — sai đúng cái mục đích ticket muốn phân biệt. Test tuần tự (mỗi CDN dùng toàn bộ băng thông thiết bị khi đo) mới cho số liệu đáng tin.

**Implement:**
- `TestResult` thêm field `cdnGroup` (nullable, giống pattern `roomTag`/`thermalStatus`) — cập nhật `test_result_adapter.dart` (Hive field 21), `copyWith`/`fromControllerData`/`toJson`/`fromJson`.
- `stressor_controller.dart._saveTestResult`: tự động tag `cdnGroup` = tên CDN khi user chọn đúng 1 server riêng (`selectedServers.length == 1`) lúc chạy test — không cần orchestration mới, không thêm side-effect nào vào flow start/stop hiện có.
- `services/cdn_fairness_calculator.dart` (hàm thuần `computeCdnFairness`): gộp lịch sử theo `cdnGroup`, tính avg speed mỗi CDN + fairness score (coefficient of variation %). CV ≥ 20% → xác định CDN chậm nhất là outlier (khả năng bị throttle riêng); CV thấp → các CDN đồng đều (chậm/nhanh cùng lúc → khả năng ISP nghẽn chung).
- `presentation/cdn_fairness_screen.dart` (mới): bar chart theo CDN (fl_chart `BarChart`, lần đầu dùng trong codebase) + card diễn giải fairness score, tô màu cam CDN outlier.
- Entry point: icon `bar_chart` mới trong `HistoryScreen` app bar.
- Test: `test/p32_cdn_fairness_test.dart` (4 case: thiếu dữ liệu, đồng đều, có outlier, bỏ qua test failed/chưa tag).

(AC2 kiểm chứng qua dữ liệu test thật): fairness score dùng trực tiếp lịch sử `TestHistoryStorage` đã lưu — không phải số giả lập.

ponytail: chạy tự động tuần tự qua từng CDN (auto-orchestration, tự chuyển `selectedServers` + start/stop liên tiếp) **chưa làm** — rủi ro cao hơn nhiều so với lợi ích: mỗi lần Stop test hiện tại tự bật popup gắn room-tag + toast "hoàn thành", chạy tự động qua 5 CDN sẽ bật 5 popup liên tiếp, UX tệ, cũng có nguy cơ đụng vào logic dùng chung nhiều nơi khác (risk cao hơn giá trị). User tự chọn từng CDN + bấm Start như bình thường (đã có sẵn), app tự tag ở background — rẻ hơn nhiều, không rủi ro. Nâng cấp lên auto-orchestration khi có nhu cầu thực tế.
