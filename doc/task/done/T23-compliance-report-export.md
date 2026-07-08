# T23 — Compliance Report export (nền tảng cho "Trust & Analytics" layer)

- **REQ:** 6, 7 (consent mọi quốc gia đúng chuẩn; policy tuân thủ) + epic mới "Trust & Analytics" (xem `doc/task/README.md`)
- **Priority:** P1 · **Severity:** — (feature mới, không phải bug) · **Status:** todo
- **Nguồn:** quyết định user 2026-07-08, dựa trên `doc/audit/audit_gemini.md` (compliance gần như tuyệt đối → đóng gói thành sản phẩm)
- **Phụ thuộc:** không phụ thuộc task nào khác — làm trước, T24/T25 dùng chung event log của task này.
- **Files dự kiến:**
  - `packages/ad_sdk/lib/src/compliance/ad_event_log.dart` (mới) — ring buffer persist rolling window các `AdEvent` + safety-block reasons
  - `packages/ad_sdk/lib/src/compliance/compliance_report.dart` (mới) — model + generator
  - `packages/ad_sdk/lib/src/core/ad_manager.dart` — thêm `exportComplianceReport({DateTimeRange? range})`
  - `packages/ad_sdk/lib/src/utils/ad_preferences.dart` — nếu ring buffer cần persist qua Hive/SharedPreferences

## Vấn đề (Why)

Audit `doc/audit/audit_gemini.md` xác nhận SDK enforce đúng consent/ATT/COPPA/safety-cap ở mọi impression — nhưng **không có cách nào xuất bằng chứng đó ra ngoài**. Khi AdMob/AppLovin flag hoặc suspend account (rất phổ biến với solo dev/studio nhỏ, thường không rõ lý do), partner không có gì để đối chiếu/khiếu nại ngoài lời khai miệng "tôi có enforce cap mà".

`AdManager().events` (xem `ad_event.dart`) đã phát đúng các sự kiện (`AdLoadEvent`, `AdShowEvent`, `AdClickEvent`, `AdRewardEvent`, `AdRevenueEvent`) nhưng là **stream tức thời, không persist** — subscriber phải tự lắng nghe từ đầu session, không thể truy vấn lịch sử.

## Fix đề xuất

1. Thêm `AdEventLog` — ring buffer cap kích thước (ví dụ 5000 entry hoặc 30 ngày, cap theo cái đến trước), persist nhẹ (không cần Hive nếu SharedPreferences đủ — ping ponytail: ưu tiên tái dùng `AdPreferences` đã có thay vì thêm dependency mới). Subscribe vào `AdManager().events` nội bộ, ghi thêm timestamp.
2. Thêm `CompliancePeriodSnapshot` field: consent status hiện tại (GDPR/CCPA/COPPA/ATT) từ consent manager, safety-cap counters hiện tại, VIP-active state. `AdSafetyConfig.getStatus()` đã có (`ad_safety_config.dart:416`) nhưng chỉ trả 1 `String` debug format — **không parse string này**, thêm biến thể mới trả structured data (ví dụ `AdSafetyConfig.getStatusSnapshot()` trả `Map`/data class) dùng chung số liệu nội bộ đã có (`_fullscreenAdsShownInSession`, `_hourlyAdTimestamps.length`, daily count, CTR, violations) mà không đổi behavior `getStatus()` cũ.
3. `ComplianceReport.generate(range)` gộp `AdEventLog` (lọc theo range) + `CompliancePeriodSnapshot` thành 1 object `toJson()`-able. Không cần PDF ở version đầu (YAGNI) — JSON export đã đủ để partner tự dán vào email khiếu nại/dashboard riêng; export PDF để sau nếu partner thật sự cần.
4. `AdManager().exportComplianceReport({DateTimeRange? range})` — API public, trả `ComplianceReport`.

## Acceptance criteria
- [ ] `AdEventLog` ghi đúng mọi `AdEvent` phát ra qua `AdManager().events`, cap kích thước đúng, không leak memory (test bằng cách bắn > cap entry, verify độ dài ring buffer không vượt).
- [ ] `ComplianceReport.generate()` phản ánh đúng số liệu thật từ `AdSafetyConfig.getStatusSnapshot()` (mới) + consent manager tại thời điểm gọi.
- [ ] `exportComplianceReport()` hoạt động cả khi log rỗng (app mới cài) — không throw.
- [ ] Test mới cho `AdEventLog` (ring buffer) + `ComplianceReport.generate()` (mock event stream).
- [ ] `flutter analyze` sạch, test SDK xanh.
