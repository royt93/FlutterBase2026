# T232 — Tính năng độc quyền: Trọng tài eCPM thời gian thực không gửi request ngầm

- **Loại:** Flagship (Độc quyền)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** 🔲 todo

## Vấn đề (Why)
Chính sách của AdMob và AppLovin cấm gửi request quảng cáo ngầm (shadow request) khi không có ý định hiển thị. Làm sao để chọn nhà mạng có doanh thu cao nhất cho phiên kế tiếp mà không vi phạm chính sách?

## Đề xuất giải pháp & Acceptance Criteria
1. `ZeroDropYieldArbitrator` kết hợp `FillRateBaselineMonitor` và `CohortOptimizer`:
   - Sử dụng thống kê eCPM lịch sử on-device theo khung giờ và quốc gia.
   - Áp dụng thuật toán Multi-Armed Bandit (Thompson Sampling / Epsilon-Greedy) thuần offline.
   - Điều phối phân bổ hiển thị phiên mà không thực hiện request song song lậu.
2. Hoàn toàn tuân thủ chính sách, tối ưu hóa doanh thu ròng tăng 15-25%.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: Thuật toán Bandit phân bổ cohort chính xác không bias.
- Widget test: Dashboard hiển thị tỉ lệ phân bổ trên RevenuePanel.
- Integration test: `example/integration_test/monetization_arbitrator_demo_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T232 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T232-flagship-zero-drop-shadow-yield-arbitrator.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
