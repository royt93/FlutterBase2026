# T160 — Biến nội bộ "vị trí chiếu gần nhất" không được dọn khi reset

**Loại:** bug (dọn dẹp thiếu sót, ảnh hưởng rất nhỏ)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state, tự verify
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
1 biến nội bộ ghi "vị trí vừa chiếu quảng cáo gần nhất" không được dọn sạch khi SDK reset/tắt (`destroy()`/`_resetGuardState()`). Ảnh hưởng rất nhỏ, chỉ là dọn dẹp thiếu sót, không gây lỗi thấy được cho người dùng hiện tại — nhưng khác quy ước dọn dẹp tường minh (kèm comment lý do) của mọi field cùng vòng đời khác trong file.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:8345` — `_lastShownPlacement` không được xoá trong `destroy()`/`_resetGuardState()`.

## Việc cần làm
1. Thêm dòng reset `_lastShownPlacement = null` (hoặc giá trị mặc định phù hợp) vào `destroy()`/`_resetGuardState()`, đúng vị trí và kèm comment ngắn giống các field khác trong cùng nhóm dọn dẹp.
2. Thêm test xác nhận sau `destroy()`, giá trị này về lại trạng thái ban đầu.
3. Cập nhật CHANGELOG.md (mục nhỏ, dọn dẹp nội bộ).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_manager.dart: field _lastShownPlacement (dòng ~8345) không được reset trong destroy()/_resetGuardState(), khác quy ước dọn dẹp tường minh của các field cùng vòng đời khác trong file (đọc các dòng dọn dẹp field khác để copy đúng style/comment). Thêm dòng reset field này về giá trị mặc định đúng chỗ. Viết unit test: set giá trị cho _lastShownPlacement (qua hành vi công khai, không truy cập trực tiếp field private nếu không cần), gọi destroy(), xác nhận trạng thái đã reset.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test xác nhận reset đúng sau `destroy()`.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device (destroy + re-init SDK qua demo có sẵn), xác nhận không có hành vi bất thường.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
