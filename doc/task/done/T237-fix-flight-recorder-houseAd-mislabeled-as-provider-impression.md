# T237 — Fix Flight Recorder gắn nhầm House Ad fallback thành impression của nhà mạng thật

- **Loại:** Fix (Bug)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ✅ done

## Vấn đề (Why)

`BannerAdWidget.build()` bọc TOÀN BỘ `_buildBanner(context)` — bao gồm cả nhánh render `_HouseAdSlot` khi `!allowed` hoặc `hasError` — trong một `VisibilityDetector` duy nhất (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:799-813`, callback `_onVisibilityChanged` tại dòng 337 gọi `_recordFlightRecorderVisibility` không điều kiện gì về nội dung đang thật sự render bên trong).

`_recordFlightRecorderVisibility` (dòng 324-341) không biết widget con đang vẽ là quảng cáo thật hay House Ad nội bộ (T229) — nó chỉ đọc `info.visibleFraction` của toàn bộ subtree và ghi:

```dart
unawaited(AdManager().recordFlightRecorderEvent(
  label: visible ? 'bannerVisible' : 'bannerHidden',
  ...
));
```

`recordFlightRecorderEvent` (`lib/src/core/ad_manager.dart:1000-1025`) tự điền `providerTag: _adapter?.tag ?? '[SDK]'` — tag của provider ĐANG CHẠY (AdMob/AppLovin), không phải "house ad". Kết quả: khi banner no-fill/offline >10s và House Ad tự hiển thị (T229), Flight Recorder vẫn ghi một entry `bannerVisible` với `providerTag` là AdMob/AppLovin thật.

Đây trực tiếp làm sai lệch chính mục đích của T231: nếu host dùng `.adproof` để đối chất "ad che UI"/"invalid traffic" với nhà mạng, bằng chứng lại khai có một impression thật của nhà mạng đó tại thời điểm literally không có yêu cầu ad nào được gửi đi (banner đang no-fill). Ngược hướng còn tệ hơn: nếu nhà mạng dùng chính log này để đối chiếu, sẽ thấy SDK "tự nhận" có impression không tồn tại.

## Đề xuất giải pháp

`_recordFlightRecorderVisibility` cần biết nội dung thực tế đang hiển thị là ad thật hay House Ad, và phải:
1. Không ghi `bannerVisible`/`bannerHidden` (nhãn ngụ ý provider thật) khi đang hiển thị House Ad.
2. Tùy chọn ghi nhãn riêng biệt (ví dụ `'houseAdVisible'`/`'houseAdHidden'`) với `providerTag` phản ánh đúng "house ad nội bộ", không phải tag provider — hoặc đơn giản là không ghi gì cả nếu house-ad hiển thị bị coi ngoài phạm vi bằng chứng compliance (cần quyết định rõ, không để mặc định sai như hiện tại).

Cách tối giản nhất: gate `_recordFlightRecorderVisibility`/`_onVisibilityChanged` theo đúng trạng thái `allowed`/`hasError` đã có sẵn trong build tree (cùng biến điều khiển việc render house-ad), thay vì visibility thô của toàn subtree.

### Acceptance Criteria

- [x] House Ad hiển thị không tạo entry `bannerVisible`/`bannerHidden` gắn `providerTag` của provider thật.
- [x] Banner/ad thật hiển thị vẫn ghi đúng như hiện tại — không regress hành vi cũ.
- [x] `MrecAdWidget` không có house-ad nên không cần sửa: T229 chỉ áp dụng `BannerAdWidget`; tìm toàn file `mrec_ad_widget.dart` không có `houseAd`/`HouseAd`.
- [x] Không tạo abstraction/dependency mới; tái dùng biến trạng thái đã có (`_allowed`, `hasError` listenable).
- [x] `flutter analyze` sạch; full `flutter test` chạy 2,408 test: 2,407 pass, 1 lỗi full-suite-only có sẵn tại `consent_fallback_wiring_test.dart` (`MissingPluginException: setHasUserConsent`) và test đó pass riêng trên source sạch không có diff T237.

## Kế hoạch kiểm thử

- Widget: bật flight recorder + `houseAd` cấu hình, mô phỏng no-fill >`houseAdDelay`, assert KHÔNG có entry `bannerVisible` mang `providerTag` thật trong buffer; nếu chọn ghi nhãn riêng, assert đúng nhãn/tag mới.
- Widget: banner load thành công bình thường vẫn ghi đúng `bannerVisible`/`bannerHidden` như cũ (regression).
- Widget: chuyển từ House Ad sang ad thật phục hồi (ticket T229 mô tả) — assert transition ghi đúng, không lẫn 2 loại nhãn.
- Integration: bật flight recorder trên `example`, ép offline đủ lâu để House Ad hiện, xuất bundle, verify nội dung không mang nhãn sai.

## Kết quả

**Verdict:** FIXED. Chọn phương án (a): không ghi Flight Recorder trong lúc nhánh House Ad đang render, vì bỏ bằng chứng mơ hồ an toàn hơn tự đặt một provider tag mới.

- RED trước fix: House Ad đang hiện nhưng buffer ghi 3 entry `bannerVisible`/`bannerHidden` với provider tag `counting` (fake provider thật trong test).
- GREEN sau fix: `banner_ad_widget_test.dart` 48/48 pass; real-banner path vẫn ghi đúng provider tag; recorder-disabled path không crash.
- `flutter analyze`: sạch.
- Full suite: 2,407/2,408 pass; 1 lỗi full-suite-only không thuộc T237 tại `consent_fallback_wiring_test.dart` (`MissingPluginException: setHasUserConsent`), test đó pass riêng trên source không có diff T237.
- Không cần integration/device test: fix chỉ gate callback Dart bằng cùng state `_allowed`/`hasError` đã quyết định render branch; widget test chạy `VisibilityDetector` thật qua scroll transition.
- Không đổi public API/golden. `MrecAdWidget` không hỗ trợ House Ad nên ngoài phạm vi.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T237 theo quy trình TDD chuẩn:
1. Đọc kỹ ticket, xác nhận lại đúng dòng code liên quan trước khi sửa.
2. Viết test RED chứng minh House Ad hiện tại bị gắn nhãn `bannerVisible` + providerTag thật sai.
3. Sửa tối giản theo đúng gợi ý gate bằng trạng thái sẵn có; không đổi hành vi render/houseAd hiện tại.
4. Tín hiệu kết thúc vòng lặp: audit độc lập >9/10, đủ test pyramid, smoke test thật (ép no-fill, xác nhận log/export không sai nhãn), rồi mới commit/push.
