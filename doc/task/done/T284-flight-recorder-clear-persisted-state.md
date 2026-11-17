# T284 — Đánh giá contract clear RAM/persistence của Flight Recorder

- **Loại:** Contract investigation / optional enhancement
- **Priority:** P3 · **Severity:** LOW
- **Confidence:** Contract reviewed; no consumer need found for direct durable clear.
- **Status:** done — no-change (2026-11-17)
- **Evidence:** `AdFlightRecorder.clear()` synchronously clears in-memory entries and hash anchor only; `AdManager.clearSdkData()` deletes persisted Flight Recorder data before clearing the live recorder. Existing tests cover fresh chain anchor after clear and a record/clear race without chain corruption. Repository callsite review found durable erasure routed through `clearSdkData()`; no direct-clear consumer requiring disk deletion was found.
- **Disposition:** Keep `clear()` RAM/hash-only; use `AdManager.clearSdkData()` for durable privacy erasure. Reopen only if a concrete consumer requires direct persistent clear.

## Bối cảnh & vấn đề

`AdFlightRecorder.clear()` synchronously clears `_entries` and `_lastHash`; its source documentation promises only in-memory chain reset, not durable erasure. The separate privacy-erasure path, `AdManager.clearSdkData()`, deletes the SDK preference key before clearing the live recorder. A direct clear can therefore leave the old persisted snapshot for a later recorder to load, but current contract does not establish that as a bug. This ticket is a discovery gate: confirm whether consumers expect `clear()` to clear disk; preserve the current API and erasure path unless a real use case requires more.

## Phạm vi

1. Xác nhận direct `clear()` call sites và consumer expectation; không thay behavior khi chưa có durable-clear use case.
2. Thêm test pin contract hiện tại: direct clear reset RAM/hash, persisted snapshot lifecycle, pending debounce writes current snapshot; durable erase do `AdManager.clearSdkData()` đảm trách.
3. Chỉ khi contract yêu cầu xóa persistent snapshot, chọn cách tương thích API tối thiểu và review API/SemVer trước khi đổi signature.
4. Bảo toàn `AdManager.clearSdkData()` ordering và `dispose()` replacement semantics; không để clear instance cũ xóa dữ liệu instance mới.

## Acceptance criteria

- [ ] Xác minh consumer call sites và chốt contract mong muốn của direct `clear()`; `AdManager.clearSdkData()` đã xóa key trước khi gọi clear và giữ hành vi đó.
- [ ] Regression test mô tả chính xác hiện trạng RAM, persisted snapshot, pending debounce; không tuyên bố debounce tự hồi sinh dữ liệu cũ.
- [ ] Nếu contract yêu cầu persistent clear: sau clear/reload chỉ dữ liệu mới còn; record mới tạo valid chain với `previousHash == ''`. Nếu RAM-only là chủ đích, ghi docs/test cho contract đó và đóng không đổi code.
- [ ] Nếu có đổi behavior: thứ tự persistence an toàn khi clear cạnh `_persistNow()`/`flush()`; không xóa entry mới ghi sau clear.
- [ ] `AdManager.clearSdkData()` vẫn xóa toàn bộ flight-recorder data, không hồi sinh từ disk sau async lifecycle.
- [ ] Nếu contract yêu cầu durable clear và public signature đổi, update `CHANGELOG.md` + API golden và SemVer rationale.
- [ ] Unit tests pin the chosen contract: clear/reload, pending debounce, clear/flush ordering, record-after-clear. Full SDK suite + `flutter analyze` pass if code changes.
- [ ] Widget/golden/interruption/network-conditioning/memory-profile/frame-jank/IAP/mediation: đánh giá relevance; ghi N/A kèm lý do nếu không ảnh hưởng. Widget test N/A trừ khi callsite UI behavior đổi; IAP ngoài SDK scope.
- [ ] Không log hoặc xuất raw evidence đã clear; chỉ test data giả, không dùng consent string/user data thật.

## Kế hoạch kiểm thử

- **Unit:** `test/ad_flight_recorder_test.dart` kiểm contract RAM clear vs persisted snapshot, pending debounce, flush/reload ordering.
- **Widget:** chỉ nếu thay đổi `BannerAdWidget`/UI callsite; nếu không N/A.
- **Integration:** kiểm `AdManager.clearSdkData()` orchestration và re-init trên fake prefs; Android/iOS device persistence không cần nếu logic chỉ Dart/SharedPreferences abstraction.
- **Golden:** N/A nếu không đổi widget/API visual output; golden/API surface test bắt buộc nếu signature/public API thay.
- **Interruption/network conditioning/memory/profile/frame-jank:** N/A nếu diff chỉ persistence operation; ghi lý do.
- **Device smoke:** chỉ khi thay storage/plugin interaction trên nền tảng; test app disposable, xác minh clear → restart → evidence rỗng, không dùng host app.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T284 như contract investigation trước, không mặc định đây là runtime bug. Đọc ticket, toàn bộ `lib/src/compliance/ad_flight_recorder.dart`, `test/ad_flight_recorder_test.dart`, `AdPreferences` flight-recorder methods và `AdManager.clearSdkData()` callsite. Tìm consumer callsites của direct `clear()` và xác nhận expected host semantics. Viết test tái hiện exact state: RAM clear, persisted snapshot còn nguyên, pending debounce ghi bundle rỗng, và `AdManager.clearSdkData()` xóa key trước. Chỉ đề xuất runtime/API change nếu contract/use case yêu cầu; nếu đổi signature, cập nhật changelog/API golden và giải thích SemVer. Bảo toàn ordering với `dispose()` và writes của instance mới. Chạy targeted/full SDK tests và analyze nếu có code change. Audit độc lập kết luận, chấm điểm /10. Bổ sung unit/widget/integration/golden/interruption/network-conditioning/memory-profile/frame-jank/mediation tests khi có ảnh hưởng; ghi N/A kèm lý do, IAP ngoài SDK. Smoke device chỉ nếu native persistence path đổi, app ID disposable, lưu evidence; không cài đè app host hoặc dùng production data/credentials. Chỉ push runtime code khi owner yêu cầu, mọi test áp dụng + device evidence pass, score >9/10; nếu no-change/clarification thì không push.
```
