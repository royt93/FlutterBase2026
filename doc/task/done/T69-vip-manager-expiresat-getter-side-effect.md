# T69 — `VipManager.expiresAt` getter ghi SharedPreferences ẩn (side-effect không rõ ràng)

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:169-177`

## Vấn đề (Why)
Mỗi lần đọc `.expiresAt` sẽ `unawaited(_prefs.setVipMaxObservedClockMs(...))` (cơ chế chống clock-rollback, đúng chủ đích) trừ khi đồng hồ bị lùi. Chưa gây vấn đề thật với code hiện tại (`vip_redeem_screen.dart` không polling), nhưng là side-effect bất ngờ cho 1 getter tưởng read-only — host tự viết UI polling mỗi frame/giây sẽ ghi đĩa dư thừa.

## Đề xuất
Đổi tên hoặc doc rõ trong dartdoc rằng getter này có side-effect ghi đĩa (anti-clock-rollback), tránh polling tần suất cao ngoài dự kiến.

## Acceptance criteria
- [x] Dartdoc `expiresAt` ghi rõ side-effect.
- [ ] (Optional) throttle ghi nếu gọi liên tục trong khoảng thời gian ngắn. — bỏ qua: không có call site polling tần suất cao hiện tại (đúng như ticket ghi nhận), thêm throttle giờ là speculative, không có nhu cầu thật.

## Đã làm (2026-08-16)
Docs-only — thêm đoạn "**Side effect:**" vào dartdoc của `expiresAt` getter, nêu rõ mỗi lần đọc gọi `_effectiveNow()` ghi high-water-mark chống lùi đồng hồ xuống `SharedPreferences`, cảnh báo không nên polling tần suất cao. `flutter analyze` sạch, không cần test (docs-only, giống T61).
