# T45 — 6 demo page mới trong example app chưa có integration test

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P2 (không block release, nhưng các surface này không có regression coverage tự động) · **Status:** todo
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
- [ ] Mỗi demo page trong danh sách có ít nhất 1 integration test smoke (mở page, tương tác chính, verify UI phản hồi).
- [ ] `flutter test integration_test/` (example) pass trên cả Android thật + iOS Simulator.
