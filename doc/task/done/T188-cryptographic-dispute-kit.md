# T188 — Bộ tạo bằng chứng khiếu nại đòi tiền quảng cáo — ĐÃ CÓ SẴN, KHÔNG CẦN LÀM

**Loại:** exclusive-feature
**Trạng thái:** đóng — trùng với tính năng đã có (T144), không cần code thêm
**Đóng ngày:** 2026-09-08, phát hiện lúc bắt đầu triển khai (viết widget test mới thì đụng phải test có sẵn của T144)

## Sửa sai audit
Bản audit ban đầu (7 subagent nội bộ + codex + agy) đề xuất tính năng này như "ý tưởng lớn, chưa có" — nhưng đây là **lỗi bỏ sót**, không phải ý tưởng mới. SDK đã có sẵn ĐẦY ĐỦ đúng tính năng này từ T144 (trước cả đợt audit này):

- `AdManager().exportDisputeKit()` (`lib/src/core/ad_manager.dart:64` — class `DisputeKit`, gồm 3 phần ký Ed25519: compliance report + bypass audit trail + incident bundle).
- `AdManager().exportSignedIncidentBundle()` — export riêng phần incident, cùng cơ chế ký `compliance_signing.dart`.
- **T145 (RevenueIntegrityLedger) đã tự động ghi incident vào đúng `incidentRecorder` này** (`revenue_integrity_ledger.dart:90` gọi `AdManager().incidentRecorder.record(...)`) — nghĩa là dữ liệu "thất thoát tiền quảng cáo" ĐÃ chảy vào dispute kit tự động, không cần nối thêm gì.
- Demo có sẵn: `ComplianceDemoPage` trong `example/lib/main.dart`, nút "Generate dispute kit (T144)", test tại `example/test/compliance_demo_page_test.dart`.
- README đã document tại `packages/ad_sdk/README.md:1306`.

## Bài học
Đây đúng loại lỗi mà memory dự án đã cảnh báo trước ("Audit phải chậm và adversarial... luôn cần tự verify bằng cách đọc source + trace toàn bộ call site trước khi tin bất kỳ finding 'mới' nào"). 7 nguồn audit độc lập (bao gồm cả tôi) đều bỏ sót vì chỉ nhìn tên "exclusive-feature đề xuất" từ agy mà không tự grep xem đã tồn tại chưa trước khi đưa vào backlog.

## Việc còn lại (nếu có)
Không có việc code nào cần làm. Nếu muốn, có thể xem lại 1 lần: `IncidentRecorder`/`exportDisputeKit` có phơi bày rõ trong README mục "Public API" (memory dự án có nhắc round-42 MINOR: "~15 class public opt-in chưa có tên trong README", có thể `IncidentRecorder`/`BypassAuditTrail` nằm trong nhóm đó) — nhưng đó là việc tài liệu nhỏ, không phải việc code, không đáng tách task riêng.
