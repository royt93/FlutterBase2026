# T286 — Khôi phục external-anchor callback sau journal write failure

- **Loại:** Enhancement / Audit evidence reliability
- **Priority:** P2 · **Severity:** MEDIUM
- **Confidence:** Current append/replay semantics are implemented and covered; no remaining confirmed defect.
- **Status:** done — no further change (2026-11-17)
- **Evidence:** `ConsentProvenanceJournal._appendLocked()` removes an entry from `_entries` when persistence fails and only schedules delivery after a successful persist. Persisted entries are delivered oldest-first using a durable anchor cursor; callback or cursor-write failure retries later and may duplicate delivery, as documented. Tests cover storage-failure recovery, oldest-first delivery, duplicate-after-ack-write-failure, later-append retry, and clear invalidating in-flight cursor writes: `test/consent_provenance_journal_test.dart:474-733`.
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

- [x] Append persistence failure removes the unpersisted entry from the in-memory chain; a later append persists/delivers only committed journal entries.
- [x] External-anchor delivery is opt-in, ordered and at-least-once using stable `entryHash` for host-side dedupe; exactly-once is not promised across callback success + cursor-write failure.
- [x] Callback/storage failure does not block consent mutation or poison the append queue; failures retry on a later append/reload.
- [x] Hash chain remains valid and persisted entries match callback eligibility after failure/recovery.
- [x] Unit tests cover storage failure/recovery, oldest-first delivery, duplicate after ack-cursor failure, retry on later append, and clear racing pending delivery.
- [ ] Widget/golden/interruption/network-conditioning/memory-profile/frame-jank/mediation/IAP are N/A unless implementation touches those paths; document reason. IAP belongs to host app.
- [ ] Run targeted tests, `flutter analyze`, full SDK suite. Device smoke only if a real external-anchor transport is in scope; never send real consent data to an unapproved endpoint.
- [ ] Independent audit + score /10; push only after all applicable tests/evidence and score >9/10.

## Disposition

- No implementation change required: the journal already persists-before-delivery and replays only committed entries. A storage failure removes the unpersisted candidate rather than retaining it for a future append.
- External anchor callbacks are opt-in. Consumers needing an irreversible remote audit must deduplicate by `entryHash`, because a successful callback followed by a failed local cursor write can be delivered again after recovery.
- Widget/golden/network-conditioning/device smoke are N/A for the existing local fake callback path; do not send real consent data to an unapproved endpoint. IAP remains host-owned.

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
