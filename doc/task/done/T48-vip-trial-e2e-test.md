# T48 — thiếu 1 test e2e cho VIP-trial 1-ngày qua toàn bộ init flow thật

- **REQ:** phát hiện qua audit round 6 (2026-07-19), mục "Re-audit vòng 6"
- **Priority:** P3 (coverage gap, không phải bug) · **Status:** ✅ done (2026-07-19)
- **Files:** `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
`FirstInstallVipGrace` (trial 1-ngày tự động kích hoạt VIP ở lần cài đặt đầu) chỉ được test qua `addVip()`/`VipManager` gọi cô lập. Không có test nào gọi `AdManager().initialize()` thật (với config mặc định/thực tế) rồi assert `vip.isActive`/`activeListenable` để xác nhận trial thực sự tự kích hoạt qua toàn bộ luồng init thật (guard check trong `ad_manager.dart`, `AdPreferences` flag, `FirstInstallGuard`...).

## Đề xuất
Thêm 1 test trong `ad_manager_core_test.dart` gọi `AdManager().initialize()` với `FirstInstallVipGrace.day`, sau đó assert `vip.isActive`, `activeListenable.value`, và `expiresAt` còn lại ~23-24h.

## Acceptance criteria
- [x] Test gọi `AdManager().initialize()` thật (không mock `VipManager`/`addVip` trực tiếp).
- [x] Assert `vip.isActive == true` và `activeListenable.value == true` sau init.
- [x] `flutter test` (packages/ad_sdk) pass toàn bộ, không regression.

## Đã verify (2026-07-19)
Thêm test mới trong `ad_manager_core_test.dart` (group "T48: first-install VIP grace fires through the real init flow"). Phát hiện thêm 1 gotcha: `AdPreferences` cache instance dạng static singleton — nếu không gọi `AdPreferences.resetForTest()` trong `setUp()`, state (`markFirstInstallGraceApplied()`) từ 1 test trước rò rỉ sang, khiến grant silently no-op khi chạy full file (dù pass khi chạy cô lập). Fix bằng cách thêm `AdPreferences.resetForTest()` vào `setUp()`. `flutter test` (packages/ad_sdk): 645/645 pass (644 → 645, +1 test mới), không regression.
