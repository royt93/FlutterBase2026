# T17 — Trial hardening: anti clock-rollback + footgun nếu grace tắt

- **REQ:** 4 (trial mode 1 ngày)
- **Priority:** P1 · **Severity:** HIGH · **Status:** done
- **Files:** `vip/vip_entry.dart` (`isActive` `:22`), `vip/vip_manager.dart`, `vip/_first_install_guard.dart`, `core/ad_manager.dart` (grace `:492-541`), `core/ad_manager.dart` (`releaseFootgunWarnings`)

## Vấn đề (Why)
Trial 1 ngày đã có (`FirstInstallVipGrace.day`). Nhưng:
- `VipEntry.isActive` chỉ so `now.isBefore(expiresAt)` (wall-clock). User **chỉnh đồng hồ lùi** → entry đã hết hạn "sống lại". `grantedAt` được lưu nhưng không dùng để phát hiện lùi giờ.
- Release nếu `firstInstallVipGrace.disabled` thì trial biến mất **âm thầm**, không cảnh báo.

## Acceptance criteria
- [x] Phát hiện clock rollback: nếu `now < grantedAt` (đồng hồ lùi so với lúc cấp) → coi entry đã tiêu thụ / không active.
- [x] Cân nhắc dùng thời điểm cấp làm mốc bất biến để tính hết hạn (hạn chế cả lùi lẫn tiến giả).
- [x] `releaseFootgunWarnings` cảnh báo nếu `firstInstallVipGrace` bị disable ở release (partner có thể vô tình tắt trial).
- [x] Giữ nguyên anti-reinstall (Keychain iOS / Android conservative) — không hồi quy.

## Ghi chú kỹ thuật
- Không thể chống 100% clock manipulation offline; mục tiêu là chặn khai thác đơn giản (lùi giờ) + fail-safe.

## Test
- [x] Unit: entry hết hạn + set now lùi < grantedAt → vẫn inactive.
- [x] Unit: grace disabled ở release → có footgun warning.
