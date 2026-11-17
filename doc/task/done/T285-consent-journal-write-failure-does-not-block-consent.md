# T285 — Journal storage failure không được chặn consent update

- **Loại:** Bug / Consent reliability
- **Priority:** P1 · **Severity:** HIGH
- **Confidence:** Behavior implemented and covered; no remaining confirmed defect.
- **Status:** done (2026-11-17)
- **Evidence:** `lib/src/consent/consent_manager.dart:386-405` catches provenance append failure and continues consent persistence/provider application. `test/consent_manager_provenance_test.dart:110-255` verifies set/reset journal failure, persisted consent, provider apply callback, warning without consent value, and that failed journal entries are not reported or persisted. `test/consent_manager_provenance_test.dart:256+` verifies consent-settings storage failure still propagates.
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

- [x] Journal append failure in `set()` is best-effort and does not block consent persistence/provider apply; failure is logged without raw consent values or false success.
- [x] `reset()` persists the unset consent and applies providers when journal append fails.
- [x] Successful journal append path and chain integrity remain covered by existing provenance tests.
- [x] Consent-settings storage failure still propagates; only auxiliary provenance append failure is swallowed.
- [x] `test/consent_manager_provenance_test.dart` covers set/reset journal failure, success path, persisted state, provider callback, warning semantics and later successful append.
- [x] No write-queue poisoning or concurrency behavior change introduced by this implementation.
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

## Disposition

- Widget/golden/network-conditioning/memory/profile/frame-jank/mediation/IAP/device smoke are N/A: change concerns best-effort local audit persistence and does not change UI, native request code, network behavior, or ad lifecycle. IAP remains host-owned.
- No release or API surface change is required. T286 separately covers external-anchor replay after persisted recovery.

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai T285 theo TDD. Đọc ticket cùng `lib/src/consent/consent_manager.dart`, `lib/src/compliance/consent_provenance_journal.dart`, `lib/src/utils/ad_preferences.dart`, `test/consent_manager_test.dart` và `test/consent_provenance_journal_test.dart`. Viết test RED cho journal storage failure riêng trên `_setInternal` và `_resetInternal`; xác nhận hiện trạng partial mutation (in-memory đổi nhưng persisted settings/providers chưa theo). Implement tối thiểu để journal write failure được ghi nhận nhưng không chặn consent settings persistence/provider apply, theo owner decision journal best-effort. Không swallow lỗi từ consent settings store hoặc provider apply; không báo provenance entry thành công khi persist fail. Bảo toàn hash chain và concurrent mutation ordering. Chạy targeted tests, analyze, full SDK suite; thêm integration test nếu seams hiện có cho phép. Widget/golden/interruption/network/memory/profile/frame-jank/mediation/IAP/device smoke chỉ khi behavior liên quan; mọi N/A ghi lý do. Audit độc lập toàn bộ diff và chấm điểm /10. Bổ sung unit + widget + integration + golden/interruption/network-conditioning/memory/frame-jank/mediation/IAP checks phù hợp, không tạo coverage giả. Device smoke chỉ theo acceptance trên, test IDs và disposable package ID; không chạm `com.roy.admobwrapper` hoặc production credentials. Chỉ push khi mọi test áp dụng pass, evidence/device gate thỏa, score >9/10.
```
