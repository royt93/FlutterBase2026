# P42 — `copyWith` không thể set `roomTag`/`thermalStatus` về `null`

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/models/test_result.dart:121,160-161`, `models/network_info.dart:29,37-41`

## Vấn đề
`TestResult.copyWith`/`NetworkInfo.copyWith` dùng pattern `field ?? this.field` — không có cách truyền `null` có chủ đích để **xoá** giá trị field (khác với "không truyền tham số này"). Cản trở tính năng "gỡ room tag đã gắn" ([[P24-retro-tag-room-history]] cần khả năng này).

## Việc cần làm (đề xuất, chưa code)
- Đổi `copyWith` sang pattern sentinel (VD dùng `Object? roomTag = _unset` với hằng sentinel riêng, hoặc field `bool clearRoomTag = false`) để phân biệt "không đổi" và "đổi thành null".

## Acceptance criteria
- [ ] Gọi `copyWith` với chủ đích xoá `roomTag` → kết quả field thực sự là `null`, không rơi lại giá trị cũ.
- [ ] Không phá vỡ các lời gọi `copyWith` hiện có (giữ default behaviour "không đổi" khi không truyền tham số).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm ticket này trước [[P24-retro-tag-room-history]] — P24 phụ thuộc trực tiếp vào sentinel pattern ở đây để code đúng flow gỡ/sửa room tag.
