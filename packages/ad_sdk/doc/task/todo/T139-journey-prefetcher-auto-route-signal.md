# T139 — Enhancement: JourneyPrefetcher tự học qua AdRouteObserver (opt-in auto-mode)

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P3
- **Status:** 🔲 todo
- **Effort:** M
- **Files (dự kiến):** `lib/src/monetization/journey_prefetcher.dart`,
  `lib/src/core/ad_route_observer.dart`
- **Nguồn gợi ý:** codex + agy đồng thuận
- **Dependency:** T133 (fix rò rỉ signal không TTL) — **BẮT BUỘC kiểm tra
  `doc/task/done/T133-*.md` tồn tại trước khi bắt đầu.** Thêm auto-mode tự
  sinh signal thường xuyên hơn host tự gọi thủ công sẽ khuếch đại đúng bug
  rò rỉ T133 đang sửa (nhiều signal hơn = giữ rác lâu hơn nếu chưa có TTL).

## Vấn đề

`journey_prefetcher.dart:11` (doc comment): "Host apps call [notifySignal]
at points in their own user journey" — xác nhận API hiện tại 100% thủ công,
`notifySignal(String signal, AdSlotType type)` (dòng 111) là entry point
DUY NHẤT. Không có bất kỳ tích hợp nào với route/navigation — host phải tự
gọi đúng chỗ trong code của họ, dễ quên/bỏ sót màn hình mới.

SDK đã có sẵn `adRouteObserver`/`AdScreenRouteLogger`
(`lib/src/core/ad_route_observer.dart`) theo dõi route push/pop toàn app
(dùng cho banner RouteAware lifecycle) — có thể tái dùng để TỰ ĐỘNG sinh
signal khi route đổi, thay vì bắt host tự gọi.

## Việc cần làm

- [ ] Thêm opt-in constructor param hoặc method mới cho `JourneyPrefetcher`
      — ví dụ `JourneyPrefetcher({bool autoRouteSignal = false, ...})` —
      khi bật, subscribe vào `adRouteObserver` (như cách `AdScreenRouteLogger`
      đang làm) để tự động gọi `notifySignal` mỗi khi route MỚI được push,
      dùng tên route (`ModalRoute.settings.name`) làm giá trị `signal` nếu
      có, bỏ qua nếu route không có name.
- [ ] Giữ `notifySignal()` public hoạt động y hệt — auto-mode chỉ là
      NGUỒN GỌI THÊM, không thay thế; host vẫn có thể tự gọi thủ công song
      song nếu muốn signal tinh chỉnh hơn route name.
- [ ] Test rõ: bật `autoRouteSignal` không được double-count nếu host CŨNG
      tự gọi `notifySignal` thủ công cho cùng route (documented behavior:
      chấp nhận trùng, coi là 2 signal riêng biệt — không cần dedupe phức
      tạp, ghi rõ trong doc comment để host biết mà tự tránh gọi đôi nếu
      không muốn).
- [ ] Cập nhật doc comment giải thích rõ auto-mode chỉ nên bật NẾU route
      name của app đủ ý nghĩa để dùng làm signal (nhiều app không đặt tên
      route rõ ràng) — nếu không, khuyên dùng `notifySignal` thủ công như
      cũ.

## Ghi chú

Effort M — chủ yếu là wiring thêm 1 `RouteAware`/listener, không đổi core
scoring logic của `JourneyPrefetcher`. Rủi ro chính: route name không phải
lúc nào cũng match đúng ý nghĩa "signal" mà `notifySignal` gốc kỳ vọng
(app đặt tên route theo screen, không phải theo "hành vi user"). Ghi rõ
trong doc comment đây là tiện lợi/gần đúng, không thay thế hoàn toàn signal
tinh chỉnh tay.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T139-journey-prefetcher-auto-route-signal.md này
(nếu đã chuyển sang inprogress/ hoặc done/ thì đọc ở đó). Implement ĐÚNG
scope mô tả trong "Việc cần làm" — KHÔNG thêm scope ngoài mô tả.

Cần T133 xong trước khi bắt đầu — kiểm tra doc/task/done/T133-*.md tồn tại
chưa, nếu chưa thì dừng lại và báo user.

SDK này KHÔNG có backend/server riêng — ticket này thuần on-device
(RouteObserver có sẵn), không liên quan remote config.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R
nguyên khối tránh ENOSPC) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
