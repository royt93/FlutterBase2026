# T286 — Khôi phục external-anchor callback sau journal write failure

- **Loại:** Enhancement / Audit evidence reliability
- **Priority:** P2 · **Severity:** MEDIUM
- **Confidence:** Confirmed behavior gap; external anchor is opt-in
- **Status:** done (2026-11-15)
- **Evidence:** `lib/src/compliance/consent_provenance_journal.dart`; `lib/src/utils/ad_preferences.dart`; `test/consent_provenance_journal_test.dart`; `test/consent_manager_provenance_test.dart`; commits `7d7bd0e` and `25a66ef`
- **Delivery contract:** At-least-once, oldest-first replay; host deduplicates by stable `entryHash`. Existing history is baseline on first callback-enabled load. Callback delivery does not block consent mutations.

## Bối cảnh & vấn đề

`ConsentProvenanceJournal._appendLocked()` appends entry to in-memory `_entries`, then persists the entire list, and only after successful persistence calls optional `onEntryAppended`. If persistence fails, consent flow now continues under T285, and the entry remains in memory. A later successful append can persist both entries, but `onEntryAppended` fires only for the later entry; an external anchor can permanently miss the earlier entry that is now in the local journal. This does not block consent or corrupt the local hash chain, but may weaken externally anchored audit completeness.

## Phạm vi

1. Confirm external-anchor consumers expect every persisted journal entry exactly once, including entries whose first write failed.
2. Define delivery semantics: at-least-once with stable entry hash/idempotency, or explicit retry/pending state; do not silently promise exactly-once over a fallible external callback.
3. Reconcile disk persistence and callback delivery ordering. Preserve consent best-effort behavior: neither journal storage nor external callback failure may block `_setInternal()`/`_resetInternal()`.
4. Avoid duplicate callback delivery for entries already externally anchored when a later whole-journal persist succeeds.
5. If partner use case does not need recovery/replay, close with a documented limitation and no code change.

## Acceptance criteria

- [x] Reproduced persistence failure and recovery; regressions assert persisted entries and callback delivery.
- [x] Contract is at-least-once, oldest-first, with host deduplication by stable `entryHash` and baseline of pre-opt-in history.
- [x] Delivery retries after failure and preserves order; duplicate delivery is possible at the external-success/local-ack boundary by design.
- [x] Storage/callback failures, concurrent append, retry, and `clear()` races do not block consent or corrupt subsequent state.
- [x] Hash chain and persisted contents covered across failure/recovery paths.
- [x] Unit regressions cover callback/storage failure, malformed/out-of-range checkpoint recovery, false writes, retry and clear races.
- [x] Widget/golden/device/performance/mediation/IAP N/A: no UI, transport, native provider or ad behavior changed; no real consent data was sent externally.
- [x] Targeted tests, analyzer, full SDK suite and Android AdMob smoke passed: 31 journal tests; 11 manager tests; 2869 SDK tests; smoke used an isolated temporary package ID and Google test ads.
- [x] Final review found no actionable findings; commits `7d7bd0e` and `25a66ef` pushed to `origin/main`.

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
