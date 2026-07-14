# T40 — AppLovin vẫn init cho age-restricted/child user (chỉ log warning, không chặn)

- **REQ:** ngoài phạm vi 7 yêu cầu gốc — phát hiện từ `doc/audit/audit_codex.md` (2026-07-13)
- **Priority:** P0-theo-codex nhưng **LOW urgency thực tế** (app hiện tại — WiFi stress tester — không child-directed) · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/lib/src/core/ad_provider_adapter.dart`, `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart`, `packages/ad_sdk/lib/src/adapters/admob_adapter.dart`, `packages/ad_sdk/lib/src/core/ad_consent.dart`, `packages/ad_sdk/lib/src/core/ad_manager.dart`, `packages/ad_sdk/test/applovin_adapter_test.dart`

## Vấn đề (Why)
`audit_codex.md` chỉ ra: khi `AdConsent.isAgeRestrictedUser == true`, code hiện tại chỉ **log một warning** rồi vẫn tiếp tục init AppLovin bình thường — không có gate nào thực sự chặn. AppLovin (và luật COPPA/Families nói chung) yêu cầu **không được** init SDK quảng cáo cho user được xác định là trẻ em, trừ khi dùng flow certified riêng cho child-directed. Với app hiện tại (WiFi stress tester, không nhắm tới trẻ em, không khai báo Families) rủi ro thực tế thấp — nhưng nếu SDK này được tái sử dụng cho một app khác có audience hỗn hợp/child-directed, đây sẽ là vi phạm chính sách thật.

## Giải pháp đã chọn
- Thêm `isAgeRestrictedUser` (default `false`) vào interface `AdProviderAdapter.initialize()`. `AppLovinAdapter.initialize()` check flag này **trước cả khi wiring listener** — nếu `true` thì abort ngay, không gọi native bridge, set `_disabledForChildUser = true` (getter `disabledForChildUser` mới), trả về `false` (giống một init failure thông thường — mọi ad surface AppLovin không dùng được cho session đó). `AdMobAdapter` nhận flag nhưng bỏ qua có chủ đích (COPPA đã xử lý qua `tagForChildDirectedTreatment` mỗi request, không cần gate ở init).
- `AdManager.initialize()` đổi thứ tự: bootstrap `ConsentManager` (load consent đã lưu từ session trước) **trước** khi chọn/init adapter — trước đây bootstrap xảy ra SAU khi adapter đã init xong, nên flag `isAgeRestrictedUser` từ session trước không bao giờ tới được gate. Giờ `adapter.initialize(config, deviceGaid: ..., isAgeRestrictedUser: _consent.isAgeRestrictedUser)` nhận đúng giá trị đã persist.
- Comment trong `ad_consent.dart`'s warning branch (khi consent đổi giữa session, AppLovin đã init rồi) được làm rõ: đây chỉ là fallback cho trường hợp mid-session, không phải gate chính (gate chính là ở init time, T40).
- **Không làm** (cân nhắc nhưng scope out theo YAGNI): field `AdConfig.audienceMode` để host app khai báo tường minh "app này luôn child-directed". Không cần thiết cho app hiện tại; nếu SDK dùng cho app child-directed từ lần cài đầu tiên (chưa có consent dialog nào chạy), gap này vẫn còn — xem "Known limitation" dưới.

## Known limitation (chưa fix, ghi nhận có chủ đích)
Lần cài đầu tiên (install #1) chưa có consent nào được lưu → `_consent.isAgeRestrictedUser` mặc định `false` → AppLovin vẫn init. Gate hiện tại chỉ bảo vệ đúng trường hợp "flag được set thành `true` sau đó" (qua dialog/consent flow), KHÔNG bảo vệ trường hợp "app luôn luôn child-directed, không có consent flow nào cả". App hiện tại (WiFi stress tester) không thuộc trường hợp này nên chấp nhận được — phải bổ sung field cấu hình tường minh trước khi tái sử dụng SDK cho app child-directed ngay từ đầu.

## Acceptance criteria
- [x] Khi `isAgeRestrictedUser == true`, AppLovin **không** được init (không chỉ log).
- [x] Có test xác nhận adapter bị skip init trong trường hợp này — `applovin_adapter_test.dart` group "COPPA child-user init gate (T40)".
- [x] Ghi chú trong `doc/feature.md`: app hiện tại không child-directed nên mức khẩn cấp thấp, nhưng bắt buộc xử lý trước khi SDK dùng cho app có audience khác + known limitation ở trên.

## Verify
`cd packages/ad_sdk && flutter test` → 548/548 pass (bao gồm test mới). `flutter analyze` → no issues.
