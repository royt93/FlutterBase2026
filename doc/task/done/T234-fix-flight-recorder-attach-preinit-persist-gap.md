# T234 — Fix AdFlightRecorder.attach() thiếu persist ngay cho entry ghi trước init (tái diễn bug-class T155)

- **Loại:** Fix (Bug)
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done

## Vấn đề (Why)

`BypassAuditTrail.attach()` (`packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart:132-149`) đã sửa đúng bug T155 (codex round 1, P1): nếu có entry ghi được TRƯỚC khi `attach(prefs)` chạy (ví dụ host gọi API bypass sớm), entry đó chỉ nằm trong bộ nhớ vì `_schedulePersist()` no-op khi `_prefs == null`. Fix là dòng 148: `if (before > 0) _schedulePersist();` — persist ngay các entry cũ khi `attach()` cuối cùng cũng chạy.

`AdFlightRecorder.attach()` (T231, mới thêm) copy gần như y hệt cấu trúc (`packages/ad_sdk/lib/src/compliance/ad_flight_recorder.dart:250-262`) nhưng **thiếu đúng dòng fix đó** — chỉ log `loaded` entries đọc được từ đĩa, không hề gọi `_schedulePersist()` cho các entry đã có trong `_entries` trước khi `attach()` được gọi.

Kịch bản thật: `AdManager.enableFlightRecorder(recorder)` (`ad_manager.dart:967-973`) có thể chạy trước `initialize()` (comment tại dòng 969-971 tự thừa nhận "covers the enabled-after-initialize ordering too"), và widget đã mount có thể emit `recordFlightRecorderEvent` trước khi `_flightRecorder.attach(prefs)` được gọi tại `ad_manager.dart:3601` (bên trong `initialize()`). Nếu app bị kill giữa 2 mốc đó, các entry evidence ghi sớm nhất — bao gồm cả banner-visible đầu tiên — biến mất vĩnh viễn dù `record()` đã chạy "thành công".

## Đề xuất giải pháp

Thêm đúng 1 dòng tương tự T155: sau khi `_load()` xong trong `attach()`, nếu có entry tồn tại từ trước khi gọi `attach()` (`before > 0`, dùng biến `before` đã có sẵn — đây là các entry ghi qua `record()` trước init, KHÔNG phải entry vừa đọc từ đĩa), gọi `_schedulePersist()` ngay.

### Acceptance Criteria

- [ ] Entry ghi bằng `record()` trước `attach()` được persist đúng debounce window ngay sau `attach()` chạy, không cần chờ `record()` kế tiếp.
- [ ] Không đổi hành vi khi `attach()` chạy trước mọi `record()` (trường hợp phổ biến nhất, không regress).
- [ ] Không đổi API công khai.
- [ ] `flutter analyze` sạch; full `flutter test` pass.

## Kế hoạch kiểm thử

- Unit: tạo `AdFlightRecorder`, gọi `record()` 1-2 lần TRƯỚC `attach(prefs)`, sau đó `attach()`, verify đĩa có đúng số entry trong debounce window (mirror test case đã có cho `BypassAuditTrail` T155).
- Unit: kịch bản app-kill mô phỏng — `attach()` rồi kill (không gọi `flush()`), tạo instance mới `attach()` lại cùng prefs, xác nhận không mất entry ghi trước init đầu tiên.
- Regression: xác nhận trường hợp `attach()` trước mọi `record()` (đường phổ biến — `initialize()` luôn attach trước khi widget nào emit event) không đổi hành vi.

## Kết quả

**Verdict:** FIXED. Claim xác nhận đúng: `AdFlightRecorder.attach()` copy gần y hệt `BypassAuditTrail.attach()` nhưng thiếu dòng `if (before > 0) _schedulePersist();`. Fix 1 dòng, thêm ngay sau khối `if (loaded > 0) { ... _lastHash = ...; }` trong `attach()` (`lib/src/compliance/ad_flight_recorder.dart`), kèm comment T234 giải thích lý do (mirror comment T155 của `BypassAuditTrail`).

- RED trước fix (đã verify bằng cách comment tạm dòng fix rồi chạy lại): 3/5 unit test mới + widget test T234 fail đúng như dự kiến (`Expected: not null / Actual: <null>`, thiếu entry sau merge).
- GREEN sau fix: unit `test/ad_flight_recorder_test.dart` 33/33 pass (5 test mới nhóm `pre-attach persistence (T234)`); widget `test/banner_ad_widget_test.dart` 49/49 pass (1 test mới); `test/mrec_ad_widget_test.dart` + `test/bypass_audit_trail_test.dart` + `test/ad_manager_flight_recorder_test.dart` không regress — cả 5 file targeted cộng lại 134/134 pass.
- Phát hiện thật trong lúc viết test (không phải bug mới, là giới hạn kiến trúc có chủ đích của T234's phạm vi tối giản): `AdFlightRecorder` có hash-chain (`AdFlightRecorder` khác `BypassAuditTrail` — list phẳng, không chain). Một entry ghi TRƯỚC `attach()` đã tự chốt `previousHash` từ `_lastHash` rỗng của chính instance đó, nên khi `attach()` sau đó load thêm lịch sử cũ từ đĩa, 2 đoạn không thể nối liền chain lại được (fix 1 dòng T155-style không giải quyết việc này, và ticket cũng không yêu cầu). Test `stored history and pre-attach entry merge and both persist` assert đúng thực tế này: cả 2 entry đều được giữ + persist (đúng phạm vi T234), nhưng `verifyFlightRecorderChain` cho toàn bộ danh sách trả `false` ở điểm nối — ghi rõ trong comment test, không che giấu.
- Full `flutter test` (2,420 test): pass. Lần chạy thứ 1 có 1 lỗi flake tại `consent_fallback_wiring_test.dart` (`MissingPluginException: setHasUserConsent`, "test failed after it had already completed") — pass riêng lẻ khi chạy 1 mình, và lần chạy full thứ 2 (không đổi gì) pass sạch 2,420/2,420. Cùng loại flake đã ghi nhận trong T237's "Kết quả" (không liên quan T234, pre-existing cross-test-file timing flake).
- `flutter analyze` (package + `example/`): sạch, không lỗi.
- Integration test mới `example/integration_test/t234_flight_recorder_preattach_persist_test.dart` (mirror `bypass_audit_trail_persistence_test.dart`): viết xong, `flutter analyze` riêng file sạch, nhưng **không chạy được trên thiết bị thật** — không có device/emulator/simulator nào sẵn sàng tại thời điểm chạy (`adb devices` rỗng, `xcrun simctl list devices booted` rỗng, không có `emulator` binary, mọi thiết bị LAN trong `flutter devices` đều lock/không kết nối). Đây là gap thật, báo cáo trung thực thay vì giả lập kết quả — cần người chạy `flutter test integration_test/t234_flight_recorder_preattach_persist_test.dart -d <device>` khi có Pixel/TECNO/S24 Ultra kết nối USB.
- Không đổi public API — không cần regenerate golden.
- CHANGELOG 3.4.0 (chưa publish) đã thêm bullet T234.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T234 theo quy trình TDD chuẩn:
1. Đọc kỹ ticket, đối chiếu trực tiếp `BypassAuditTrail.attach()` làm tham chiếu đúng.
2. Viết test RED tái hiện đúng mất-dữ-liệu khi record trước attach rồi kill trước lần record kế tiếp.
3. Sửa tối giản (1 dòng, đúng pattern T155), không tạo abstraction mới.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Audit lại diff, chấm điểm /10 độc lập.
   - Đủ test pyramid, smoke test thiết bị thật (bật flight recorder trước init, kill app, mở lại, xác nhận entry đầu còn nguyên qua export/verify tool).
   - Chỉ commit/push khi >9/10.
