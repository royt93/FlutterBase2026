# T73 — `NativeAdWidget` hỗ trợ cấu hình kích thước/template (không cố định medium/320)

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:36,139-148`

## Vấn đề (Why)
Cố định `_height = 320` và `TemplateType.medium`. Host muốn nhúng native ad vào `ListView` in-feed (template nhỏ ~90dp) không có cách cấu hình.

## Đề xuất
Cho phép truyền `TemplateType`/custom height qua constructor, giữ default hiện tại nếu không set.

## Acceptance criteria
- [ ] `NativeAdWidget(templateType: TemplateType.small)` render đúng kích thước nhỏ.
- [ ] Default không đổi khi không truyền param mới (backward-compatible).
