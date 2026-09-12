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

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** SDK có 1 "sổ ghi nhớ" nội bộ
lưu "quảng cáo vừa chiếu ở vị trí nào" để gán đúng doanh thu cho đúng vị
trí khi có sự kiện trả tiền quảng cáo về (đôi khi tới trễ). Khi app gọi
`destroy()` (tắt SDK) hoặc gọi `initialize()` lại lần 2 mà không destroy
trước, sổ ghi nhớ này KHÔNG được xoá — khác với mọi biến tạm khác cùng
nhóm dọn dẹp trong file (tất cả đều có dòng reset + comment giải thích).
Hậu quả trên thực tế cực nhỏ (dữ liệu doanh thu của phiên MỚI có thể vô
tình bị gán nhầm theo vị trí của phiên CŨ đã kết thúc, trong 1 khoảng thời
gian cực ngắn ngay sau khi khởi động lại) — nhưng đây là 1 lỗ hổng dọn dẹp
thật, không phải giả thuyết.

**Kỹ thuật đã sửa (`ad_manager.dart`):** thêm `_lastShownPlacement.clear();`
vào cuối `_resetGuardState()` — hàm "nguồn sự thật duy nhất" mà cả
`destroy()` VÀ đường "gọi lại `initialize()` mà không destroy trước" đều
đi qua, đúng theo quy ước đã có sẵn trong file cho mọi field cùng vòng đời
khác. Cập nhật doc comment của field để làm rõ: field này "không bao giờ
xoá TRONG 1 phiên" (thiết kế cũ, đúng) nhưng VẪN PHẢI xoá ở ranh giới
phiên (destroy/reinit) — 2 quy tắc không mâu thuẫn nhau.

**Kết quả review độc lập (`codex review --uncommitted`, 1 vòng):** sạch,
không tìm ra lỗi.

**Test coverage:**
- Thêm `debugSetLastShownPlacement()` (test seam, giống style
  `debugCurrentDeviceGAID`) để set giá trị mà không cần chạy toàn bộ luồng
  hiển thị quảng cáo thật.
- `test/ad_manager_core_test.dart`: thêm 2 test mới — (1) sanity: đúng là
  cơ chế gán vị trí lúc-chiếu hoạt động (chứng minh test thực sự đo được
  điều cần đo); (2) sau `debugResetGuardState()`, sự kiện doanh thu KHÔNG
  còn bị gán nhầm theo vị trí cũ. Không sửa/breaking test cũ nào (246 test
  trong file vẫn xanh nguyên).
- Full SDK suite: 1844 test xanh.
- Full example suite: 42 test xanh.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r160_last_shown_placement_reset_test.dart` —
gọi `AdManager().destroy()` THẬT trên tiến trình app thật, xác nhận sự
kiện doanh thu phát SAU khi destroy() không còn bị gán theo vị trí của
phiên trước. PASS — lần chạy đầu tiên phát hiện 1 lỗi THẬT trong chính
bài test (không phải trong code sửa): `destroy()` thay thế hẳn
`StreamController` của `events` bằng cái mới, nên subscription đăng ký
TRƯỚC `destroy()` không còn nhận được sự kiện phát SAU đó — phải đăng ký
lại sau khi gọi `destroy()`. Đã sửa test, chạy lại PASS.

**Tự chấm điểm: 9.5/10.**
