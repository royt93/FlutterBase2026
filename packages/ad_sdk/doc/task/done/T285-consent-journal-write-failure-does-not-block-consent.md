# T285 — Journal storage failure không được chặn consent update

- **Loại:** Bug / Consent reliability
- **Priority:** P1 · **Severity:** HIGH
- **Confidence:** Confirmed by source; no storage-failure regression test. Owner chose best-effort provenance journal.
- **Status:** todo
- **Evidence:** `lib/src/consent/consent_manager.dart:386-400, 569-601, 603-635`; `lib/src/compliance/consent_provenance_journal.dart:175-178, 193-216, 219-266`; related tests `test/consent_manager_test.dart`, `test/consent_provenance_journal_test.dart`
- **Dependencies:** Owner decision confirmed: journal is best-effort audit; journal write failure must not block consent update/provider apply

## Bối cảnh & vấn đề

`ConsentManager._setInternal()` và `_resetInternal()` thay đổi in-memory consent/listenable, rồi await `_recordProvenance()` trước khi lưu consent settings và áp dụng thay đổi vào AdMob/AppLovin. `ConsentProvenanceJournal.append()` await platform storage write; lỗi ghi propagates về caller. Vì vậy storage failure có thể làm API ném lỗi sau khi in-memory state đã đổi, nhưng trước khi consent được lưu bền hoặc provider flags được cập nhật. Journal là audit phụ; theo quyết định owner, failure phải được log/ghi nhận nhưng không được ngăn consent mới được persist/apply. Không được giả vờ entry provenance đã được ghi thành công.

## Phạm vi

1. Thêm tests inject lỗi `setConsentProvenanceJournalRaw` trong các đường `set` và `reset`.
2. Khi journal persistence lỗi, tiếp tục mandatory consent settings persistence và provider application; ghi journal failure bằng logging hiện có, không để raw storage exception làm fail consent mutation.
3. Bảo toàn hành vi khi journal thành công: hash chain/ordering/retention không đổi.
4. Bảo đảm lỗi consent-settings persistence vẫn propagate; giữ nguyên error handling hiện tại trong `applyConsentToProviders` (provider bridge failures được log/catch ở đó). Chỉ provenance journal write failure được degrade thành best-effort.
5. Không thêm retry loop/network call; journal là local audit store.
6. External-anchor callback gap sau failed append tách riêng sang T286; T285 không thêm callback replay hoặc thay đổi `onEntryAppended` semantics.

## Acceptance criteria

- [ ] Regression RED: journal storage throw trong `set()` hiện ngăn consent save/provider apply; test chứng minh cả hai.
- [ ] Sau fix, `set()` với journal write failure hoàn tất theo contract: `ConsentSettings` được persist, AdMob/host policy callback nhận giá trị mới, provenance failure không giả mạo success.
- [ ] `reset()` có cùng coverage: consent unset/flags preserved được persist và provider apply vẫn chạy khi journal write fail.
- [ ] Thành công bình thường vẫn append đúng một provenance record, lưu consent và apply provider một lần.
- [ ] Consent-settings write errors still propagate; provider bridge errors retain existing log/catch behavior and `_lastAppliedToProviders` remains unchanged unless required writes succeed.
- [ ] Thứ tự concurrent set/reset không để mutation cũ ghi đè trạng thái mới; bổ sung concurrency test nếu thay đổi sequencing.
- [ ] Unit tests cho set/reset × journal success/failure, consent-settings/provider call counts và journal queue tiếp tục hoạt động sau append failure.
- [ ] Widget test N/A nếu UI không đổi; integration cần cho consent lifecycle nếu abstraction cho phép. Golden N/A nếu không đổi rendering/API surface; update API golden/changelog chỉ khi public API đổi.
- [ ] Interruption/network conditioning/memory/profile/frame-jank N/A vì local consent store path không có network/frame/memory algorithm; mediation/IAP N/A (IAP host-owned). Ghi lý do cho mọi N/A.
- [ ] `flutter analyze` và full SDK tests pass.

## Kế hoạch kiểm thử

- **Unit:** controlled throwing `AdPreferences`/journal storage; set/reset branches; verify persisted consent and provider callback.
- **Widget:** N/A, no UI change.
- **Integration:** run consent mutation through `ConsentManager`/`AdManager` bootstrap with injected failing local journal store; verify end-to-end state and no ads incorrectly use stale consent.
- **Golden:** N/A, no visual/public API change.
- **Interruption/network conditioning:** N/A, local storage exception not network/interruption behavior; test async storage failure directly.
- **Memory/profile/frame-jank:** N/A, no sustained allocation/render path change.
- **Mediation/IAP:** N/A; no ad waterfall or purchase API change.
- **Device smoke:** Android test build with test ad IDs only if real SharedPreferences/platform channel is changed; verify consent mutation completes after injected/testable storage failure without production data. Otherwise unit+integration are sufficient, explicitly document device N/A.

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai T285 theo TDD. Đọc ticket cùng `lib/src/consent/consent_manager.dart`, `lib/src/compliance/consent_provenance_journal.dart`, `lib/src/utils/ad_preferences.dart`, `test/consent_manager_test.dart` và `test/consent_provenance_journal_test.dart`. Viết test RED cho journal storage failure riêng trên `_setInternal` và `_resetInternal`; xác nhận hiện trạng partial mutation (in-memory đổi nhưng persisted settings/providers chưa theo). Implement tối thiểu để journal write failure được ghi nhận nhưng không chặn consent settings persistence/provider apply, theo owner decision journal best-effort. Không swallow lỗi từ consent settings store hoặc provider apply; không báo provenance entry thành công khi persist fail. Bảo toàn hash chain và concurrent mutation ordering. Chạy targeted tests, analyze, full SDK suite; thêm integration test nếu seams hiện có cho phép. Widget/golden/interruption/network/memory/profile/frame-jank/mediation/IAP/device smoke chỉ khi behavior liên quan; mọi N/A ghi lý do. Audit độc lập toàn bộ diff và chấm điểm /10. Bổ sung unit + widget + integration + golden/interruption/network-conditioning/memory/frame-jank/mediation/IAP checks phù hợp, không tạo coverage giả. Device smoke chỉ theo acceptance trên, test IDs và disposable package ID; không chạm `com.roy.admobwrapper` hoặc production credentials. Chỉ push khi mọi test áp dụng pass, evidence/device gate thỏa, score >9/10.
```
