# T284 — Flight Recorder clear contract investigation

- **Type:** Contract investigation
- **Priority:** P3 · **Severity:** LOW
- **Confidence:** Existing behavior is explicit; no confirmed defect or consumer requirement for durable `clear()`.
- **Status:** no-change (2026-11-15); keep `AdFlightRecorder.clear()` RAM-only.
- **Evidence:** `lib/src/compliance/ad_flight_recorder.dart:329-389, 391-415, 544-549`; `lib/src/core/ad_manager.dart:1646-1669`; `test/ad_flight_recorder_test.dart:39-48, 450-492`; `test/ad_manager_flight_recorder_test.dart:251-279`; `doc/AD_PROMPT_FLUTTER.MD:3514-3516`.

## Findings

- `AdFlightRecorder.clear()` synchronously clears `_entries` and `_lastHash`; it does not call persistence or cancel `_debounceTimer`. This explicitly resets the in-memory chain only.
- A pre-existing debounce timer remains active after direct `clear()`. When it fires, `_persistNow()` serializes the current entries: the empty snapshot if there was no later record, or the new post-clear entries if there was one.
- If direct `clear()` has no pending debounce timer, persisted data remains unchanged. A new recorder attached before any later persist can therefore reload the old snapshot. That is consistent with the documented RAM-only contract, not durable erasure.
- `AdManager.clearSdkData()` is the durable-erasure API: it clears SDK preference data first, then clears live recorder state so erased data is not restored or exposed from RAM.
- Existing tests pin direct clear's chain-anchor reset and record-after-clear validity. Recorder tests cover persistence reload/flush; manager tests cover live-state clearing via `clearSdkData()`. No API or runtime change is justified without a concrete consumer requirement for durable clear.
- `doc/AD_PROMPT_FLUTTER.MD` already warns that stopping collection is not privacy purge and directs consumers to the scoped erasure workflow.

## Decision

No-change. Keep `AdFlightRecorder.clear()` synchronous and RAM-only; use `AdManager.clearSdkData()` for durable SDK data erasure. Reopen only if a consumer presents a concrete need for a direct durable-clear operation. Any future API change must define async completion, debounce/flush ordering, and protection against erasing records written after the clear request.

## Test matrix

- **Unit:** existing direct-clear chain-anchor test and persistence reload/flush tests reviewed; no runtime change, so no additional test required.
- **Widget/golden/integration/device/interruption/network/memory/profile/frame-jank/mediation:** N/A — no behavior/API change. Native persistence path unchanged. IAP is host-app scope.
- `git diff --check` is the applicable validation for this ticket disposition.
