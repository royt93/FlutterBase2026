# T146 — Độc quyền: Privacy-safe cohort optimizer (chọn provider cho install kế tiếp)

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P3
- **Status:** 🔲 todo
- **Effort:** XL
- **Files (dự kiến):** `lib/src/compliance/compliance_signing.dart`
  (`signJsonPayload`/`verifySignedJsonPayload` đã có, dòng ~166-185 — TÁI
  DÙNG, không viết cơ chế ký mới), file mới
  `lib/src/monetization/cohort_optimizer.dart`
- **Nguồn gợi ý:** codex
- **Dependency:** khuyến nghị làm SAU T136 (cùng triết lý session-alternate,
  tránh thiết kế trùng lặp 2 cơ chế thử-nghiệm khác nhau) — không bắt buộc
  cứng nhưng nên xem lại T136 trước khi thiết kế.

## ⚠️ Lưu ý phạm vi — khác T143, khả thi với kiến trúc hiện tại

Ý tưởng gốc dễ bị hiểu nhầm giống T143 (runtime failover — vướng giới hạn
kiến trúc single-provider-per-install, xem T143). **T146 KHÔNG cần runtime
switch** — phạm vi thật là: SDK tự ghi nhận (ký + lưu local) kết quả
provider hiện tại của CHÍNH install đó qua các session, rồi cung cấp 1 API
"gợi ý provider cho lần init TIẾP THEO" (host tự đọc gợi ý này TRƯỚC khi
gọi `initialize()`, tự quyết định có nghe theo không) — không phải SDK tự
đổi adapter giữa chừng. Vì vậy khả thi với kiến trúc `AdConfig` hiện tại
(vẫn chỉ 1 provider/lần init, chỉ khác ở CHỌN provider nào thông minh hơn).

**Không phải cross-install thật** — vì không có server tổng hợp dữ liệu
NHIỀU install khác nhau, đây chỉ là tối ưu cho CHÍNH 1 install qua các lần
mở app/session của riêng nó.

## Việc cần làm

- [ ] Thiết kế `CohortOptimizer` — ghi nhận mỗi session: provider đã dùng +
      metric quan sát được (fill rate/eCPM tổng hợp từ `AdEventLog`/
      `AdRevenueEvent` đã có).
- [ ] Ký bản ghi bằng `signJsonPayload()` đã có sẵn
      (`compliance_signing.dart:166`), lưu local (SharedPreferences hoặc
      file, tương tự pattern VIP đã lưu key). Verify lại bằng
      `verifySignedJsonPayload()` khi đọc lại (chống app khác/tiến trình
      khác chỉnh sửa file ngoài ý muốn).
- [ ] API `CohortOptimizer.recommendedProviderForNextInit()` — trả về
      `AdProvider?` gợi ý (null = chưa đủ dữ liệu, giữ nguyên lựa chọn host
      đã cấu hình). Host tự đọc giá trị này TRƯỚC khi build `AdConfig`,
      không bắt buộc nghe theo.
- [ ] Document rõ trong doc-comment: đây KHÔNG phải cross-install
      optimization thật (không có server), chỉ là gợi ý dựa lịch sử của
      CHÍNH thiết bị đó.
- [ ] Unit test: đủ dữ liệu → có gợi ý đúng hướng; chưa đủ dữ liệu → trả
      `null`; dữ liệu bị tamper (verify signature fail) → bỏ qua, coi như
      chưa có dữ liệu (fail-safe).

## Ghi chú

Effort XL vì cần thiết kế cẩn thận ngưỡng "đủ dữ liệu để tin" (bao nhiêu
session mới đáng tin) và tránh false-positive khi mẫu quá nhỏ. Đây là ý
tưởng phức tạp nhất trong nhóm độc quyền — cân nhắc làm SAU cùng, sau khi
đã có kinh nghiệm thật từ T136 (cùng họ session-alternate, ít rủi ro hơn để
thử nghiệm thiết kế trước).

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T146-privacy-safe-cohort-optimizer.md này (nếu
đã chuyển inprogress/done thì đọc ở đó). Implement ĐÚNG scope "Việc cần
làm" — KHÔNG thêm scope ngoài mô tả. ĐỌC KỸ mục "Lưu ý phạm vi" — đây là
gợi ý cho INIT TIẾP THEO của CÙNG install, KHÔNG phải runtime switch,
KHÔNG phải cross-install thật (không có server tổng hợp). Nếu code có xu
hướng lái sang runtime switch (giống T143) hoặc cần gửi dữ liệu lên server
nào, dừng lại hỏi user.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có, không tự dựng server/API mới. Tái dùng
`signJsonPayload`/`verifySignedJsonPayload` đã có, đừng viết cơ chế ký mới.

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
