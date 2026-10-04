# T236 — Mở rộng Flight Recorder ghi nhận Fullscreen (App Open/Interstitial/Rewarded) và Native

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done (commit 0ca4928)

## Vấn đề (Why)

`AdFlightRecorder` (T231) hiện chỉ có 3 nguồn ghi nhận thật:

- `BannerAdWidget._recordFlightRecorderVisibility` (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:324-341`) → `bannerVisible`/`bannerHidden`.
- `MrecAdWidget._recordFlightRecorderVisibility` (`lib/src/widget/mrec_ad_widget.dart:97-114`) → `mrecVisible`/`mrecHidden`.
- `AdManager._emit` khi `event is AdClickEvent` (`lib/src/core/ad_manager.dart:9592-9599`) → `clicked`, dùng chung mọi format.

4 điểm `_emit(AdShowEvent(...))` cho App Open/Interstitial/Rewarded (`ad_manager.dart:7710`, `8064`, `8537`, `8779`) và toàn bộ `NativeAdWidget` (`lib/src/widget/native_ad_widget.dart`) **không** gọi `recordFlightRecorderEvent` ở đâu cả.

T231 viết ra chính để đối chất "Invalid Traffic"/"Ad layout che UI" với nhà mạng — hai tranh chấp phổ biến nhất chính là fullscreen (App Open che UI khi hiện sai lúc, T230's ad-fatigue fast-close cũng liên quan trực tiếp tới fullscreen dismiss timing) và Native (layout tự vẽ, đúng thứ T228 vừa mở rộng). Thiếu 2 mảng này nghĩa là bằng chứng flight-recorder không phủ đúng 2 bề mặt rủi ro chính sách cao nhất.

## Đề xuất giải pháp

Thêm `recordFlightRecorderEvent` tại đúng các điểm hiện có, tái dùng label convention hiện tại (`'*Visible'`/`'*Hidden'` cho khả năng dùng `interactionDurationMs`, hoặc nhãn mới `'fullscreenShown'`/`'fullscreenDismissed'`/`'nativeVisible'`/`'nativeHidden'` phù hợp free-text convention đã ghi trong `FlightRecorderEntry.label`'s doc comment):

1. 4 điểm `_emit(AdShowEvent(...))` fullscreen: ghi 1 entry lúc show thành công (label `'fullscreenShown'`, `type` tương ứng) và 1 entry lúc dismiss (label `'fullscreenDismissed'`) — tận dụng `showStopwatch`/`dismissed` đã có sẵn tại chỗ.
2. `NativeAdWidget`: thêm `VisibilityDetector` giống Banner/MREC CHỈ để phục vụ flight recorder khi bật (class doc comment hiện tại của `NativeAdWidget` giải thích lý do KHÔNG có `VisibilityDetector` cho auto-pause — nhưng đó là quyết định khác mục đích; ghi nhận evidence không bắt buộc phải gắn với auto-pause/refresh logic).

### Acceptance Criteria

- [x] Mỗi format fullscreen tạo đúng 1 cặp entry show/dismiss khi flight recorder bật; không entry nào khi tắt (giữ đúng "zero overhead when disabled").
- [x] Native tạo entry visible/hidden tương tự Banner/MREC khi flight recorder bật; không thêm auto-pause/refresh behavior mới cho Native (ngoài phạm vi, đã có quyết định riêng trong doc comment của widget).
- [x] Không đổi hành vi khi flight recorder tắt (default OFF).
- [x] Không tạo lớp trừu tượng mới; tái dùng đúng API `recordFlightRecorderEvent`/`AdFlightRecorder.record` hiện có.
- [x] `flutter analyze` sạch; full `flutter test` pass; `test/goldens/public_api_surface.txt` cập nhật nếu có thay đổi API công khai.

## Kế hoạch kiểm thử

- Unit: bật flight recorder qua `FakeAdapter`, show+dismiss từng loại fullscreen, assert entry đúng label/type/chain hợp lệ.
- Widget: `NativeAdWidget` mount/hide qua VisibilityDetector, assert visible/hidden entry tương ứng, dedup giống Banner/MREC (`_lastFlightRecorderVisible` pattern).
- Integration: mở rộng `example/integration_test/t231_flight_recorder_test.dart` (hoặc file kế thừa) cho ít nhất 1 fullscreen format + native trên thiết bị thật.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T236 theo quy trình TDD chuẩn:
1. Đọc kỹ ticket, đối chiếu đúng vị trí `_emit(AdShowEvent(...))` và `NativeAdWidget` hiện tại trước khi sửa.
2. Viết test trước cho từng format fullscreen + native, cả khi recorder bật và tắt.
3. Sửa tối giản, tái dùng pattern Banner/MREC đã có, không đổi hành vi auto-pause của Native.
4. Tín hiệu kết thúc vòng lặp: audit độc lập >9/10, đủ test pyramid, smoke test thật trên device cho ít nhất App Open + Native, rồi mới commit/push.
