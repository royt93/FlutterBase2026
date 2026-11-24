# T293 — Phát hiện từ audit lớp safety (cap / throttle / vi phạm), chờ quyết định

- **Loại:** Hardening / quyết định sản phẩm
- **Priority:** P2 · **Severity:** MEDIUM (chạm bảo vệ tài khoản AdMob và doanh thu)
- **Status:** todo — CHỜ QUYẾT ĐỊNH. Chưa sửa gì trong file này.

Audit chỉ-đọc ngày 2026-11-23. Điểm 2 (hộp thoại Loading rồi không có quảng cáo) đã sửa và có test đỏ-xanh. Các điểm dưới đây chưa sửa vì đều là đánh đổi giữa bảo vệ tài khoản và độ bền, hoặc đổi hành vi host nhìn thấy.

## Điểm 5 — Resume App Open dùng placement `splash` (ĐÃ TÁI HIỆN, test đang `skip`)

`showAppOpenAd` mặc định `AdPlacement.splash`, và hai đường resume gọi nó không truyền placement. Khi host đặt `maxPerPlacementAdsPerDay: {AdPlacement.splash: 1}` (đúng ví dụ trong README) thì quảng cáo splash dùng hết cap, và mọi App Open resume sau đó bị chặn tới hết ngày UTC với lý do `placement_cap`.

Test: `test/ad_manager_core_test.dart` → "a per-day cap on the splash placement still lets a resume App Open show" (đang `skip`; bỏ skip thì đỏ).

Hướng sửa cần chọn: truyền một placement riêng cho resume (ví dụ `AdPlacement.custom('app_open_resume')`) ở hai chỗ gọi và ở `_placementMinIntervalOverride` (T181 cố ý dùng splash cho khớp). Tác dụng phụ: `AdShowEvent.placement` và doanh thu ghi theo placement mới; mọi override đặt theo `splash` trong `PlacementRegistry` sẽ không còn áp dụng cho resume. Ràng buộc: `ad_manager.dart` chỉ dư ~4 byte dưới trần dung lượng.

## Điểm 1 — Đồng hồ nhảy tiến khóa cap ngày vĩnh viễn

`_todayUtcClamped` lưu mốc ngày cao nhất đã thấy và không bao giờ hạ. Đồng hồ máy đọc 2030 một lần (NTP lỗi, người dùng đổi ngày) rồi trở lại bình thường thì mốc kẹt ở 2030, bộ đếm ngày không bao giờ sang ngày mới, `dailyCapReached()` chặn mọi quảng cáo fullscreen. Chỉ `clearSdkData` hoặc xóa dữ liệu app gỡ được. Đã có test ghi rõ đây là đánh đổi có chủ đích của round-37 (hạ mốc sẽ mở lại lỗ hổng reset cap bằng cách tua lùi đồng hồ). Cần quyết định: giới hạn mốc không được vượt quá N ngày so với đồng hồ thật, hay chấp nhận.

## Điểm 3 — Số lần vi phạm đáng ngờ không suy giảm qua các lần khởi động

`_lastViolationTimestamp` không được lưu, bắt đầu bằng 0 mỗi tiến trình, nên `_decayViolationCount` thoát ngay. Người dùng bình thường vấp cổng CTR/click-spam mỗi tuần một lần ở tiến trình mới thì bộ đếm chỉ tăng, thời gian tạm dừng leo từ 30 phút lên trần 24 giờ. Mâu thuẫn với comment hứa suy giảm theo nửa mỗi 24 giờ.

## Điểm 4 — Force-stop rồi mở lại xóa tạm dừng lưu lượng không hợp lệ đang hoạt động

`_suspiciousPauseUntil`, `_hourlyAdTimestamps`, `_lastFullscreenAdTime` chỉ nằm trong RAM; `resetSession` cũng đặt về 0. Click spam kích hoạt tạm dừng 24 giờ, người dùng force-stop và mở lại thì quảng cáo chạy tiếp. Chỉ số lần leo thang sống sót.

## Điểm 6 — Đồng hồ lùi chặn quảng cáo fullscreen tới lần khởi động kế (độ tin cậy thấp)

`elapsed` âm làm `elapsed < minInterval` đúng, và `removeWhere(now - t > 3600000)` không xóa gì nên cap giờ cũng giữ. Bước lùi nhỏ ít tốn, bước lùi lớn tốn nhiều; trạng thái chỉ trong RAM.

## Acceptance Criteria (khi quyết định làm)

- [ ] Mỗi điểm được làm có một test đỏ trên bản hiện tại trước khi sửa.
- [ ] Không làm yếu bảo vệ tài khoản: tua lùi đồng hồ vẫn không reset được cap (test round-37 vẫn xanh).
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh (mind: ~4 byte ở `ad_manager.dart`).
- [ ] CHANGELOG ghi rõ.
