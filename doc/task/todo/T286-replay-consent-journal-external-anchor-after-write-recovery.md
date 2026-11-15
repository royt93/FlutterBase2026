# T286 — Khôi phục external-anchor callback sau journal write failure

- **Loại:** Enhancement / Audit evidence reliability
- **Priority:** P2 · **Severity:** MEDIUM
- **Confidence:** Confirmed behavior gap; external anchor is opt-in
- **Status:** todo
- **Evidence:** `lib/src/compliance/consent_provenance_journal.dart:107-118, 193-216, 219-266`; `test/consent_provenance_journal_test.dart` hook and append coverage
- **Dependencies:** T285 best-effort consent isolation; owner approval of callback retry/idempotency semantics

## Bối cảnh & vấn đề

`ConsentProvenanceJournal._appendLocked()` appends entry to in-memory `_entries`, then persists the entire list, and only after successful persistence calls optional `onEntryAppended`. If persistence fails, consent flow now continues under T285, and the entry remains in memory. A later successful append can persist both entries, but `onEntryAppended` fires only for the later entry; an external anchor can permanently miss the earlier entry that is now in the local journal. This does not block consent or corrupt the local hash chain, but may weaken externally anchored audit completeness.

## Phạm vi

1. Confirm external-anchor consumers expect every persisted journal entry exactly once, including entries whose first write failed.
2. Define delivery semantics: at-least-once with stable entry hash/idempotency, or explicit retry/pending state; do not silently promise exactly-once over a fallible external callback.
3. Reconcile disk persistence and callback delivery ordering. Preserve consent best-effort behavior: neither journal storage nor external callback failure may block `_setInternal()`/`_resetInternal()`.
4. Avoid duplicate callback delivery for entries already externally anchored when a later whole-journal persist succeeds.
5. If partner use case does not need recovery/replay, close with a documented limitation and no code change.

## Acceptance criteria

- [ ] Reproduce: first append storage fails; second append succeeds; demonstrate precisely which entries are persisted and which callbacks were delivered.
- [ ] Owner/host contract for external anchor delivery is explicit (best-effort, at-least-once, idempotent, or no replay).
- [ ] If implementing replay, callback receives the missed first entry once or with stable dedupe key; later entries preserve order.
- [ ] Storage failure, callback sync throw, callback async throw, and retry/recovery do not poison `_writeQueue` or block consent mutation.
- [ ] Hash chain verifies before/after failure and recovery; persisted contents match documented delivery contract.
- [ ] Unit tests cover failure → recovery, repeated failures, callback errors and no duplicate delivery; update existing hook tests.
- [ ] Widget/golden/interruption/network-conditioning/memory-profile/frame-jank/mediation/IAP are N/A unless implementation touches those paths; document reason. IAP belongs to host app.
- [ ] Run targeted tests, `flutter analyze`, full SDK suite. Device smoke only if a real external-anchor transport is in scope; never send real consent data to an unapproved endpoint.
- [ ] Independent audit + score /10; push only after all applicable tests/evidence and score >9/10.

## Kế hoạch kiểm thử

- **Unit:** deterministic failing `SharedPreferencesStorePlatform` plus controllable sync/async `onEntryAppended` callbacks.
- **Widget:** N/A, journal API only.
- **Integration:** `ConsentManager.set/reset` remains non-blocking under journal and external callback failures; device/network integration N/A if callback remains local fake.
- **Golden:** N/A, no UI/public API visual changes.
- **Network conditioning/interruption:** N/A unless callback transport is implemented; do not introduce network dependency for local journal.
- **Memory/profile/frame-jank:** N/A unless a bounded pending-delivery queue changes memory/runtime profile; if added, test boundedness.
- **Device smoke:** N/A for local-only semantics; required only for approved external endpoint integration.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T286 như scope tùy chọn, không sửa khi chưa xác nhận external-anchor host cần reliable replay. Đọc ticket, `consent_provenance_journal.dart`, `consent_manager.dart`, related tests và T202/T285. Viết regression failure → recovery chứng minh local disk list và callback list chính xác. Trước khi code, xác nhận callback delivery guarantee với owner/host; nếu không có yêu cầu, ghi limitation/no-change. Nếu được duyệt, chọn at-least-once + stable dedupe semantics thay vì hứa exactly-once không thể bảo đảm; không để external callback hoặc storage lỗi chặn consent. Test callback sync/async failure, storage failure/recovery, duplicate/retry, chain integrity và queue recovery. Chạy targeted/full suite, analyze. Unit/integration/golden/widget/device/perf dimensions áp dụng theo actual implementation; N/A kèm lý do, không gọi external endpoint chứa consent data nếu chưa được phê duyệt. Independent audit changes, score /10; chỉ push nếu mọi gate pass và >9/10.
```
