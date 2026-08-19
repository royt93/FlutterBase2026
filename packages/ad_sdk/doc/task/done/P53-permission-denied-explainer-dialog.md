# P53 — Dialog giải thích trước khi xin quyền vị trí (giảm tỷ lệ deny vĩnh viễn)

- **Priority:** P3 · **Severity:** — · **Status:** ✅ done (2026-08-11)
- **Nguồn:** subagent đọc source (idea, đi cùng fix [[P34-location-permission-auto-open-settings]])
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/network_info_service.dart`

## Ý tưởng
Trước khi gọi `Permission.location.request()` lần đầu, user không được giải thích lý do cần quyền này (SSID trên Android chỉ đọc được khi có quyền vị trí — không phải để track vị trí thật). Thêm dialog giải thích ngắn trước request đầu tiên có thể giảm tỷ lệ user bấm "Deny" rồi sau đó "Don't ask again".

## Việc cần làm (đề xuất, chưa code)
- Thêm dialog 1 lần trước lần request đầu tiên: "Cần quyền vị trí để đọc tên WiFi (SSID) — app không dùng để theo dõi vị trí bạn".
- Kết hợp với P34: sau khi user đã từ chối vĩnh viễn, không tự mở Settings nữa mà chỉ hiện lại giải thích + nút "Mở Settings" (chủ động, không ép).

## Acceptance criteria
- [x] Lần đầu xin quyền có dialog giải thích trước, không request thẳng.
- [x] Không hiện lại dialog giải thích ở các lần sau nếu user đã quyết định (grant hoặc deny).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm chung 1 PR với [[P34-location-permission-auto-open-settings]]: bỏ auto-open Settings (P34) + thêm dialog giải thích ở đây — cùng file, cùng luồng permission.

## Kết quả (2026-08-11)
Thêm `_maybeShowExplainerDialog()` trong `network_info_service.dart`, gọi trước `Permission.location.request()` lần đầu khi `status.isDenied`; ghi flag `keyLocationPermissionExplainerShown` qua `SharedPreferencesUtil` để không hiện lại. Translation keys: `location_permission_explainer_title/message` (`en_us.dart`/`vi_vn.dart`). Test: `test/network_info_service_permission_test.dart`.
