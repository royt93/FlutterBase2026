# T145 — Độc quyền: Cross-provider Revenue Integrity Ledger

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** L
- **Files (dự kiến):** `lib/src/state/ad_event.dart` (`AdShowEvent`,
  `AdRevenueEvent` — không có field ID chung, xem dưới),
  `lib/src/compliance/ad_event_log.dart`, `lib/src/compliance/incident_recorder.dart`
  (báo bất thường qua đây, đã có sẵn), file mới
  `lib/src/monetization/revenue_integrity_ledger.dart`
- **Nguồn gợi ý:** codex
- **Dependency:** không có

## Vấn đề

**Đã tự verify: KHÔNG có request/impression ID chung giữa `AdShowEvent` và
`AdRevenueEvent`** (`lib/src/state/ad_event.dart:46-137`) — cả 2 chỉ có
`providerTag`, `type`, `placement` (+ field riêng). Brainstorm gốc giả định
"đối soát bằng request/impression ID" — **không khả thi trực tiếp**, vì
field đó không tồn tại. Việc đối soát thật sự chỉ có thể làm bằng khớp
(providerTag, placement) + cửa sổ thời gian hợp lý (vd: show success không
có revenue event tương ứng trong N giây sau đó).

## Việc cần làm

- [ ] Thiết kế `RevenueIntegrityLedger` — lắng nghe `AdEventLog` (đã có
      sẵn), với mỗi `AdShowEvent(success: true)` ghi nhận
      (providerTag, placement, timestamp) vào 1 pending list.
- [ ] Khi có `AdRevenueEvent` khớp (providerTag, placement) trong cửa sổ
      thời gian hợp lý (configurable, mặc định vd 60s) sau show — xoá khỏi
      pending list (bình thường).
- [ ] Pending entry còn tồn tại quá cửa sổ thời gian → coi là "show thành
      công nhưng không có revenue callback tương ứng" — báo qua
      `IncidentRecorder` đã có sẵn (không tự chế cơ chế báo cáo mới).
- [ ] Cân nhắc rõ: đây là HEURISTIC (khớp gần đúng theo thời gian, không
      phải đối soát chính xác tuyệt đối bằng ID) — phải document rõ giới
      hạn này, tránh host hiểu nhầm đây là bằng chứng tuyệt đối gian lận
      mediation (có thể chỉ là revenue event tới trễ hơn bình thường).
- [ ] Unit test: case khớp bình thường, case revenue tới trễ nhưng vẫn
      trong cửa sổ (không false-positive), case thật sự thiếu revenue
      (đúng phát hiện).

## Ghi chú

Hoàn toàn on-device — chỉ dùng event chính SDK đã nhận từ AdMob/AppLovin,
không gọi API bên thứ 3 nào. Effort L vì cần thiết kế cửa sổ thời gian hợp
lý (quá ngắn → false positive nhiều, quá dài → phát hiện chậm) và cần dữ
liệu thật (không phải giả định) để hiệu chỉnh ngưỡng — nên có 1 giai đoạn
thu thập dữ liệu thật trước khi chốt threshold mặc định.

## Kết quả (2026-09-07) — DONE

- **Status:** ✅ done. **Điểm cuối: 9.5/10** (2 vòng review độc lập
  `codex`: 8.5/10 → 9.5/10).
- `RevenueIntegrityLedger` (file mới) — lắng nghe `AdManager().events`
  (không phải AdEventLog trực tiếp — class đó là log thụ động, không có
  API stream riêng; dùng đúng nguồn event thật mọi class T1xx khác trong
  SDK đều dùng). Mỗi `AdShowEvent(success:true)` → pending List (không
  phải Map, vì có thể nhiều pending cùng key). `AdRevenueEvent` khớp
  (providerTag, placement) xoá entry CŨ NHẤT (FIFO — không có ID thật nên
  đây là lựa chọn hợp lý nhất). Entry quá `matchWindow` → báo qua
  `AdManager().incidentRecorder` (đã có sẵn từ T144, không tự chế cơ chế
  mới). Thuần event-driven, KHÔNG dùng Timer thật.
- **Vòng 1 (8.5/10)** — 2 finding Important:
  1. Thiếu document giới hạn "purely event-driven, no Timer" — matchWindow
     chỉ check khi có event MỚI tới, app im lặng hoàn toàn thì entry
     "treo" chưa sweep. Đã thêm "Known limitation" vào doc comment class +
     README.
  2. 4 test không thực sự chứng minh điều tuyên bố (FIFO chỉ assert count
     giảm — LIFO cũng pass; thiếu case khác placement; test click không
     chứng minh event không liên quan không xoá entry ĐANG pending; test
     missing-revenue không verify đúng 1 lần). Viết lại cả 4, tự
     mutation-test FIFO (đổi tạm `indexWhere`→`lastIndexWhere`, xác nhận
     FAIL đúng, restore lại) TRƯỚC KHI gửi review vòng 2.
- Baseline: `flutter analyze` sạch (2 info deprecation pre-existing không
  liên quan); `flutter test` 1782/1782; integration test
  `t145_revenue_integrity_ledger_test.dart` pass thật trên Pixel 7 Pro
  (Android thật).

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T145-cross-provider-revenue-integrity-ledger.md
này (nếu đã chuyển inprogress/done thì đọc ở đó). Implement ĐÚNG scope
"Việc cần làm" — KHÔNG thêm scope ngoài mô tả. Đây là heuristic khớp theo
thời gian, KHÔNG có ID chung thật giữa show/revenue event — đừng giả định
ngược lại.

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
