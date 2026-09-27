# T225 — Tối ưu hiệu năng cuộn 120Hz cho InFeedAdListView và recycling cache

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done — SCOPE REDUCED (real load-on-scroll gap fixed; LRU rejected as redundant)

## Vấn đề (Why)
`InFeedAdListView` chèn Native Ad vào danh sách cuộn. Khi người dùng lướt nhanh với tốc độ 120fps, việc khởi tạo widget và layout native ad liên tục có thể gây micro-jank (rớt khung hình) hoặc spam request load ad.

## Đề xuất giải pháp & Acceptance Criteria
1. Bổ sung `scrollVelocityThreshold`: Khi tốc độ cuộn vượt ngưỡng, tạm hoãn nạp ad mới cho đến khi danh sách ổn định (`ScrollEndNotification`).
2. Tái sử dụng slot layout placeholder để tránh nhảy giật layout (layout shift / CLS).
3. Thêm LRU bounded cache cho native ad views đã tải trong viewport gần.

### Acceptance Criteria
- [x] Code thay đổi tối giản: dùng `ScrollStartNotification`/`ScrollEndNotification` + `ValueNotifier`; không thêm dependency/config/velocity subsystem/LRU ad-view cache.
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Unit/index math giữ nguyên; widget 12/12 pass (fast-scroll→settle, normal, zero ads, dense ads, dispose, rebuild, nested scroll, provider-flexible placeholder); integration T141 1/1 pass trên Samsung Galaxy S24 Ultra SM-S928B.
- [x] `flutter analyze` sạch 0 cảnh báo; full `flutter test` 2318/2318 pass.

## Kế hoạch kiểm thử
- Widget test: Cuộn nhanh giả lập và kiểm tra debounce nạp ad.
- Golden/Performance test: Đo frame rendering time không vượt quá 16ms.
- Integration test: `example/integration_test/t141_in_feed_native_ad_list_view_test.dart`.

## Kết quả xác minh

- Ticket đúng một phần: `InFeedAdListView` cũ tạo `NativeAdWidget` trực tiếp trong `itemBuilder` và `NativeAdWidget.initState` gọi `_initNative`, nên các slot mới mount khi fling vẫn bắt đầu load. `_allowed`/`AdSlot.beginLoad` chỉ chặn trùng theo cùng instance; không chặn nhiều slot khác nhau khi cuộn nhanh.
- Scope giảm: không thêm velocity threshold hay LRU ad-view cache. Flutter đã có tín hiệu settle; adapter đã có per-key `InlineAdInstanceRegistry`, `AdSlot.beginLoad`, `canLoadNative`/`recordNativeLoad`, disposal/tombstone bounds.
- RED: 3 widget case mới fail vì slot mount giữa scroll vẫn `active: true`.
- GREEN: 12/12 targeted; full 2318/2318; T141 integration 1/1 trên USB `R5CX613VZBR` (`SM-S928B`). Log fast-scroll có đúng một `in-feed load deferred — scroll in flight`, rồi một `scroll settled — releasing deferred native loads`; không spam theo frame.
- API golden cập nhật có chủ ý: widget phải giữ trạng thái scroll, nên `StatelessWidget` → `StatefulWidget`; constructor/usage không đổi. CHANGELOG ghi rõ.

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
