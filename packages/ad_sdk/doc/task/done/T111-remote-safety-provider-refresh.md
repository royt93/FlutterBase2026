# T111 — Enhancement: RemoteAdSafetyProvider thiếu đường re-fetch định kỳ

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `lib/src/config/remote_ad_safety_provider.dart`, `lib/src/core/ad_manager.dart:2156-2168`

## Vấn đề

`fetchSafetyParamOverrides()` chỉ được gọi 1 lần bên trong `initialize()`. Muốn áp giá trị remote mới, host phải `destroy()`+`initialize()` lại toàn bộ SDK — nặng hơn nhiều so với `VipRevocationProvider` (T95) vốn có `refreshRevocationList()` gọi được bất cứ lúc nào không cần re-init.

## Việc cần làm

- [x] Thêm `AdManager().refreshRemoteSafetyParams()` public, mirror đúng pattern `refreshRevocationList` (fail-open, giữ giá trị cũ nếu lỗi) — dùng `AdSafetyConfig.updateParams()` mới (chỉ swap `_params`, không đụng `_suspiciousViolationCount`/`_sessionStartTime` như `init()` làm)
- [x] Test: refresh thành công áp giá trị mới; refresh lỗi giữ nguyên giá trị cũ, không throw — `test/refresh_remote_safety_params_test.dart` (3 test, mutation-verified: revert `refreshRemoteSafetyParams()` thành no-op → 2/3 đỏ đúng chỗ, áp lại → xanh)

## Đã làm

Field mới `_remoteSafetyProvider` lưu provider từ `initialize()`, clear trong `destroy()`. Method mới đọc `_config`/`_remoteSafetyProvider`, fail-open ở mọi bước (fetch throw/null/timeout 5s, hoặc `_config` bị null hoá giữa chừng bởi 1 `destroy()` khác). `AdSafetyConfig.updateParams()` mới (không phải `init()` đầy đủ) để không reset session đang chạy.

Test viết ở file riêng (`test/refresh_remote_safety_params_test.dart`), không phải trong `ad_manager_core_test.dart`'s "remoteSafetyProvider (T88)" group — thêm test ở đó gây lỗi *deterministic* (không phải flaky) từ tương tác với 1 test có sẵn ("provider slower than 5s timeout") để lại 1 lời gọi `google_mobile_ads` thật chưa hoàn tất. File mới dùng `debugSetAdapter`/`debugConfig` test seam thay vì `AdManager().initialize()` thật — không cần chạm `AdMobAdapter`/plugin thật, nhanh hơn và né được toàn bộ lớp vấn đề đó.
