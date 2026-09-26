# T142 — Tính năng mới: Offline deterministic scenario runner cho QA

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P3
- **Status:** ✅ done
- **Effort:** L
- **Files (dự kiến):** file mới `lib/src/testing/scenario_runner.dart` (hoặc
  `test/test_helpers/` nếu quyết định đây là dev-only, không ship trong
  package — cần quyết định khi bắt đầu, xem Ghi chú), tham khảo
  `lib/src/compliance/ad_event_log.dart`, `lib/src/monetization/digital_twin.dart`
- **Nguồn gợi ý:** codex
- **Dependency:** không có

## Vấn đề

**Đã verify: KHÔNG có `FakeAdapter` dùng chung nào trong `lib/`.** Brainstorm
gốc nói "đã có FakeAdapter/AdEventLog/DigitalTwin rời rạc" — kiểm tra lại
bằng grep cho thấy `_FakeAdapter implements AdProviderAdapter` chỉ tồn tại
dưới dạng class PRIVATE, định nghĩa RIÊNG trong từng file test (ít nhất 3
bản khác nhau: `test/integration_self_check_test.dart`,
`test/monetization_arbitrator_test.dart`, `test/ad_crash_guard_test.dart`)
— không có 1 fake adapter chung nào được export/tái dùng. `AdEventLog`
(`lib/src/compliance/ad_event_log.dart`) và `MonetizationDigitalTwin`
(`lib/src/monetization/digital_twin.dart`) thì có thật và export sẵn.

Vậy việc thật cần làm KHÔNG PHẢI "gộp 3 thứ có sẵn" mà là: (1) trích xuất 1
fake adapter DÙNG CHUNG từ 3 bản private hiện có, (2) xây orchestration mới
chạy kịch bản qua fake adapter đó + ghi log qua `AdEventLog` + replay qua
`MonetizationDigitalTwin`.

## Việc cần làm

- [x] Đọc kỹ 3 bản `_FakeAdapter` hiện có, hợp nhất thành 1 class dùng
      chung (quyết định: export trong `lib/` cho host QA dùng được, hay chỉ
      là dev-dependency nội bộ test/ — quyết định này ảnh hưởng tới có nên
      thêm dependency mới vào `pubspec.yaml`'s `dev_dependencies` hay
      `dependencies` không, cân nhắc kỹ trước khi code).
- [x] Cập nhật 3 file test hiện có dùng bản chung mới thay vì bản riêng
      (tránh double-maintain 3 bản gần giống nhau — đây chính là root cause
      nên fix, không chỉ thêm 1 bản thứ 4).
- [x] Thiết kế `ScenarioRunner` — nhận danh sách bước kịch bản (kiểu enum/
      class: init, loadFail, retry, show, reward, ...), chạy qua fake
      adapter chung, output structured result (list `AdEvent` đã phát sinh)
      để so sánh (assert) được trong test.
- [x] Unit test cho `ScenarioRunner` tự nó (không chỉ dùng nó để test cái
      khác).

## Ghi chú

Effort L vì việc thật không phải build tính năng mới trên nền có sẵn, mà là
DỌN 3 bản trùng lặp trước rồi mới xây orchestration mới lên trên — quyết
định "export public hay giữ nội bộ test" cần cân nhắc: nếu public, đây trở
thành 1 phần API SDK cần maintain/test/document như mọi API khác; nếu chỉ
nội bộ, giá trị chỉ dành cho người maintain SDK này, không phải host app.
Nên hỏi user quyết định hướng này trước khi code nếu không rõ trong ticket.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T142-offline-scenario-runner.md này (nếu đã
chuyển inprogress/done thì đọc ở đó). Implement ĐÚNG scope "Việc cần làm" —
KHÔNG thêm scope ngoài mô tả. Quyết định "public API hay nội bộ test" ở
mục Ghi chú CHƯA được chốt — hỏi user trước khi bắt đầu nếu chưa rõ.

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
