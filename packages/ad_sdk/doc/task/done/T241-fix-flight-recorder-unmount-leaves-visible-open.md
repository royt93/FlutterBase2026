# T241 — Flight Recorder: unmount khi đang visible để lại entry "visible" không đóng

- **Loại:** Bug
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done — fixed, tested (unit/widget/integration + real device), merged

## Vấn đề (Why)

Phát hiện khi audit độc lập T236 (round code-review, 2026-10-02): `BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget` đều dùng chung pattern `_recordFlightRecorderVisibility` + `_lastFlightRecorderVisible` dedup, gọi qua `VisibilityDetector.onVisibilityChanged`. Khi widget unmount (pop route, route replacement, list row bị xoá khỏi `ListView`) trong lúc đang ở trạng thái visible:

- `VisibilityDetector` KHÔNG tự tổng hợp một callback `visibleFraction = 0` lúc `RenderObject` bị detach/dispose — nó chỉ bắn callback khi còn gắn trong cây render và có thay đổi thực tế.
- Callback trễ nào đó (nếu có) bị chặn bởi guard `if (mounted) ...` trong `onVisibilityChanged`.
- Kết quả: `AdFlightRecorder` giữ lại entry cuối cùng là `*Visible` không bao giờ có `*Hidden` khép lại — chuỗi bằng chứng export ra ngoài (`.adproof`) có một "phiên hiển thị" treo vô thời hạn về mặt dữ liệu, dù UI thực tế đã biến mất từ lâu.

Hành vi này có từ T231 (khi `BannerAdWidget`/`MrecAdWidget` được thêm `_recordFlightRecorderVisibility`), không phải lỗi mới của T236 — T236 chỉ khiến `NativeAdWidget` kế thừa đúng pattern (và đúng gap) này.

## Đề xuất giải pháp

Trong `dispose()` của cả 3 widget (`BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget`), nếu `_lastFlightRecorderVisible == true` lúc dispose:
1. Ghi một entry `*Hidden` cuối cùng TRƯỚC khi gọi `super.dispose()`, dùng toạ độ/kích thước cuối cùng đã biết (không cần `context.findRenderObject()` nữa vì render object sắp bị huỷ — có thể cache `Offset`/`Size` cuối cùng từ lần `_recordFlightRecorderVisibility` gần nhất, tương tự cách T236 thêm `_lastVisibilityInfo` cho Native).
2. Đặt `_lastFlightRecorderVisible = false` ngay sau đó để tránh double-close nếu có code path dispose gọi hai lần.

### Acceptance Criteria

- [x] Unmount một Banner/MREC/Native đang hiển thị (pop route, hoặc `ListView` xoá item) với flight recorder bật → entry `*Hidden` cuối cùng được ghi, hash chain vẫn hợp lệ.
- [x] Widget unmount khi CHƯA từng visible (`_lastFlightRecorderVisible == null` hoặc `false`) → không ghi entry thừa.
- [x] Không đổi hành vi khi flight recorder tắt (default OFF) — vẫn early-return như hiện tại.
- [x] Không tạo lớp trừu tượng mới; tái dùng đúng helper `_recordFlightRecorderVisibility`/field hiện có ở từng widget.
- [x] `flutter analyze` sạch; test liên quan pass.

## Kế hoạch kiểm thử

- [x] Widget test cho cả 3 widget: mount → trigger visible → pop route (hoặc remove khỏi `ListView`) → assert `*Hidden` entry cuối cùng tồn tại và `verifyFlightRecorderChain` vẫn `true`.
- [x] Widget test: mount nhưng chưa từng visible → unmount ngay → assert KHÔNG có entry `*Hidden` thừa (mảng `entries` rỗng hoặc không chứa `*Hidden` không khớp `*Visible` nào).
- [x] Integration/device: pop một màn hình có Banner/Native đang hiển thị, xuất `.adproof`, xác nhận chain đóng đúng.

## Kết quả thực tế (2026-10-04)

- Production: `banner_ad_widget.dart`, `mrec_ad_widget.dart`, `native_ad_widget.dart` — `dispose()` gọi helper đóng evidence interval bằng toạ độ/kích thước cache cuối cùng (không dùng `context.findRenderObject()` lúc dispose).
- Test: `test/banner_ad_widget_test.dart`, `test/mrec_ad_widget_test.dart`, `test/native_ad_widget_test.dart` — 134 test (mới + sửa) pass; full suite 2474/2474 pass; `flutter analyze` sạch (package + example).
- Integration device thật: `example/integration_test/t231_flight_recorder_test.dart` thêm 2 test mới (pop route khi Banner visible; remove khỏi `ListView` khi Native visible), chạy trên **TECNO BG6** (device thật, `118743744X002560`) — 6/6 test trong file pass, lặp lại 2 lần liên tiếp để loại trừ may rủi.
  - Phát hiện phụ trong lúc chạy trên device thật (không phải bug T241): một VIP trial thật tự cấp lúc `initialize()` và trạng thái `isConnected` dùng giá trị cache cuối (`_lastConnected`) có thể trễ theo Wi-Fi thật — cả hai đều là hành vi SDK có chủ đích, không phải lỗi. Đã thêm `clearSdkData(allIncludingEntitlements)` + chờ `isConnected` trong chính test file để cách ly kết quả khỏi state thiết bị, không đụng code sản phẩm.

## Audit độc lập sau khi "xong" lần đầu — 3 bug thật tìm thấy (2026-10-04)

Sau khi code+test ở trên pass, chạy audit độc lập (2 reviewer tĩnh, không chạy build/test) trước khi commit. Cả 2 phát hiện bug thật mà bản fix đầu tiên bỏ sót:

1. **HIGH — export/disable race làm mất entry đóng.** `recordFlightRecorderEvent`/helper đóng interval dùng `unawaited(...)`, và `await IabStorage.read(...)` bên trong khiến ghi vào hash chain xảy ra SAU khi `dispose()` đã return. Một host gọi `exportSignedFlightRecorderBundle()` hoặc `disableFlightRecorder()` ngay sau route pop (đúng use case T241) có thể lấy bundle thiếu `*Hidden` vừa ghi, hoặc tệ hơn recorder bị dispose trước khi write kịp chạy → entry bị `_doRecord`'s `_disposed` guard âm thầm drop vĩnh viễn.
2. **HIGH — swap recorder giữa lúc widget mounted tạo orphan `*Hidden`.** `_lastFlightRecorderVisible` không gắn với recorder cụ thể nào — nếu host gọi `enableFlightRecorder`/`disableFlightRecorder` thay recorder trong lúc widget vẫn đang mounted+visible, lúc dispose code ghi `*Hidden` vào recorder HIỆN TẠI (mới), không phải recorder đã giữ `*Visible` gốc → entry mồ côi không có `*Visible` khớp trong chain của nó.
3. **MAJOR — House Ad bị gắn nhầm nhãn provider thật lúc dispose.** Khi quảng cáo thật lỗi/no-fill chuyển sang House Ad fallback trong lúc banner/MREC vẫn đang visible (không có callback visibility mới nào fire vì on-screen fraction không đổi), `_lastFlightRecorderVisible` vẫn kẹt `true` từ quảng cáo thật. Lúc unmount, helper đóng interval ghi `*Hidden` gắn `providerTag` thật cho nội dung thực chất là House Ad — đúng điều mà guard T237 (`_isShowingHouseAdFallback`) tồn tại để ngăn, nhưng helper đóng interval của T241 không áp dụng guard đó. Chỉ ảnh hưởng Banner/MREC (Native không có House Ad).

**Fix:**
- `AdManager` thêm `Map<AdFlightRecorder, Future<void>> _flightRecorderWriteChains` — mỗi recorder có write-chain RIÊNG (không còn 1 `Future` toàn cục dùng chung mọi recorder). `exportSignedFlightRecorderBundle()` chỉ chờ chain của recorder hiện tại; `enableFlightRecorder`/`disableFlightRecorder` chỉ dispose recorder cũ sau khi chain của CHÍNH NÓ xong (dispose đồng bộ ngay nếu không có write nào đang chạy — giữ đúng hành vi cũ cho test gọi đồng bộ).
  - Thử lần đầu dùng 1 `Future?` toàn cục duy nhất cho mọi recorder → gây regression nặng hơn: 1 write bị kẹt ở bất kỳ recorder/test nào (vd. `tester` bị teardown trước khi mock `IabStorage` resolve) làm MỌI export/disable sau đó trong cùng process treo vô thời hạn (`flutter test test/banner_ad_widget_test.dart` timeout 10 phút). Phát hiện qua integration suite thật, sửa lại đúng theo hướng user đã chọn ("track theo recorder").
- `closeFlightRecorderInterval(recorder, ...)` (method `@internal` mới trên `AdManager`) đóng interval đúng vào recorder đã CAPTURE lúc ghi `*Visible` (field `_lastFlightRecorderInstance` mới ở cả 3 widget), không phải recorder hiện tại.
- Banner/MREC: helper đóng interval giờ kiểm tra `_isShowingHouseAdFallback` (getter mới, dùng chung với `_recordFlightRecorderVisibility`) — nếu đang hiển thị House Ad thì bỏ qua việc ghi `*Hidden` hoàn toàn (an toàn hơn: để interval mở còn hơn gắn sai nhãn).
- Test mới trong `test/banner_ad_widget_test.dart`: house-ad-at-dispose, recorder-swap-no-orphan, export-race (3 test, dùng `tester.runAsync()` cho test export vì gọi crypto thật).
- Verify lại: `flutter analyze` sạch (package+example), full suite 2478/2478 pass, 6/6 integration test T231/T241/T238 pass 2 lần liên tiếp trên **Samsung S24 Ultra thật** (`R5CX613VZBR`, máy khác TECNO BG6 lần chạy trước — vẫn là device thật theo đúng yêu cầu).
