# T43 — ATT/UMP consent flow có thể treo vô thời hạn, chặn `initialize()` mãi mãi

- **REQ:** tự phát hiện khi debug hang trên iOS Simulator ở `consent_dialog_test.dart` (2026-07-15), người dùng chốt "Sửa luôn" qua `AskUserQuestion`
- **Priority:** P1 (hiếm khi xảy ra trên production nhưng khi xảy ra thì app không quảng cáo được cho tới khi user tự mở lại app) · **Status:** ✅ done (2026-07-15)
- **Files:** `packages/ad_sdk/lib/src/core/att_consent.dart`, `packages/ad_sdk/lib/src/core/ump_consent.dart`, `packages/ad_sdk/test/att_consent_test.dart`, `packages/ad_sdk/test/ump_consent_test.dart`, `packages/ad_sdk/example/lib/main.dart` (thêm cờ test `SKIP_UMP`)

## Vấn đề (Why)
`requestAttIfNeeded()` và `requestUmpConsentFlow()` đều `await` một callback native (dismiss dialog ATT, dismiss form UMP, hoặc phản hồi mạng `requestConsentInfoUpdate`) **không có timeout**. App mẫu gọi tuần tự ATT → UMP → `AdManager().initialize()` trong splash. Nếu OS/native side không bao giờ resolve callback đó (ATT prompt bị Apple throttle sau nhiều lần mở app liên tiếp; form UMP được hiển thị thật nhưng không ai bấm qua trên Simulator không có script tự động; mạng chậm/chết khi gọi `requestConsentInfoUpdate`), cả chuỗi `initialize()` không bao giờ chạy — SDK quảng cáo bị "đơ" vĩnh viễn cho phiên app đó, không có lỗi/crash nào hiển thị ra ngoài. Phát hiện được khi `consent_dialog_test.dart` treo 4 lần liên tiếp trên iOS Simulator; đọc thẳng source mới lần ra 3 điểm `await` không có giới hạn thời gian.

## Giải pháp đã chọn
Bọc từng `await` rủi ro bằng `Future.timeout(Duration(seconds: 20), onTimeout: () => <giá trị an toàn>)` — mirror đúng pattern watchdog 90s đã có sẵn cho App-Open ad (`applovin_adapter.dart`/`admob_adapter.dart`), chỉ khác là dùng combinator có sẵn của Dart thay vì Timer thủ công (vì đây là các lệnh `await` tuần tự đơn giản, không phải state machine của ad slot):

- `att_consent.dart` — `requestAuthorization().timeout(20s, onTimeout: () => TrackingStatus.notDetermined)`.
- `ump_consent.dart` — hai chỗ: `dismissCompleter.future.timeout(20s, ...)` (form dismiss — nguyên nhân gốc của hang) và `updateCompleter.future.timeout(20s, ...)` (mạng, thêm chủ động cùng lớp rủi ro).
- Cố tình **không** đụng vào `requestPrivacyOptionsFlow()` — đây là hành động user tự bấm "Cài đặt riêng tư" sau khi app đã khởi động xong, nằm ngoài chuỗi gating của splash, ngoài phạm vi đã duyệt.
- Thêm cờ dart-define `SKIP_UMP` vào app mẫu (tương tự `SKIP_ATT`/`SKIP_SPLASH_AD` đã có) để test tự động có thể bỏ qua bước UMP thật khi cần.

## Acceptance criteria
- [x] Prompt ATT không bao giờ resolve → sau 20s vẫn trả về `notDetermined`, không hang.
- [x] Form UMP không bao giờ dismiss → sau 20s vẫn trả về kết quả kèm `error` mô tả timeout, không hang.
- [x] `requestConsentInfoUpdate` không phản hồi (mạng chết) → sau 20s vẫn fallback đọc trạng thái cache hiện có, không hang.
- [x] Có test xác nhận riêng cho nhánh ATT (`fakeAsync` + `Completer` không bao giờ complete trong `att_consent_test.dart`).
- [x] Có test xác nhận riêng cho nhánh UMP (`requestConsentInfoUpdate` — guard `updateCompleter`), thêm 2026-07-15 trong `ump_consent_test.dart`: mock trực tiếp `MethodChannel('plugins.flutter.io/google_mobile_ads/ump', StandardMethodCodec(UserMessagingCodec()))` (phải dùng đúng codec tùy biến của plugin, nếu không request bị "Message corrupted" trước khi tới handler) trả về `Completer` không bao giờ complete cho method `ConsentInformation#requestConsentInfoUpdate`, bọc trong `fakeAsync` + `elapse(20s)`, assert kết quả trả về có `error` chứa "timed out" thay vì hang. Nhánh `dismissCompleter` (form dismiss) vẫn chưa có test riêng — muốn giả lập cần dựng một `ConsentForm` thật qua codec tùy biến (`loadConsentForm`), phức tạp hơn hẳn; rủi ro còn lại được coi là chấp nhận được vì cùng cơ chế `Future.timeout` đã được test ở 2 nhánh khác.

## Verify
`cd packages/ad_sdk && flutter test` → 553/553 pass (gồm test timeout ATT trong `att_consent_test.dart` + test timeout UMP mới trong `ump_consent_test.dart`). `flutter analyze` ở cả `packages/ad_sdk` và repo root → no issues found.
