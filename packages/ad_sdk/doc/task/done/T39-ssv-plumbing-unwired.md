# T39 — SSV (server-side verification) plumbing có sẵn nhưng chưa wire vào host/example

- **REQ:** 3 (ad type reward không bắt buộc theo 7 yêu cầu gốc, nhưng liên quan tới tính đầy đủ)
- **Priority:** P2 · **Status:** ✅ done — phần app-side (2026-07-14). Phần server-side vẫn chờ, out of scope.
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`showRewardedAd`, `ssvCustomData`/`ssvUserId` — đã có sẵn từ trước), `packages/ad_sdk/lib/src/core/ad_screen.dart` (`AdScreenState.showRewardedAd` — **sửa mới**, xem bên dưới), `lib/mckimquyen/util/shared_preferences_util.dart` (`getOrCreateSsvUserId()` — mới), `lib/mckimquyen/widget/wifi_stressor/presentation/history_screen.dart` (nơi gọi thật, dòng ~72)

## Vấn đề (Why)
SSV cho rewarded ads (đối tác tự verify reward ở server riêng, SDK không tự chạy hay verify gì) đã có plumbing đầy đủ ở tầng `AdManager.showRewardedAd()` (`ssvCustomData`/`ssvUserId`), nhưng host app chưa từng truyền gì — luôn `null`. Duy nhất 1 nơi trong app gọi rewarded ad thật: `history_screen.dart` (xem quảng cáo để mở khóa export dữ liệu).

Khi wire thật mới phát hiện thêm 1 lỗ hổng: `history_screen.dart` không gọi `AdManager().showRewardedAd()` trực tiếp mà gọi qua wrapper `AdScreenState.showRewardedAd()` (`ad_screen.dart`, class mà mọi màn hình có ad phải kế thừa để có sẵn safety-check) — wrapper này **chưa có tham số** `ssvUserId`/`ssvCustomData`, dù `AdManager` cấp dưới đã có. Kế hoạch ban đầu giả định sai là host app gọi thẳng `AdManager`, nên bước sửa thực tế rộng hơn 1 chút: phải mở rộng cả wrapper của SDK.

## Giải pháp đã chọn
- **Host app:** thêm `getOrCreateSsvUserId()` vào `shared_preferences_util.dart` — sinh 1 lần bằng `Random.secure()` (không thêm dependency `uuid` mới) thành chuỗi hex 32 ký tự, lưu key `ssv_anonymous_user_id`, tái sử dụng cho các lần sau. ID này ẩn danh, không liên hệ tài khoản/thiết bị thật.
- `history_screen.dart`: `onPressed` của nút export đổi thành `async`, gọi `getOrCreateSsvUserId()` rồi truyền `ssvUserId: ...` vào `showRewardedAd(...)`.
- **SDK (`packages/ad_sdk`):** thêm 2 tham số optional `ssvUserId`/`ssvCustomData` vào `AdScreenState.showRewardedAd()` (`ad_screen.dart`), forward thẳng xuống lời gọi `AdManager().showRewardedAd(...)` bên trong — giữ nguyên mọi safety-check/disclosure-dialog hiện có của wrapper, chỉ thêm đường truyền dữ liệu.
- **Không** cấu hình postback URL nào (chưa có server) — `ssvCustomData` để trống, đúng hiện trạng.

## Acceptance criteria
- [x] `getOrCreateSsvUserId()` sinh ID ổn định qua các lần gọi (persist SharedPreferences), không phụ thuộc package `uuid`.
- [x] `history_screen.dart` truyền `ssvUserId` thật vào `showRewardedAd(...)`.
- [x] `AdScreenState.showRewardedAd()` (SDK) chấp nhận và forward đúng `ssvUserId`/`ssvCustomData` xuống `AdManager.showRewardedAd()`, không phá vỡ safety-check/disclosure hiện có.
- [x] Không cấu hình postback URL — phần server-side vẫn ngoài phạm vi, chờ hạ tầng riêng khi có nhu cầu.

## Verify
`flutter analyze` (root) → no issues. `cd packages/ad_sdk && flutter analyze && flutter test` → no issues, 550/550 pass. `flutter test` (root) → 79/79 pass (gồm `vip_screen_widget_test.dart`).
