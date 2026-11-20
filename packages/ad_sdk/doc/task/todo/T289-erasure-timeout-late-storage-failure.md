# T289 — Verify late storage failure after clearSdkData timeout

- **Type:** Privacy-erasure follow-up / behavior clarification
- **Priority:** P3 · **Severity:** LOW / unconfirmed host-impact
- **Status:** Open — timeout/order behavior published in 3.7.5; caller-error contract after a late failure needs host-level review.
- **Evidence:** `lib/src/core/ad_manager.dart` (`clearSdkData`, underlying erasure completion); `lib/src/utils/ad_preferences.dart` (flight-key FIFO and erasure depth); timeout regressions in `test/ad_manager_flight_recorder_test.dart`; README scoped-erasure section.

## Hypothesis and boundary

After the 30-second caller deadline, `clearSdkData()` has already returned `TimeoutException`. The underlying erasure keeps running with Flight Recorder paused. If storage later fails, the failure is logged (subject to `SafeLogger` level/tag filter) and the erasure gate is released when the operation completes. The original caller cannot receive that later result through the already-timed-out Future. The current contract says timeout means **unconfirmed**, never success.

No data resurrection or successful-delete lie after timeout has been reproduced. This ticket asks whether hosts need an explicit durable status/query or callback; do not add one without a concrete consumer requirement. Do not retry by clearing the FIFO or opening the gate early.

## Acceptance criteria before changing runtime

- [ ] Ask a host integration owner whether a durable post-timeout completion/error signal is needed; current logs are not guaranteed visible under all filters.
- [ ] Demonstrate the exact late-failure path with controlled storage and record whether data remains, gate state, subsequent write ordering and surfaced error.
- [ ] If host can safely treat timeout as unconfirmed and retry only after app/platform recovery, close no-change and clarify docs. If a stronger result channel is required, specify its lifecycle, persistence and ownership before designing an API.
- [ ] Preserve “timeout is not success”; no timeout may release the gate while an old write/remove can still land. Add regression, independent review and targeted/full tests for any approved change.

## Out of scope

No arbitrary timeout-based cancellation, no claiming platform storage can be interrupted, no change to erasure scopes or shared-preference FIFO, no legal-compliance guarantee. No runtime fix or release without owner approval.
