# T225 — Tối ưu hiệu năng cuộn 120Hz cho InFeedAdListView và recycling cache

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** 🔲 todo

## Vấn đề (Why)
`InFeedAdListView` chèn Native Ad vào danh sách cuộn. Khi người dùng lướt nhanh với tốc độ 120fps, việc khởi tạo widget và layout native ad liên tục có thể gây micro-jank (rớt khung hình) hoặc spam request load ad.

## Đề xuất giải pháp & Acceptance Criteria
1. Bổ sung `scrollVelocityThreshold`: Khi tốc độ cuộn vượt ngưỡng, tạm hoãn nạp ad mới cho đến khi danh sách ổn định (`ScrollEndNotification`).
2. Tái sử dụng slot layout placeholder để tránh nhảy giật layout (layout shift / CLS).
3. Thêm LRU bounded cache cho native ad views đã tải trong viewport gần.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Widget test: Cuộn nhanh giả lập và kiểm tra debounce nạp ad.
- Golden/Performance test: Đo frame rendering time không vượt quá 16ms.
- Integration test: `example/integration_test/t141_in_feed_native_ad_list_view_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T225 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T225-enhance-infeed-native-ad-listview-scroll-performance.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
