# T201 — InlineAdController imperative lifecycle (NEW)
Priority P2 · Status todo.

Inline host hiện phải tự phối hợp rebuild/manager calls; đề xuất controller gắn một slot để refresh/pause/resume/status, idempotent dispose, không bypass policy. Manager singleton methods là option nhưng dễ tác động placement khác.

Tests: unit command serialization; widget attach/detach/rebuild; integration scroll/background/consent; Android+iOS device smoke banner/MREC/native.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.

## Kết quả (2026-09-15)

**Đã làm:**

- Thêm class mới `InlineAdController` (`lib/src/widget/inline_ad_controller.dart`,
  export ở `applovin_admob_sdk.dart`): `refresh()`/`pause()`/`resume()`/`status`
  (`detached`/`active`/`paused`), `dispose()` idempotent, và một interface nội
  bộ `InlineAdControllerTarget` mà `_BannerAdWidgetState`/`_MrecAdWidgetState`/
  `_NativeAdWidgetState` implement.
- Thêm param `controller` (mutual-exclusive với `active` — assert ở
  constructor) cho cả 3 widget: `BannerAdWidget`, `MrecAdWidget`,
  `NativeAdWidget`. Widget tự `attach()`/`detach()` controller ở
  `initState`/`didUpdateWidget`/`dispose` — đúng như pattern
  `TextEditingController` của Flutter.
- `refresh()` gọi lại đúng gate sẵn có (`canLoadBanner`/`canLoadMrec`/
  `canLoadNative` — cooldown; `_initBanner`/`_initMrec`/`_initNative` —
  consent/VIP/connectivity) — **không bypass policy**: một refresh trong lúc
  cooldown bị bỏ qua âm thầm, không ép load.
- `pause()`/`resume()` dùng lại đúng đường automatic (`_applyVisibility`,
  giống hệt `VisibilityDetector`/route-away) cho Banner/MREC; với Native
  (không có auto-refresh ticker để tạm dừng) thì dispose-and-reload.
- Command trước khi attach (refresh/pause/resume gọi lúc chưa có widget nào
  gắn) được nhớ lại — không mất — áp dụng ngay khi widget kế tiếp attach.
  Nhiều lệnh liên tiếp trước khi attach được "gộp" về trạng thái cuối cùng
  (state-based), không phải một hàng đợi phát lại từng lệnh — tránh trường
  hợp pause→refresh→resume phát lại theo đúng thứ tự literal lại gây refresh
  trong lúc đang tạm dừng.

**2 lỗi thật tìm thấy trong lúc viết integration test (không phải lỗi giả định
— cả hai đều được revert-and-confirm-red trước khi sửa):**

1. `BannerAdWidget`/`MrecAdWidget`'s `didPopNext()` (trở lại route sau khi
   push/pop) gọi lại `_initBanner`/`_initMrec` **vô điều kiện** trên nhánh
   AdMob — nếu host đã `pause()` qua controller, một route push+pop thật sự
   (ví dụ mở dialog rồi đóng) sẽ âm thầm load lại banner/mrec dù đang paused.
   Đã sửa: thêm gate `_pausedByController` vào đầu `didPopNext()`.
   (Lưu ý: gap tương tự với `active: false` thuần túy — không qua controller —
   đã tồn tại từ trước T201, KHÔNG thuộc phạm vi task này, để dành cho task
   sau nếu chủ dự án muốn sửa.)
2. `controllerSetPaused(false)` gọi `_applyVisibility(true)` → có thể gọi
   `didPopNext()` nội bộ → nhánh AdMob dùng `addPostFrameCallback` chờ frame
   kế tiếp để load lại — nhưng khi `resume()` được gọi từ code bên ngoài (không
   phải giữa lúc build hay giữa một route transition thật), không gì đảm bảo
   sẽ có frame kế tiếp, nên callback bị treo vô thời hạn. Đã sửa: thêm
   `WidgetsBinding.instance.scheduleFrame()` sau `_applyVisibility()` trong
   `controllerSetPaused`.

**Test:**

- Unit (`test/inline_ad_controller_test.dart`, 18 test): attach/detach state,
  command serialization của refresh/pause/resume trước khi attach (coalesce
  đúng theo trạng thái cuối, không replay từng lệnh), notifyListeners, và
  dispose() idempotent (gọi 2 lần không throw, gọi lệnh sau khi dispose không
  throw).
- Widget (`test/inline_ad_controller_widget_test.dart`, 15 test): assert
  mutual-exclusion active/controller cho cả 3 widget; attach khi mount/detach
  khi dispose; rebuild giữ nguyên controller không assert; đổi sang controller
  khác giữa chừng detach cái cũ/attach cái mới; refresh() tôn trọng cooldown
  thật; pause()/resume() dispose/reload thật qua fake adapter (đếm
  `loadBannerCalls`/`disposeCalls` thật); và test tái hiện đúng lỗi #1 ở trên
  (route push+pop trong lúc paused không được âm thầm load lại).
- Widget demo page (`example/test/inline_ad_controller_demo_page_test.dart`,
  5 test): trang demo `InlineAdControllerDemoPage` (3 section Banner/MREC/
  Native, mỗi section có controller + nút Refresh/Pause/Resume + label
  status riêng) — pause 1 section không ảnh hưởng 2 section còn lại.
- Integration thật trên **thiết bị Android thật** (Samsung, serial
  `R5CX613VZBR`) — `example/integration_test/t201_inline_ad_controller_test.dart`:
  chạy app thật (`app.main()`), chờ splash → home → SDK init xong, mở trang
  demo T201, pause Banner section, rồi lần lượt: kéo scroll (không bị resume
  ngầm), push+pop một route thật (không bị reload ngầm — chính là lỗi #1),
  và `AdManager().setConsent(hasUserConsent: false)` (rút personalisation —
  không bị resume ngầm), cuối cùng resume() thật load lại. **PASS trên thiết
  bị thật.**
- Không có thiết bị iOS trong môi trường này để smoke thật trên iOS — giống
  các task trước, đây là giới hạn môi trường, không phải bỏ sót có chủ đích.
- Không chạy được `codex review --uncommitted` (hết hạn mức từ trước trong
  phiên — chủ dự án đã cho phép bỏ qua để tiếp tục làm).

**Kết quả test toàn bộ:**
- `flutter test` (SDK, `packages/ad_sdk`): 2107/2107 pass (từ 2074 trước T201,
  +33 test mới: 18 unit + 15 widget).
- `flutter test` (example, `packages/ad_sdk/example`): 58/58 pass (từ 52
  trước T201, +6 test mới: 1 navigation + 5 demo page).
- `flutter analyze`: sạch cả 2 package.

**Tự chấm điểm: 9/10.** Trừ điểm vì (1) không chạy được codex review (được
chủ dự án cho phép bỏ qua), (2) không smoke được trên iOS thật (không có
thiết bị), và (3) một gap tương tự (`active: false` + route push/pop) vẫn
còn tồn tại độc lập với T201 — đã ghi chú rõ, không thuộc phạm vi task này.
