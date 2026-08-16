# T99 — Flagship: Smart Monetization Arbitrator → VIP upsell nudge khi ad value thấp (sau khi T58 fix đơn vị eCPM)

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng flagship, phụ thuộc T58) — **BLOCKED bởi T58**
- **Files:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`

## Vì sao độc quyền
Thay vì hiển thị 1 ad giá trị thấp cho user tiềm năng cao, Arbitrator (sau khi T58 fix đơn vị eCPM) có thể chủ động phân tích eCPM thực tế + tín hiệu chuyển đổi để từ chối ad rẻ tiền và gợi ý user nâng cấp VIP — tối ưu ARPU. Đây là hướng phát triển tiếp của tính năng arbitrator đã có, không phải xây từ đầu.

## Việc cần làm (đề xuất, chưa code — chờ T58 xong trước)
- [x] Sau khi T58 fix đơn vị, thiết kế hook `onLowValueAdVetoed` để app tự hiển thị nudge VIP (SDK không tự vẽ UI, chỉ emit tín hiệu).

## Đã làm (2026-08-16)

T58 đã done từ trước (`doc/task/done/T58-monetization-arbitrator-ecpm-unit-scale.md`)
nên hết block. Đọc `lib/src/monetization/monetization_arbitrator.dart` +
`lib/src/core/ad_manager.dart` phát hiện: **toàn bộ scope ticket này ĐÃ ĐƯỢC
LÀM TỪ TRƯỚC** (không rõ ở commit nào, có thể lúc làm T58 hoặc 1 batch feature
trước đó) — không phải ý tưởng chưa code như status ghi:

- `MonetizationArbitrator.decide()` đã trả `ArbitratorDecision.nudgeVip` khi
  eCPM (đơn vị đã đúng sau T58) dưới threshold, có cả nhánh
  `registerVipLikelihoodEstimator` (host cung cấp tín hiệu khả năng convert)
  và guardrail chống veto quá tay (`maxVetoRate`).
- Hook chính là `ArbitratorNudgeEvent` (`lib/src/state/ad_event.dart`) — emit
  qua `AdManager().events` tại **cả 3** điểm gọi show fullscreen:
  `showInterstitial` (dòng ~2787), `showRewardedAd` (dòng ~3031), VÀ
  `showRewardedInterstitialAd` (dòng ~3236, thêm sau bởi T89). SDK không tự vẽ
  UI — đúng yêu cầu "chỉ emit tín hiệu, app tự hiển thị nudge".
  `bypassVipGuard: true` (watch-ad-để-gia-hạn-VIP) được loại trừ khỏi veto —
  hợp lý, không nên chặn chính flow VIP dùng để gia hạn.
- README đã có sẵn mục mô tả `ArbitratorNudgeEvent` + ví dụ dùng.

**Khoảng trống thật duy nhất tìm thấy** (giống pattern T82 — vé "đã thỏa mãn"
nhưng vẫn còn 1 góc chưa phủ): `test/monetization_arbitrator_test.dart` có
test cho veto path của `showInterstitial`/`showRewardedAd` nhưng KHÔNG có cho
`showRewardedInterstitialAd` (slot T89 thêm sau). Đã đóng khoảng trống này:
- `_FakeAdapter` trong test thêm `rewardedInterstitialSlot`/
  `loadRewardedInterstitial`/`showRewardedInterstitial` thật (không dựa vào
  `noSuchMethod` — theo đúng bài học T75 đã ghi trong session này).
- 1 test mới: veto `showRewardedInterstitialAd` → native show bị skip,
  `ArbitratorNudgeEvent` phát đúng `type: AdSlotType.rewardedInterstitial`,
  `onDone(false, false)`.
- README's arbitrator section: bổ sung nhắc `showRewardedInterstitialAd`
  (trước đó chỉ nhắc `showInterstitial`/`showRewardedAd`, có thể gây hiểu
  lầm slot T89 không được arbitrator che phủ).
- `flutter analyze`: No issues found! `flutter test`: 831/831 pass.
