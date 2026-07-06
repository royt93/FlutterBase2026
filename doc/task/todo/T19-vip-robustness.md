# T19 — VIP robustness: negative-duration, purge, cap/API clarity

- **REQ:** 5 (kích hoạt VIP by code)
- **Priority:** P2 · **Severity:** MEDIUM · **Status:** todo
- **Files:** `vip/vip_manager.dart` (`addVip`/`redeemVip`, `_purgeExpired`, `_scheduleNextExpiry`), `config/ad_config.dart` (`maxVipStackDuration` `:184`), `core/ad_manager.dart` (`showRewardedAd` `bypassVipGuard/vipAutoGrant` `:1196-1222`)

## Vấn đề (Why)
Một số điểm bền vững/tài liệu của VIP:
- `addVip` không guard `duration <= 0` → duration âm tạo entry chết âm thầm.
- Entry hết hạn tích tụ (lazy purge) — làm phình persistence.
- `maxVipStackDuration` chỉ áp cho path `stack:true` — dễ hiểu nhầm là cap tổng.
- API `bypassVipGuard`/`vipAutoGrant` (flow "xem ad → +N ngày") đúng policy nhưng tên/tài liệu dễ gây nhầm (agent từng hiểu nhầm là bypass policy).

## Acceptance criteria
- [ ] `addVip`/`redeemVip`: assert/clamp `duration > 0`; duration âm bị từ chối rõ ràng.
- [ ] Purge eager entry đã hết hạn khi load/redeem (không để rác tích tụ).
- [ ] Tài liệu hoá rõ `maxVipStackDuration` **chỉ** áp cho stacking; non-stacking không bị cap.
- [ ] Tài liệu hoá `bypassVipGuard`/`vipAutoGrant`: có hiển thị ad thật, đúng policy; cân nhắc đổi tên method rõ intent (vd `showRewardedToExtendVip`).
- [ ] (Đã đúng) timezone: `VipEntry` encode ISO8601 UTC — giữ; thêm test khẳng định.

## Test
- [ ] Unit: duration âm bị từ chối; entry hết hạn bị purge; stacking clamp tại cap; non-stacking không cap.
