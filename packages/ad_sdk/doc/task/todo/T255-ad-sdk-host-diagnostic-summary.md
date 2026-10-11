# T255 — Báo cáo chẩn đoán SDK một lần, không tự đổi provider

- **Loại:** Flagship idea (độc quyền)
- **Priority:** P2 · **Effort:** L
- **Confidence:** IDEA; các tín hiệu nền đã có, giá trị host chưa được xác thực
- **Status:** todo
- **Evidence:** `lib/src/monetization/ad_diagnostics.dart`, `fill_rate_baseline_monitor.dart`, `waterfall_tuner.dart`, `provider_failover_advisor.dart`, `revenue_integrity_ledger.dart`, `self_healing_observer.dart`; existing `test/*diagnostics*`, `test/*fill_rate*`, `test/waterfall_tuner_test.dart`
- **Dependencies:** product/use-case validation; preserve opt-in observer-only policy

## Ý tưởng & giá trị độc quyền

SDK có nhiều tín hiệu cục bộ riêng lẻ: integration diagnostics, fill-rate drift, waterfall recommendation, failover advice, revenue integrity và self-healing observation. Host phải tự nối chúng để biết “vì sao quảng cáo không chạy/thu nhập đổi?”. Ý tưởng: một `AdHealthReport` opt-in, snapshot/summary có severity, evidence, timestamp, confidence/unknowns và hành động gợi ý — không gửi mạng, không chuyển provider, không gọi ad request.

Đây là ý tưởng sản phẩm, chưa có bằng chứng host cần thêm facade. T143/T136/T146/T232 đã bao phủ provider selection/failover; task này không được xây lại arbitrator.

## Discovery gate trước code

- [ ] Đã chọn: validate host need trước; chưa được code report nếu chưa xác nhận use case.
- [ ] Xác nhận ít nhất một host/use case cần report tổng hợp thay vì API/module hiện tại.
- [ ] Map từng field về nguồn hiện hữu, freshness, privacy và ý nghĩa; không phát minh metric/claim uplift.
- [ ] Nếu chỉ gom getter không giảm công tích hợp, kết luận REFUTED.

## Acceptance criteria nếu qua gate

- [ ] Snapshot chỉ đọc, deterministic, opt-in; không side effect, network, shadow request, adapter switch hoặc ad load.
- [ ] Mỗi finding phân biệt `observed`, `inferred`, `unknown`; không gọi nghi vấn là fraud/lost revenue.
- [ ] Redaction và retention/privacy review; không lộ ad IDs, user identifiers hay raw consent payload ngoài contract.
- [ ] Unit: nguồn trống, tín hiệu stale, nhiều findings, severity order, contradictory/unknown signals.
- [ ] Widget test nếu có UI trong example; nếu report API thuần thì ghi N/A.
- [ ] Integration Android/iOS dùng fake/test provider chứng minh snapshot khớp event stream; không cần real ad impression để verify read-only report.
- [ ] Smoke test thiết bị tạo test events, xác nhận report không đổi provider/khởi tạo request mới.
- [ ] Public API policy, golden, changelog/docs và audit độc lập >9/10.

## Prompt vòng lặp

Bắt đầu bằng discovery gate T255; đọc các module và tasks T97/T98/T112/T127/T136/T143/T146/T232 để không tạo trùng. Hỏi user nếu product scope chưa rõ. Không code nếu chưa có use case thật. Nếu được duyệt, test chứng minh report thuần read-only, privacy-safe, stale/unknown signals rõ ràng và không gửi ad request. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke device; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.