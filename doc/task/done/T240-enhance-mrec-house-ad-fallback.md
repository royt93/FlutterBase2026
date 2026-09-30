# T240 — Mở rộng House Ad fallback (T229) sang MrecAdWidget

- **Loại:** Enhancement
- **Priority:** P3 · **Severity:** LOW
- **Status:** ✅ done (2026-09-30)

## Vấn đề (Why)

T229 thêm `HouseAdItem`/`houseAd`/`houseAdDelay` chỉ cho `BannerAdWidget` (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:72-73, 109, 114`). `MrecAdWidget` (`lib/src/widget/mrec_ad_widget.dart`) có đúng 3 điểm blank-render giống Banner trước khi có T229 (dòng 461 `!allowed`, dòng 492 AdMob `hasError`, dòng 525 AppLovin `hasError` — đều `return const SizedBox.shrink();`) nhưng không có tham số house-ad nào, nên MREC no-fill/offline luôn để trống 300x250, trong khi Banner cùng tình huống đã có thể hiện nội dung nội bộ.

MREC là khối diện tích lớn hơn banner nhiều (300x250 vs ~320x50) — khoảng trắng no-fill ở đây ảnh hưởng UX rõ hơn banner, nên đây là gap thật đáng làm, không chỉ đối xứng API.

## Đề xuất giải pháp & Acceptance Criteria

1. Thêm `houseAd`/`houseAdDelay` (cùng type `HouseAdItem`, cùng default `Duration(seconds: 10)`) vào `MrecAdWidget`, tái dùng `HouseAdItem`/`_HouseAdSlot` đã có (không tạo class mới) — chỉ cần export lại/tái dùng widget nội bộ từ `banner_ad_widget.dart` hoặc factor `_HouseAdSlot` ra file chung nếu 2 widget cùng cần (tối giản, đúng tinh thần "không trùng lặp" của T229's Acceptance Criteria).
2. Chèn `_HouseAdSlot` vào đúng 3 điểm blank hiện tại của MREC, cùng convention Banner.
3. Không phát `AdEvent` giả, không đụng VIP suppression/safety gates/revenue accounting — y hệt điều kiện T229 đã đặt ra.

### Acceptance Criteria

- [ ] Code tối giản, tái dùng `HouseAdItem`/`_HouseAdSlot`, không tạo abstraction mới ngoài việc share 1 class nội bộ đã có.
- [ ] Không ảnh hưởng quyết định sản phẩm đã duyệt của owner.
- [ ] Widget test đủ case y hệt Banner: no-fill hiện house ad sau delay, dispose hủy timer, ad phục hồi trước delay không hiện house ad, tap gọi đúng `onTap`.
- [ ] `flutter analyze` sạch 0 cảnh báo; `flutter test` toàn bộ pass xanh; golden API cập nhật nếu constructor đổi signature công khai.

## Kết quả (2026-09-30)

**Verdict: DONE.** Xác minh claim trước khi sửa: `mrec_ad_widget.dart` đúng có 3
điểm `SizedBox.shrink()` ở dòng 461/492/525 (nay đã dịch dòng sau khi thêm
param), khớp mô tả ticket.

Triển khai: tái dùng `HouseAdItem` (import từ `banner_ad_widget.dart`, không
đổi vị trí khai báo). `_HouseAdSlot` (private, không thể import cross-file
trong Dart) được đổi tên public `HouseAdSlot`/`HouseAdSlotState` để
`MrecAdWidget` tái dùng trực tiếp — không tạo class/abstraction mới, chỉ mở
đủ để share. Để không rò rỉ 2 class này vào public API surface, barrel
(`lib/applovin_admob_sdk.dart`) export `banner_ad_widget.dart` với
`hide HouseAdSlot, HouseAdSlotState`. `MrecAdWidget.houseAd`/`houseAdDelay`
(cùng default `Duration(seconds: 10)`) là thay đổi API công khai duy nhất —
đã cập nhật `test/goldens/public_api_surface.txt` + CHANGELOG 3.4.0.

`_recordFlightRecorderVisibility` của MREC được gate y hệt T237's fix cho
Banner (`widget.houseAd != null && (!_allowed.value || mrecHasError)`) —
house-ad hiển thị không tạo entry `mrecVisible`/`mrecHidden` gắn provider tag
thật; ad thật vẫn ghi đúng tag (có test riêng cho cả 2 nhánh + trạng thái
recorder bật/tắt).

TDD: RED trước (test mới fail vì thiếu param/logic) → GREEN sau khi sửa.
`test/mrec_ad_widget_test.dart` thêm 2 group mới (~15 test case): no-fill/
offline quá delay hiện fallback, tap gọi đúng `onTap`, ad thật trước delay
hủy timer, ad thật phục hồi sau fallback gỡ fallback, dispose khi timer đang
chờ an toàn, pause/resume qua `active` không tạo timer trùng, VIP/consent-
blocked bán nhất quán với Banner, và cặp test Flight Recorder enabled/
disabled. `test/banner_ad_widget_test.dart` (48 test) chạy lại xanh toàn bộ
— không regress từ việc đổi `_HouseAdSlot` thành shared `HouseAdSlot`.

Integration: thêm demo section "T240 — House Ad fallback demo" vào
`example/lib/main.dart`'s `MrecDemoPage` (nút force-offline debug-seam,
`MrecAdWidget` cấu hình `houseAd`/`houseAdDelay: 2s`) và test mới trong
`example/integration_test/mrec_ad_test.dart` ép offline qua
`AdManager().debugConnectivityChanged` để buộc fallback hiện ra không cần ad
thật, verify render + tap + không crash.

`flutter analyze` sạch (root + example). Full `flutter test` (root package):
xem log chạy đầy đủ trong báo cáo cuối; không regress nào phát hiện ngoài
phạm vi T240.

## Kế hoạch kiểm thử

- Widget test: mirror `banner_ad_widget_test.dart`'s house-ad cases cho MREC.
- Unit: không cần — không có logic thuần ngoài tái dùng `_HouseAdSlot`.
- Integration: không cần thêm case mới ở tầng đó, cùng lý do T229 đã ghi (hành vi timer/dispose/tap không phụ thuộc platform channel thật).

## Prompt vòng lặp (Loop Prompt)

Triển khai task T240 theo quy trình TDD chuẩn:
1. Đọc kỹ T229 (`doc/task/done/T229-idea-offline-house-ad-fallback.md`) làm tham chiếu đúng pattern trước khi sửa MREC.
2. Viết test trước (Red-Green-Refactor) mirror đúng bộ case Banner đã có.
3. Sửa tối giản, share `_HouseAdSlot` giữa 2 widget nếu cần refactor nhỏ, không tạo class/abstraction mới ngoài việc share.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Audit lại toàn bộ code changes và chấm điểm /10.
   - Bổ sung widget test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
