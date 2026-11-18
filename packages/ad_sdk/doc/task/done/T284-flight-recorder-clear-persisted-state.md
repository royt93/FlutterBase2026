# T284 — Flight Recorder clear contract investigation

- **Type:** Contract investigation
- **Priority:** P3 · **Severity:** LOW
- **Status:** done (direct-clear decision 2026-11-15; records consolidated and follow-up clarified 2026-11-18).
- **Disposition:** Keep synchronous `AdFlightRecorder.clear()` RAM/hash-only. Durable privacy erasure uses `AdManager.clearSdkData()`. Reopen direct durable clear only for a concrete consumer requirement.
- **Evidence:** `lib/src/compliance/ad_flight_recorder.dart` (`clear`, `_gen`, `_sync`, `_persistNow`); `lib/src/utils/ad_preferences.dart` flight-key FIFO; `lib/src/core/ad_manager.dart` (`clearSdkData`, `_eraseSdkData`); `test/ad_flight_recorder_test.dart`; `test/ad_manager_flight_recorder_test.dart`; `example/integration_test/t200_clear_sdk_data_test.dart`.

## Contract and findings

- Direct `clear()` empties entries and resets the hash anchor synchronously; it does not promise to remove persisted bytes. With no later persist, another recorder can reload the old disk snapshot. A pending debounce serializes current RAM, not a captured old entry.
- Follow-up in published 3.7.4 added `_gen` fencing: `record()`/`recordPair()` work admitted before direct clear or SDK erasure cannot append after that boundary. Direct clear still has no async signature or durable-delete guarantee.
- The original no-change decision concerned direct durable clear only. It must not be read as saying the later `clearSdkData()` erasure path needed no runtime change.
- SDK erasure now establishes epoch/depth guards, orders flight-key writes/removal through one FIFO, drops events arriving during erasure and resumes recording after cleanup ends. Captured old recorder references reset on epoch change. A failing flight-key removal still allows other SDK preference keys to be erased before its error is rethrown.
- `clearSdkData()` caller times out after 30 seconds, but timeout is **unconfirmed erasure**, not success. Cleanup continues; Flight Recorder stays paused until actual cleanup ends. A storage call that never returns keeps recording paused until restart. Late-error logs obey logger level/tag filters. This guarantee is Flight Recorder-specific, not all concurrent SDK writers or other isolates.
- Gated-store regression established the SDK/storage-interface ordering gap. Locked Android SharedPreferences already dispatches set/remove serially; no production Android native reordering was demonstrated.

## Acceptance / disposition

- [x] Direct-clear callsite/contract review found no consumer requiring direct disk deletion; kept RAM/hash-only API.
- [x] Existing recorder tests cover anchor reset, persistence reload and concurrent clear/record chain validity. Manager regression covers queued record invalidation, in-flight snapshot erasure, stale recorder reference, attach during erasure, fresh record after clear and overlapping erasures.
- [x] Durable-erasure ordering follow-up implemented and published in 3.7.4; the direct-clear no-change conclusion is not applied to that follow-up.
- [x] Timeout and failure tests cover caller timeout without early gate release, late cleanup failure, and cleanup draining later queued removals.
- [x] Public signature change N/A: direct `clear()` stays synchronous and no durable-clear method was added. API golden unchanged; behavior notes are in CHANGELOG/README.
- [x] Full SDK suite passed 2,906/2,906 after `b40ff4f` test/docs follow-up; analyze and release gate `all` passed. Test counts describe that checkout, not a permanent package total.
- [x] Real Android scope/host-key/secure-storage smoke: T200 passed 2 tests on TECNO KJ7 in isolated `com.roy.admobwrapper.t281qa` (2026-11-18); host package untouched. This normal-storage run does not reproduce a native stalled-write/timeout race.
- [x] Widget/golden rendering, frame/jank, memory profiling, network conditioning and mediation N/A for this record consolidation: no UI/provider/native implementation changed here. Runtime concurrency was tested in the follow-up above; IAP is host-owned.
- [x] Synthetic fixtures only; no erased evidence/consent content introduced into task records or test logs.

## Consolidation

The root discovery record and package conclusion were merged here. Root `doc/task/done/T284-flight-recorder-clear-persisted-state.md` remains a link to this record. Historical no-change wording applies only to the direct-clear API decision; 3.7.4 erasure fixes remain separately attributable to their commits/CHANGELOG.
