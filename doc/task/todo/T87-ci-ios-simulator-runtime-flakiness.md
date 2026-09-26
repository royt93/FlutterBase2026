# T87 — Tối ưu thời gian/flakiness CI iOS Simulator

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P2 · **Status:** 🔲 blocked
- **Files:** `.github/workflows/test.yml:143-270`, `.github/scripts/integration-retry.sh`

## Vấn đề

Job `sdk-integration-ios` từng mất ~16-18 phút sau khi shard 3 runner. Cache Flutter/CocoaPods đã được thêm; không đổi logic boot/retry khi chưa có số đo CI thật.

## Acceptance criteria

- [ ] Đo thời gian GitHub Actions trước/sau trên CI thật.
- [ ] Thời gian giảm rõ rệt, không tăng flakiness.

## Bằng chứng local (2026-09-26)

- `example/integration_test/t220_owner_decisions_device_test.dart` pass trên iOS Simulator `AdSdkTest-iPhone16` (iOS 18.6).
- Bao phủ AVP2 online, AVP1 default reject + opt-in accept, offline activation reject, QA fleet và COPPA consent mapping.
- Đây là smoke test correctness local, **không** đo timing hoặc flakiness GitHub Actions nên không đóng ticket.

## Chặn hiện tại

GitHub Actions job không bắt đầu do billing/spending limit. `gh run view 35108276470` báo:

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings.

Cần owner khôi phục billing tại https://github.com/settings/billing, sau đó trigger CI và đo lại qua `gh run view`.
