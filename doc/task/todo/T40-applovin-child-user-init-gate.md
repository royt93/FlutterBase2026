# T40 — AppLovin vẫn init cho age-restricted/child user (chỉ log warning, không chặn)

- **REQ:** ngoài phạm vi 7 yêu cầu gốc — phát hiện từ `doc/audit/audit_codex.md` (2026-07-13)
- **Priority:** P0-theo-codex nhưng **LOW urgency thực tế** (app hiện tại — WiFi stress tester — không child-directed) · **Status:** 📋 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_consent.dart:75-89`, `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:116-140`

## Vấn đề (Why)
`audit_codex.md` chỉ ra: khi `AdConsent.isAgeRestrictedUser == true`, code hiện tại chỉ **log một warning** rồi vẫn tiếp tục init AppLovin bình thường — không có gate nào thực sự chặn. AppLovin (và luật COPPA/Families nói chung) yêu cầu **không được** init SDK quảng cáo cho user được xác định là trẻ em, trừ khi dùng flow certified riêng cho child-directed. Với app hiện tại (WiFi stress tester, không nhắm tới trẻ em, không khai báo Families) rủi ro thực tế thấp — nhưng nếu SDK này được tái sử dụng cho một app khác có audience hỗn hợp/child-directed, đây sẽ là vi phạm chính sách thật.

## Giải pháp đề xuất
- Thêm gate thật sự (không chỉ log) trong `applovin_adapter.dart` trước dòng init: nếu `AdConsent.isAgeRestrictedUser == true` → skip init, expose trạng thái "adapter disabled for child user" ra ngoài (tương tự cách VIP suy giảm ad surface).
- Cân nhắc thêm cấu hình rõ ràng ở `AdConfig` (ví dụ `audienceMode` hoặc field tương tự) để host app khai báo chủ đích, thay vì suy luận ngầm từ 1 flag.

## Acceptance criteria
- [ ] Khi `isAgeRestrictedUser == true`, AppLovin **không** được init (không chỉ log).
- [ ] Có test xác nhận adapter bị skip init trong trường hợp này.
- [ ] Ghi chú trong `doc/feature.md`/README: app hiện tại không child-directed nên mức khẩn cấp thấp, nhưng bắt buộc xử lý trước khi SDK dùng cho app có audience khác.
