# T19 — VIP robustness: negative-duration, purge, cap/API clarity

- **REQ:** 5 (kích hoạt VIP by code)
- **Priority:** P2 · **Severity:** MEDIUM · **Status:** done
- **Files:** `vip/vip_manager.dart` (`addVip`/`redeemVip`, `_purgeExpired`, `_scheduleNextExpiry`), `config/ad_config.dart` (`maxVipStackDuration` `:184`), `core/ad_manager.dart` (`showRewardedAd` `bypassVipGuard/vipAutoGrant` `:1196-1222`)

## Vấn đề (Why)
Một số điểm bền vững/tài liệu của VIP:
- `addVip` không guard `duration <= 0` → duration âm tạo entry chết âm thầm.
- Entry hết hạn tích tụ (lazy purge) — làm phình persistence.
- `maxVipStackDuration` chỉ áp cho path `stack:true` — dễ hiểu nhầm là cap tổng.
- API `bypassVipGuard`/`vipAutoGrant` (flow "xem ad → +N ngày") đúng policy nhưng tên/tài liệu dễ gây nhầm (agent từng hiểu nhầm là bypass policy).

## Acceptance criteria
- [x] `addVip`/`redeemVip`: assert/clamp `duration > 0`; duration âm bị từ chối rõ ràng.
- [x] Purge eager entry đã hết hạn khi load/redeem (không để rác tích tụ).
- [x] Tài liệu hoá rõ `maxVipStackDuration` **chỉ** áp cho stacking; non-stacking không bị cap.
- [x] Tài liệu hoá `bypassVipGuard`/`vipAutoGrant`: có hiển thị ad thật, đúng policy. Không đổi tên `showRewardedAd`/`bypassVipGuard` — `showRewardedAd` được dùng xuyên suốt SDK (adapter/bridge/ad_screen/host app, 25+ call sites); rename sẽ là diff cơ học lớn cho task P2/MEDIUM. Thay vào đó tăng cường doc comment tại chỗ định nghĩa.
- [x] (Đã kiểm tra, KHÔNG đúng như mô tả) `VipEntry` thực tế encode ISO8601 theo **local time** (từ `DateTime.now()`), không phải UTC — không có suffix `Z`. Round-trip qua `DateTime.parse` vẫn giữ đúng instant tuyệt đối (an toàn), nên không phải bug, nhưng đã sửa doc comment cho đúng thực tế thay vì khẳng định sai là UTC. Đã thêm test khẳng định round-trip.

## Test
- [x] Unit: duration âm bị từ chối; entry hết hạn bị purge; stacking clamp tại cap; non-stacking không cap.
- [x] Unit: ISO8601 round-trip (UTC input và local `DateTime.now()` input) giữ đúng instant — `packages/ad_sdk/test/vip_manager_robustness_test.dart`.
