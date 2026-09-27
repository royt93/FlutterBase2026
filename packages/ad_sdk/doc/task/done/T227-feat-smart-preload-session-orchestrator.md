# T227 — Tính năng mới: Bộ điều phối nạp trước thông minh theo trạng thái phiên và pin

- **Loại:** New Feature
- **Priority:** P2 · **Severity:** LOW
- **Status:** ✅ done — REFUTED / scope-reduced (owner-approved decision, not an audit finding to reopen)

## Vấn đề (Why, như đề xuất ban đầu)
Nạp trước (Preload) quảng cáo giúp sẵn sàng hiển thị ngay lập tức, nhưng nếu thiết bị đang yếu pin (Battery Saver) hoặc mạng yếu, việc nạp ồ ạt gây tốn năng lượng và lãng phí request.

## Đề xuất giải pháp & Acceptance Criteria (như đề xuất ban đầu)
1. Xây dựng `AdPreloadOrchestrator` phối hợp với `AdSafetyConfig`:
   - Trì hoãn preload khi pin <15% hoặc đang ở chế độ tiết kiệm dữ liệu.
   - Lên lịch preload thông minh theo xác suất người dùng sắp chạm điểm chuyển cảnh.
2. Cung cấp API bật/tắt linh hoạt cho host app.

## Kết luận điều tra (2026-09-27)

Ticket có 2 nửa. Điều tra trước khi viết code (đúng kỷ luật series T223-T226) cho thấy:

### Nửa 1 — "Lên lịch preload thông minh theo xác suất chuyển cảnh": ĐÃ CÓ SẴN
`JourneyPrefetcher` (`lib/src/monetization/journey_prefetcher.dart`, T123/T139) đã làm chính xác việc này:
opt-in, host gọi `notifySignal(signal, type)` tại điểm trong journey thường xảy ra trước khi
hiển thị quảng cáo; `JourneyPrefetcher` tự học rolling average thời gian từ signal đến lúc
show thật (persist qua `AdPreferences`), và ngưng preload sớm nếu tín hiệu đó không còn đáng
tin cậy (`maxHoldDuration`). `autoRouteSignalType` (T139) còn tự động hoá qua route observer
mà không cần gọi tay. Xây thêm `AdPreloadOrchestrator` cho phần này sẽ trùng lặp
(cùng bẫy như T223/T224 đã REFUTED trong series này).

### Nửa 2 — "Trì hoãn preload khi pin <15% hoặc data-saver": TỪ CHỐI, không có tín hiệu sẵn có
Rà soát toàn bộ codebase: không có bất kỳ battery API, MethodChannel/platform channel, hay
dependency nào đọc được mức pin hoặc trạng thái tiết kiệm dữ liệu (`rg MethodChannel lib/` =
0 kết quả). Dependency kết nối mạng duy nhất trong `pubspec.yaml`, `connection_notifier
^4.1.1`, chỉ bọc `internet_connection_checker_plus` và chỉ lộ ra `isConnected`/
`onStatusChange` (có mạng hay không) — không có API pin, không có API data-saver/metered.
Đọc trực tiếp mã nguồn của `connection_notifier` trong pub-cache xác nhận không có API nào
gần với việc này.

Muốn làm phần này sẽ cần thêm dependency mới (ví dụ `battery_plus` cho pin) và/hoặc viết
platform-channel riêng cho data-saver (khái niệm chỉ tồn tại rõ ràng trên Android, iOS không
có tương đương — chỉ có Low Power Mode). Đây đúng là quyết định sản phẩm/dependency thật,
không phải chi tiết kỹ thuật có thể tự quyết — đã dừng lại và hỏi owner thay vì tự thêm
dependency cho một SDK xuất bản có kỷ luật pinning nghiêm ngặt (xem `CLAUDE.md`).

**Owner đã quyết định (giải thích bằng ví dụ đời thường, non-tech):** BỎ phần pin/data-saver.
Chỉ giữ phần đã có sẵn (`JourneyPrefetcher`). Quyết định này khớp với quyết định owner đã có
từ trước cho **T182** (`doc/task/done/T182-low-power-data-saver-mode-SKIP.md`, 2026-09-08,
xác nhận lại 2026-09-26) — chủ dự án ưu tiên doanh thu quảng cáo ổn định hơn tính năng
thân thiện pin/data ở thời điểm hiện tại. T227 không nên bị mở lại thành audit finding khi
chưa có quyết định owner mới.

## Thay đổi thực tế
Không có thay đổi code, không thêm dependency. Chỉ đóng task này với verdict REFUTED /
scope-reduced như trên.

## Kế hoạch kiểm thử
Không cần test mới — không có hành vi/code nào thay đổi. Coverage hiện tại của
`JourneyPrefetcher` (`test/journey_prefetcher_test.dart` và các test liên quan T133/T139/T162)
giữ nguyên, không cần bổ sung.
