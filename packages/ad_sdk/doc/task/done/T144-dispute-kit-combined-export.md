# T144 — Độc quyền: Combined dispute kit export (đóng gói 3 signed export đã có)

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P3 (đã giảm từ P2 gốc — hạ tầng chính đã có sẵn, xem dưới)
- **Status:** 🔲 todo
- **Effort:** S (đã giảm từ L gốc — KHÔNG phải xây từ đầu)
- **Files (dự kiến):** `lib/src/core/ad_manager.dart` (dòng ~1014-1062, nơi
  `exportSignedComplianceReport`/`exportSignedBypassAuditTrail` đã có),
  `lib/src/compliance/incident_recorder.dart` (dòng 171, `signIncidentBundle`
  đã có nhưng chưa nối vào `AdManager`)
- **Nguồn gợi ý:** agy (đã điều chỉnh scope sau khi tự verify code thật)
- **Dependency:** không có

## ⚠️ Đã tự verify: phần lớn tính năng NÀY ĐÃ CÓ SẴN, không phải xây mới

Brainstorm gốc ("idea #23 — Realtime Account Safety Shield + dispute kit")
đề xuất như 1 tính năng hoàn toàn mới. Đọc code thật cho thấy **2/3 phần đã
được implement sẵn**:

- `AdManager().exportSignedComplianceReport({from, to})` — đã có
  (`ad_manager.dart:1058-1062`), doc comment còn ghi rõ **"tamper-evidence
  for a dispute appeal"** — đúng chính xác mục đích brainstorm đề xuất.
- `AdManager().exportSignedBypassAuditTrail()` — đã có
  (`ad_manager.dart:1021-1022`), ký qua `signBypassAuditTrail()` có sẵn
  trong `bypass_audit_trail.dart:98`.
- `signIncidentBundle(IncidentBundle)` — hàm ký **đã tồn tại**
  (`incident_recorder.dart:171`), nhưng **KHÔNG có method tiện lợi nào trên
  `AdManager`** để lấy `IncidentBundle` hiện tại rồi ký (khác 2 cái trên).

**Gap thật duy nhất:** (1) thiếu `AdManager().exportSignedIncidentBundle()`
tương tự 2 method kia; (2) không có 1 API "xuất TẤT CẢ 3 thứ cùng lúc"
thành 1 artifact duy nhất cho host nộp 1 lần khi kháng cáo — hiện host phải
tự gọi 3 method riêng rồi tự gộp.

## Việc cần làm

- [ ] Verify `AdManager` có field/cách truy cập `IncidentRecorder` instance
      hiện tại không (tương tự `bypassAuditTrail` field ở dòng 1015) — nếu
      chưa có, thêm field tương tự.
- [ ] Thêm `AdManager().exportSignedIncidentBundle()` — mirror đúng pattern
      2 method đã có.
- [ ] Thêm `AdManager().exportDisputeKit({from, to})` — gọi cả 3 method
      trên, gộp thành 1 object/JSON duy nhất (`DisputeKit { compliance,
      bypassAuditTrail, incidentBundle }`), tất cả đã ký sẵn từng phần.
- [ ] Demo trong example app (thêm nút vào `ComplianceDemoPage` hiện có,
      không cần trang mới).
- [ ] Unit test cho `exportDisputeKit` — verify cả 3 phần có mặt và verify
      lại được bằng các hàm `verifySigned*` đã có.

## Ghi chú

Effort giảm từ L→S sau khi tự verify — đây là ví dụ tốt cho việc PHẢI đọc
code thật trước khi ước lượng effort từ brainstorm, không tin nguyên văn.
Rủi ro thấp vì chỉ gộp API đã có, không thiết kế cơ chế ký/redaction mới.

## Kết quả (2026-09-07) — DONE

- **Status:** ✅ done. **Điểm: 9.4/10** (1 vòng review độc lập `codex`,
  PUSH ngay).
- Đúng scope: chỉ gộp 3 API có sẵn — `exportSignedComplianceReport`,
  `exportSignedBypassAuditTrail`, `signIncidentBundle` (qua `incidentRecorder`
  field mới, không reset khi `destroy()`, giống `bypassAuditTrail`). `DisputeKit`
  class + `exportSignedIncidentBundle()`/`exportDisputeKit({from, to})` —
  không tự viết logic ký/verify/redaction mới.
- Demo thêm nút trong `ComplianceDemoPage` (không trang mới, đúng ticket).
- **Tự bắt được 1 bug trong WIDGET TEST (không phải code production)**:
  gọi `exportDisputeKit()` (ký Ed25519 thật qua `package:cryptography`) qua
  nút bấm trong `testWidgets()` ban đầu HANG VÔ THỜI HẠN — `flutter_test`'s
  fake-async pump loop không cho crypto/isolate work thật hoàn tất. Sửa
  bằng `tester.runAsync()` bọc CẢ `tester.tap()` và 1 `Future.delayed`
  THẬT (200ms, không phải `Duration.zero`) bên trong.
- 1 finding P3/minor từ review: thiếu `if (!mounted) return;` sau await
  trong demo — đã sửa (chỉ ảnh hưởng example UI, không phải API production).
- Baseline: `flutter analyze` sạch (cả `ad_sdk` và `example`); `flutter
  test` 1736/1736 (`ad_sdk`) + 33/33 (`example`); integration test
  `t144_dispute_kit_test.dart` pass thật trên iOS Simulator (Samsung Galaxy
  S24 Ultra mất kết nối wireless giữa session, dùng simulator thay thế).

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T144-dispute-kit-combined-export.md này (nếu đã
chuyển inprogress/done thì đọc ở đó). Implement ĐÚNG scope "Việc cần làm" —
KHÔNG thêm scope ngoài mô tả, ĐẶC BIỆT không tự viết lại cơ chế ký mới, chỉ
gộp 3 API đã có.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có, không tự dựng server/API mới. Nếu ticket
này có vẻ cần backend, dừng lại hỏi user trước khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp: sửa → audit adversarial (codex/agy độc lập trong bản copy cô lập /tmp,
rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R nguyên khối) → nếu
≤9/10 sửa tiếp → verify lại → lặp tới ≥9/10 mới push. KHÔNG tự ý push nếu
chưa đạt ngưỡng. Di chuyển ticket từ todo/ → inprogress/ khi bắt đầu, →
done/ khi xong.
```
