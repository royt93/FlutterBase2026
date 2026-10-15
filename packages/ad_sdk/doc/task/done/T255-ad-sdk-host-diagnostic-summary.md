# T255 — Báo cáo chẩn đoán SDK một lần, không tự đổi provider

- **Loại:** Flagship idea (độc quyền)
- **Priority:** P2 · **Effort:** L
- **Confidence:** IDEA; các tín hiệu nền đã có, giá trị host chưa được xác thực
- **Status:** done (REFUTED: no concrete host need; README diagnostics docs corrected; independent audit 9.5/10)
- **Evidence:** `lib/src/monetization/ad_diagnostics.dart`, `fill_rate_baseline_monitor.dart`, `waterfall_tuner.dart`, `provider_failover_advisor.dart`, `revenue_integrity_ledger.dart`, `self_healing_observer.dart`; existing `test/*diagnostics*`, `test/*fill_rate*`, `test/waterfall_tuner_test.dart`
- **Dependencies:** product/use-case validation; preserve opt-in observer-only policy

## Ý tưởng & giá trị độc quyền

Ý tưởng ban đầu giả định host phải tự nối riêng integration diagnostics, fill-rate drift, waterfall recommendation, failover advice, revenue integrity và self-healing observation để giải thích ad/revenue changes. Discovery 2026-10-11 xác nhận `AdManager.diagnostics()` đã tổng hợp waterfall, fill rate, arbitrator, baseline regression và revenue-integrity signals; `exportSafeDiagnostics()` đã có redaction/bounds, còn self-healing observations đi qua `AdManager.events`/`AdEventLog`.

Vì vậy nhu cầu cho facade mới **chưa được xác thực** và nhiều phần trùng API hiện hữu. Chỉ tiếp tục nếu host/support use case chỉ ra một gap cụ thể mà API hiện tại không đáp ứng. T143/T136/T146/T232 đã bao phủ provider selection/failover; không xây lại arbitrator.

## Discovery gate trước code

- [x] Đã chọn: validate host need trước; chưa được code report nếu chưa xác nhận use case.
- [x] Discovery (2026-10-11): hiện tại **không có bằng chứng đủ để xây facade mới**. `AdManager.diagnostics()` đã tổng hợp waterfall, fill rate, arbitrator, baseline regression và revenue-integrity signals; `exportSafeDiagnostics()` đã cho export bounded, redacted, checksummed. Self-healing observations được emit vào `AdManager.events` và `AdEventLog` bounded/persisted.
- [x] Owner xác nhận không có host/support use case cụ thể ngoài các nhu cầu hiện có (2026-10-15).
- [x] Existing APIs already provide the aggregate signals and safe export described above.
- [x] Known gaps: no per-field freshness timestamp, severity, or observed/inferred/unknown labels; no host requested these capabilities.
- [x] REFUTED: no new facade/API without a concrete host need. This does not claim existing APIs fit every possible workflow.

Không code report/API vì không có bằng chứng host need.

## Acceptance criteria nếu qua gate

N/A — discovery gate không qua; không có code, public API, test hoặc smoke mới. Các mục dưới chỉ được áp dụng nếu task được mở lại với use case host cụ thể.

- [x] N/A: Snapshot chỉ đọc, deterministic, opt-in; không side effect, network, shadow request, adapter switch hoặc ad load.
- [x] N/A: Mỗi finding phân biệt `observed`, `inferred`, `unknown`; không gọi nghi vấn là fraud/lost revenue.
- [x] N/A: Redaction và retention/privacy review; không lộ ad IDs, user identifiers hay raw consent payload ngoài contract.
- [x] N/A: Unit: nguồn trống, tín hiệu stale, nhiều findings, severity order, contradictory/unknown signals.
- [x] N/A: Widget test nếu có UI trong example; nếu report API thuần thì ghi N/A.
- [x] N/A: Integration Android/iOS dùng fake/test provider chứng minh snapshot khớp event stream; không cần real ad impression để verify read-only report.
- [x] N/A: Smoke test thiết bị tạo test events, xác nhận report không đổi provider/khởi tạo request mới.
- [x] N/A: Public API policy, golden, changelog/docs — không đổi API/code.
- [x] Independent review of REFUTED conclusion: 9.5/10, no blocking findings.

## Prompt vòng lặp

Bắt đầu bằng discovery gate T255; đọc các module và tasks T97/T98/T112/T127/T136/T143/T146/T232 để không tạo trùng. Hỏi user nếu product scope chưa rõ. Không code nếu chưa có use case thật. Nếu được duyệt, test chứng minh report thuần read-only, privacy-safe, stale/unknown signals rõ ràng và không gửi ad request. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke device; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.