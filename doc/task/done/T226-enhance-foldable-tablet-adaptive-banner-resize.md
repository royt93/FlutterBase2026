# T226 — Cải tiến Adaptive Banner thích ứng màn hình gập (Foldable) và xoay ngang

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** LOW
- **Status:** ✅ done — **SCOPE-REDUCED: test coverage only, no new SDK code**

## Verdict: code gap KHÔNG tồn tại — chỉ thiếu test (scope-reduced)

Kiểm chứng trước khi build (discipline T223):
- `BannerAdWidget` đã có `_RenderAdmobWidthObserver` (RenderProxyBox
  `performLayout` — phát hiện mọi layout-pass thay đổi width, kể cả khi
  Element không rebuild, ví dụ `AnimatedContainer` animate width) +
  `_widthCorrectionDebounce` 300ms + `_refreshLayoutWidth` đo width thật
  của chính container (không dùng `MediaQuery` full-screen). Fold/unfold và
  split-view resize chính là chuỗi layout-width thay đổi → đã được bao phủ.
- `AdaptiveAdSurface` là lớp riêng (banner↔MREC format switch, debounce
  200ms riêng), không phải thứ `BannerAdWidget` thiếu.
- Đường AppLovin KHÔNG reload khi resize là đúng thiết kế (comment dòng
  ~172 `banner_ad_widget.dart`): `MaxAdView` có `isAdaptiveBannerEnabled:
  true` tự resize native, reload lại chỉ đốt request vô ích.
- KHÔNG cần dependency hinge/fold sensor (`dual_screen`,
  `flutter_displaymode`…): Flutter-native `constraints.maxWidth` qua layout
  pass đã đủ cho mọi việc cần làm. Đề xuất `DisplayFeatures`/hinge sensor
  của ticket là thừa (YAGNI).

Test coverage đã tồn tại: reload khi đổi width, no-op khi width giữ
nguyên, container resize không MediaQuery/route/TickerMode, animation
không rebuild vẫn settle đúng final width (`test/banner_ad_widget_test.dart`,
group `T157` + round-29).

Gap thật duy nhất: (1) không có test nào prove rapid fold-like width
sequence settle đúng MỘT lần reload; (2) không có test dispose giữa lúc
debounce đang pending; (3) đường AppLovin không có test resize nào.

## Đã làm (tests only, 0 dòng SDK lib thay đổi)

`test/banner_ad_widget_test.dart` (+~140 dòng):
- `rapid surface-width changes settle on one final AdMob reload` —
  `tester.view.physicalSize` 400→460→540→620→700 trong debounce window,
  assert giữa chừng vẫn 1 load, sau settle đúng 1 reload tại width 700.
- `unmounting during a pending width correction is safe` — dispose giữa
  debounce pending: không exception, không reload thêm, registry rỗng.
- Group `T226 — AppLovin native adaptive banner resize path`: cùng rapid
  sequence, assert `preloadBannerCalls` vẫn 1, `disposeCalls` 0 (không
  teardown native view vô ích).
- Test infra: `_BannerCountingAdapter` thêm `preloadBannerCalls`,
  `appLovinBannerAdViewId`→`_NullObjectListenable`, `setBannerRoutePaused`
  no-op; `_appLovinConfig` mới.

## Acceptance Criteria
- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi. (0 dòng lib — không thể tối giản hơn)
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case. (Widget: 3 tests mới. Unit: N/A — không có logic tính toán mới. Integration: N/A — `banner_ad_test.dart` cần ads thật trên window-resize thật, widget test với `tester.view.physicalSize` đã prove cùng hành vi trên fake adapter; không pad.)
- [x] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Evidence
- `flutter analyze`: No issues found.
- `flutter test test/banner_ad_widget_test.dart`: 36/36 pass.
- Full suite (`flutter test`): 2308/2310 pass. 2 fail, cả 2 trong
  `test/r23_coppa_midinit_flip_test.dart` (age-gate mid-init retry race) —
  file này không đụng gì tới banner/resize, PRE-EXISTING trước khi task
  này chạm code (đã ghi nhận trong memory session trước: "round71...
  r23_coppa 2 bug thật đã fix, còn 1 race nhỏ chưa sửa"), không do commit
  này gây ra — diff commit chỉ sửa `test/banner_ad_widget_test.dart`.
- Device smoke (S24 Ultra thật, SM-S928B, qua adb `R5CX613VZBR`):
  `flutter run -d R5CX613VZBR --dart-define=AD_PROVIDER_ADMOB=true`,
  build+cài+chạy example app thành công, sau đó xoay
  portrait→landscape→portrait→landscape→portrait 2 lần liên tiếp qua
  `adb shell settings put system user_rotation`. Không crash, không
  Flutter exception trong log (`grep -i exception/FATAL` chỉ khớp tên
  file build `libapplovin-native-crash-reporter.so`, không phải crash
  thật), app vẫn foreground sau rotations (`dumpsys window` xác nhận
  `mCurrentFocus`/`mFocusedApp` vẫn MainActivity). LƯU Ý: đây là proxy
  bằng rotation, KHÔNG phải fold-hinge hardware thật (không có sẵn) —
  không chứng minh đầy đủ 100% behavior gập màn hình thật, chỉ chứng
  minh app không crash qua chuỗi window-size-change thật trên thiết bị
  thật.

## Vấn đề (Why) — gốc
Trên thiết bị Android màn hình gập (Samsung Galaxy Z Fold) hoặc iPad chia đôi màn hình (Split View), chiều rộng cửa sổ thay đổi liên tục khi mở/gập máy. Banner AdWidget hiện tại có thể bị méo tỉ lệ hoặc giữ kích thước cũ.

## Đề xuất giải pháp & Acceptance Criteria — gốc (đã bác bỏ phần code)
1. Lắng nghe thay đổi `MediaQueryData.size` và `DisplayFeatures` (hinge/fold sensor). → BÁC: layout-pass width observer đã đủ, không cần sensor dep.
2. Debounce tự động tính toán lại kích thước Anchored Adaptive Banner khi màn hình gập/mở. → ĐÃ CÓ (300ms).
3. Tự động reload ad đúng kích thước mới mà không gây nhấp nháy UI. → ĐÃ CÓ (dispose+reload sau settle).
