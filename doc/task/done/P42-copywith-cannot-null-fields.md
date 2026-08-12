# P42 — `copyWith` không thể set `roomTag`/`thermalStatus` về `null`

- **Priority:** P3 · **Severity:** — · **Status:** ✅ done (2026-08-11)
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/models/test_result.dart:121,160-161`, `models/network_info.dart:29,37-41`

## Vấn đề
`TestResult.copyWith`/`NetworkInfo.copyWith` dùng pattern `field ?? this.field` — không có cách truyền `null` có chủ đích để **xoá** giá trị field (khác với "không truyền tham số này"). Cản trở tính năng "gỡ room tag đã gắn" ([[P24-retro-tag-room-history]] cần khả năng này).

## Việc cần làm (đề xuất, chưa code)
- Đổi `copyWith` sang pattern sentinel (VD dùng `Object? roomTag = _unset` với hằng sentinel riêng, hoặc field `bool clearRoomTag = false`) để phân biệt "không đổi" và "đổi thành null".

## Acceptance criteria
- [x] Gọi `copyWith` với chủ đích xoá `roomTag` → kết quả field thực sự là `null`, không rơi lại giá trị cũ.
- [x] Không phá vỡ các lời gọi `copyWith` hiện có (giữ default behaviour "không đổi" khi không truyền tham số).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm ticket này trước [[P24-retro-tag-room-history]] — P24 phụ thuộc trực tiếp vào sentinel pattern ở đây để code đúng flow gỡ/sửa room tag.

## Kết quả (2026-08-11)
`TestResult.copyWith`: `roomTag`/`thermalStatus` đổi type thành `Object?` với sentinel mặc định `_unset` (hằng static riêng của class) — `identical(param, _unset)` phân biệt "không truyền" (giữ nguyên) với "truyền `null`" (xoá). Các tham số khác giữ nguyên pattern `?? this.field` cũ (không cần sentinel — không phục vụ nhu cầu xoá nào hiện tại, thêm vào sẽ là YAGNI). `NetworkInfo.copyWith` không sửa — không field nào ở đó cần "xoá có chủ đích" theo acceptance criteria/scope P24. Test: `test/test_result_copywith_test.dart`.
