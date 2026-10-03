# T236 — Mở rộng Flight Recorder ghi nhận Fullscreen (App Open/Interstitial/Rewarded) và Native

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done

## Bằng chứng kiểm thử & Hoàn thành

**Lưu ý quan trọng — 2 vòng audit độc lập phát hiện lỗi thật, đã fix trước khi publish:**

Vòng 1 (5 lỗi):
1. Backdating `fullscreenShown` về `dismissedAt - durationMs` làm hỏng thứ tự thời gian trong hash chain nếu có `clicked` entry ghi giữa chừng → đổi sang ghi CẢ HAI entry tại thời điểm dismiss thật (không backdate).
2. Nhãn đổi từ `fullscreenShown` → **`fullscreenVisible`** để khớp `AdFlightRecorder._msSinceLastVisible`'s `endsWith('visible')` lookup — nhãn cũ khiến `interactionDurationMs` luôn = 0 cho mọi click trong lúc xem fullscreen.
3. `_recordFullscreenFlight` re-check `identical(_flightRecorder, recorder) && !recorder.isDisposed` SAU `await IabStorage.read` để không ghi nhầm vào recorder đã bị thay/dispose khi đang chờ.
4. `NativeAdWidget` guard thêm `AdManager().nativeIsLoaded(this).value` vào điều kiện `visible` — trước đó ShimmerView placeholder (ad chưa load xong) bị ghi nhận thành `nativeVisible` giả mạo; nếu load sau đó fail (no-fill), chuỗi bằng chứng giữ lại một impression chưa từng thật sự hiển thị. Thêm listener `nativeIsLoaded` để re-check visibility khi ad load xong (geometry không đổi nên `VisibilityDetector` không tự fire lại).
5. (Thử nghiệm ban đầu ở vòng 1, đã revert ở vòng 2) Từng đổi 4 callback dismiss (`onDismiss`/`onDone`) thành `async` + `await _recordFullscreenFlight(...)` ngay bên trong để đóng race export — nhưng cách này phá vỡ 8 test khác (SSV plumbing, event delivery) vì adapter/fake gọi các callback đó KHÔNG đợi Future trả về; `await` bên trong một callback kiểu `void Function(...)` không làm nơi gọi nó thật sự chờ, chỉ trì hoãn mọi statement sau await đó (kể cả `_emit(...)`/`onEarnedReward(...)`) sang một microtask khác, phá đồng bộ tính timing mà các test khác phụ thuộc.

Vòng 2 (kiến trúc đúng, phát hiện khi chạy lại full suite sau thử nghiệm vòng 1):
- Giữ nguyên 4 callback dismiss **sync** như ban đầu — không đổi calling convention của `showRewardedAd()`/`showInterstitial()`/etc.
- `_recordFullscreenFlight(...)` vẫn gọi `unawaited(...)` tại mỗi điểm dismiss, nhưng Future được lưu vào field mới `_pendingFlightRecorderWrite`.
- `exportSignedFlightRecorderBundle()` `await _pendingFlightRecorderWrite` TRƯỚC khi đọc `recorder.entries` — đóng đúng race T231 (host export ngay trong `onAdDismiss` không bao giờ thiếu entry) mà KHÔNG đổi timing của callback gốc, không phá test khác.
- Thêm public getter `AdFlightRecorder.isDisposed` để hỗ trợ check ở trên, và public `AdFlightRecorder.recordPair(...)` để ghi atomically 2 entry liền nhau trong cùng `_writeChain` (không bị split bởi concurrent write/recorder swap) — `CHANGELOG.md` và `test/goldens/public_api_surface.txt` đã cập nhật đúng theo rule "intentional public changes require a CHANGELOG.md entry and regenerated golden" (xem Acceptance Criteria cuối cùng bên dưới — KHÔNG phải "không đổi public API" như nháp ban đầu).

- **Unit test:** `test/t236_flight_recorder_fullscreen_native_test.dart` (9 test) — 4 format fullscreen đều assert đúng 1 cặp `fullscreenVisible`/`fullscreenDismissed` (dùng `singleWhere`, không phải lỏng `isNotEmpty`), timestamp không đảo ngược kể cả khi có `clicked` entry xen giữa, `exportSignedFlightRecorderBundle()` gọi NGAY trong `onAdDismiss` vẫn thấy đủ cặp entry (test race qua export thật, không phải qua timing giả định của callback), recorder bị swap giữa chừng không ghi nhầm vào bên nào, show thất bại không ghi sai, recorder OFF không tạo overhead.
- **Widget test:** `test/native_ad_widget_test.dart` (group `T236 Flight Recorder visibility evidence`) — `nativeVisible` chỉ ghi khi ad THẬT SỰ loaded (không phải Shimmer placeholder), toạ độ pixel thật, `nativeHidden` khi cuộn khỏi màn hình, dedup nhiều lần gọi liên tiếp, recorder OFF không mount `VisibilityDetector` (zero overhead xác nhận bằng `findsNothing`).
- **Integration test (Device thật, Google Pixel 7 Pro `2B051FDH3006MU`):** `example/integration_test/t231_flight_recorder_test.dart` — dùng `FakeAdProviderAdapter` (seam có sẵn từ T212/T231, cùng cách banner/mrec test trong file này đã làm từ trước) để lái `AdManager.showAppOpenAd()`/`NativeAdWidget` một cách xác định, không phụ thuộc tỉ lệ fill AdMob thật. Test này chứng minh những gì CÓ THỂ chứng minh trên device thật mà không cần mạng: `VisibilityDetector` callback timing thật, toạ độ pixel thật từ `RenderBox.localToGlobal`/`size` trên cây render thật, và toàn bộ orchestration `AdManager` thật (không phải mock). **Không chứng minh** hành vi native SDK provider thật (AdMob/AppLovin callback timing) — phần đó nằm ngoài phạm vi T236, coverage riêng đã có ở các integration test khác.
- **Static analysis:** `flutter analyze` sạch 0 issue. **Full suite:** `flutter test` 2452/2452 pass, bao gồm `api_golden_test.dart` khớp golden đã regenerate.

## Acceptance Criteria
- [x] Mỗi format fullscreen tạo đúng 1 cặp entry visible/dismiss khi flight recorder bật; không entry nào khi tắt (giữ đúng "zero overhead when disabled").
- [x] Native tạo entry visible/hidden tương tự Banner/MREC khi flight recorder bật, CHỈ khi ad thật sự loaded (không phải placeholder); không thêm auto-pause/refresh behavior mới cho Native.
- [x] Không đổi hành vi khi flight recorder tắt (default OFF).
- [x] Không tạo lớp trừu tượng mới; tái dùng đúng API `AdFlightRecorder.record` hiện có qua private helper `_recordFullscreenFlight`.
- [x] `flutter analyze` sạch; `flutter test` toàn bộ pass.
- [x] Public API surface CÓ đổi (thêm `AdFlightRecorder.isDisposed` getter + `recordPair` method, cần thiết để fix race an toàn — xem Finding 3 ở trên) — đã tuân thủ đúng rule: `CHANGELOG.md` có entry `[Unreleased]`, `test/goldens/public_api_surface.txt` đã regenerate và `api_golden_test.dart` pass.

**Known gap, không fix trong T236 (xem T241):** nếu widget bị unmount (pop/route-replace/list-row-remove) trong khi đang `nativeVisible`/`bannerVisible`/`mrecVisible`, `VisibilityDetector` không tự tổng hợp callback fraction=0 lúc dispose, và `mounted` guard chặn callback trễ nào đó — chuỗi bằng chứng bị treo ở trạng thái "visible" không đóng. Hành vi này có từ T231 (Banner/MREC), Native chỉ kế thừa; sửa chung cả 3 bề mặt trong T241 thay vì vá lệch một mình Native ở đây.

`AdFlightRecorder` (T231) hiện chỉ có 3 nguồn ghi nhận thật:

- `BannerAdWidget._recordFlightRecorderVisibility` (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:324-341`) → `bannerVisible`/`bannerHidden`.
- `MrecAdWidget._recordFlightRecorderVisibility` (`lib/src/widget/mrec_ad_widget.dart:97-114`) → `mrecVisible`/`mrecHidden`.
- `AdManager._emit` khi `event is AdClickEvent` (`lib/src/core/ad_manager.dart:9592-9599`) → `clicked`, dùng chung mọi format.

4 điểm `_emit(AdShowEvent(...))` cho App Open/Interstitial/Rewarded (`ad_manager.dart:7710`, `8064`, `8537`, `8779`) và toàn bộ `NativeAdWidget` (`lib/src/widget/native_ad_widget.dart`) **không** gọi `recordFlightRecorderEvent` ở đâu cả.

T231 viết ra chính để đối chất "Invalid Traffic"/"Ad layout che UI" với nhà mạng — hai tranh chấp phổ biến nhất chính là fullscreen (App Open che UI khi hiện sai lúc, T230's ad-fatigue fast-close cũng liên quan trực tiếp tới fullscreen dismiss timing) và Native (layout tự vẽ, đúng thứ T228 vừa mở rộng). Thiếu 2 mảng này nghĩa là bằng chứng flight-recorder không phủ đúng 2 bề mặt rủi ro chính sách cao nhất.

## Đề xuất giải pháp

Thêm `recordFlightRecorderEvent` tại đúng các điểm hiện có, tái dùng label convention hiện tại (`'*Visible'`/`'*Hidden'` cho khả năng dùng `interactionDurationMs`; các label mới là `'fullscreenVisible'`/`'fullscreenDismissed'`/`'nativeVisible'`/`'nativeHidden'`):

1. 4 điểm `_emit(AdShowEvent(...))` fullscreen: ghi đúng 1 cặp `'fullscreenVisible'`/`'fullscreenDismissed'` khi dismiss callback xác nhận ad thật sự đã `shown` (cùng timestamp dismiss thật; không backdate thời điểm show ước lượng vì sẽ phá thứ tự chain nếu có click ở giữa).
2. `NativeAdWidget`: thêm `VisibilityDetector` giống Banner/MREC CHỈ để phục vụ flight recorder khi bật (class doc comment hiện tại của `NativeAdWidget` giải thích lý do KHÔNG có `VisibilityDetector` cho auto-pause — nhưng đó là quyết định khác mục đích; ghi nhận evidence không bắt buộc phải gắn với auto-pause/refresh logic).

### Acceptance Criteria

- [ ] Mỗi format fullscreen tạo đúng 1 cặp entry show/dismiss khi flight recorder bật; không entry nào khi tắt (giữ đúng "zero overhead when disabled").
- [ ] Native tạo entry visible/hidden tương tự Banner/MREC khi flight recorder bật; không thêm auto-pause/refresh behavior mới cho Native (ngoài phạm vi, đã có quyết định riêng trong doc comment của widget).
- [ ] Không đổi hành vi khi flight recorder tắt (default OFF).
- [ ] Không tạo lớp trừu tượng mới; tái dùng đúng API `recordFlightRecorderEvent`/`AdFlightRecorder.record` hiện có.
- [ ] `flutter analyze` sạch; full `flutter test` pass; `test/goldens/public_api_surface.txt` cập nhật nếu có thay đổi API công khai.

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
