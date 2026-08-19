# T45 — 6 demo page mới trong example app chưa có integration test

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P2 (không block release, nhưng các surface này không có regression coverage tự động) · **Status:** ✅ done (2026-07-19)
- **Files:** `packages/ad_sdk/example/integration_test/` (15 file hiện có), `packages/ad_sdk/example/lib/main.dart`

## Vấn đề (Why)
`example/integration_test/` có 15 file test nhưng 6 demo page sau (đều đã có UI thật trong `main.dart`, thêm dần qua các đợt audit T31-T41) **chưa có test riêng nào**:
1. Mrec demo (`MrecDemoPage`)
2. Native ad demo (`NativeDemoPage`)
3. Monetization Arbitrator demo
4. Fill-Rate Monitor demo
5. Consent-country demo
6. Diagnostics & self-check demo (`DiagnosticsDemoPage`, `main.dart:2438`)

Đây là các tính năng đã ship (không phải ý tưởng), nên thiếu test = không có tín hiệu tự động khi có regression.

## Đề xuất
Thêm 1 file `integration_test/<feature>_demo_test.dart` cho mỗi mục trên, theo pattern các test hiện có (dùng `_pumpUntil` polling nếu có tương tác secure-storage/network thật, tham khảo fix T-mới nhất trong `vip_api_playground_test.dart`). Có thể làm tuần tự, ưu tiên Diagnostics/self-check trước (dễ regress nhất vì tổng hợp nhiều subsystem).

## Acceptance criteria
- [x] Mỗi demo page trong danh sách có ít nhất 1 integration test smoke (mở page, tương tác chính, verify UI phản hồi).
- [x] `flutter test integration_test/` (example) pass trên Android thật (Pixel 7 Pro, `2B051FDH3006MU`) — mỗi file trong 6 file mới chạy riêng và pass. iOS Simulator **không** được chạy trong lượt này (ngoài phạm vi được giao — chỉ verify trên Pixel 7 Pro theo yêu cầu task).

## Đã verify (2026-07-19)
6 file test mới, mỗi file 1 demo page:
- `mrec_ad_test.dart` — MREC renders + route push/pop pause/resume (clone của banner_ad_test.dart pattern).
- `native_ad_test.dart` — Native ad demo renders without crashing.
- `monetization_arbitrator_demo_test.dart` — "Enable Smart Arbitrator" button wires a real `MonetizationArbitrator` into `AdManager()`.
- `fill_rate_monitor_demo_test.dart` — "Enable Fill-rate Monitor" button wires a real `FillRateMonitor` into `AdManager()`.
- `consent_country_demo_test.dart` — consent-country TextField + Set button reaches `ConsentManager.instance` (T27), distinct from existing `consent_dialog_test.dart` which never touches this control.
- `diagnostics_demo_test.dart` — `AdManager().diagnostics()` JSON render + `AdManager().runIntegrationSelfCheck()` async self-check renders a pass/fail result card (tolerant of either outcome since real per-slot ad fill isn't guaranteed with this example's placeholder `YOUR_*` ad-unit IDs).

Each file run individually on Pixel 7 Pro (`2B051FDH3006MU`) and passed. `diagnostics_demo_test.dart`, `mrec_ad_test.dart`, and `native_ad_test.dart` (real ad-network-dependent paths) were each run twice to confirm no systematic flakiness — both runs passed for all three (diagnostics self-check took ~80-90s per run against the network, well inside the 60s polling budget after the button tap). `consent_country_demo_test.dart` and `monetization_arbitrator_demo_test.dart`/`fill_rate_monitor_demo_test.dart` don't depend on real ad fill (synchronous object wiring), so a single run each was sufficient there but were also re-run once more without issue.

No shared polling helper was extracted — only `diagnostics_demo_test.dart` needed a `_pumpUntil`-style poll (self-check's real per-slot ad load), same as the existing one in `vip_api_playground_test.dart`; under the 3+ reuse threshold to justify a shared `test_helpers.dart`.

Found and fixed two real bugs during on-device verification (not just flakiness):
1. `find.byType(FilledButton)` cannot match `FilledButton.icon`/`.tonalIcon` buttons — Flutter's `find.byType` matches exact `runtimeType`, and those factories build a private `_FilledButtonWithIcon` subclass. Fixed by finding on the label `Text` directly in `diagnostics_demo_test.dart`.
2. `find.text(...)` on a title string that's identical between a HomePage tile and the pushed page's AppBar returns 2 matches (HomePage stays mounted offstage under `MaterialPageRoute`) — fixed by asserting `findsWidgets` instead of `findsOneWidget` post-navigation in `diagnostics_demo_test.dart`.
