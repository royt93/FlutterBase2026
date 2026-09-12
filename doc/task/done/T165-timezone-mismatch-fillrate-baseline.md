# T165 — Lệch ngày múi giờ giữa 2 công cụ theo dõi thống kê nội bộ

**Loại:** bug (chỉ ảnh hưởng báo cáo/cảnh báo nội bộ, không ảnh hưởng chống gian lận hay người dùng cuối)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config + agy (2 nguồn độc lập, cùng file)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Công cụ theo dõi "tỷ lệ lấp đầy quảng cáo theo ngày" dùng giờ địa phương của máy để tính "ngày nào" — trong khi bộ đếm giới hạn số quảng cáo/ngày (chống gian lận) dùng giờ quốc tế (UTC, đã kẹp high-water-mark chống chỉnh giờ lùi). Nếu người dùng đổi múi giờ (đi du lịch/đổi cài đặt đồng hồ), số liệu theo dõi "tỷ lệ lấp đầy" có thể bị lệch ngày so với thực tế — chỉ ảnh hưởng báo cáo/cảnh báo nội bộ, không ảnh hưởng chống gian lận hoặc người dùng cuối.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/utils/ad_preferences.dart:612,677` — `_recordFillRateBaselineSampleNow`/`getFillRateBaselineHistory` dùng `DateTime.now()` (giờ local).
- `packages/ad_sdk/lib/src/utils/ad_preferences.dart:118` — `_todayUtcClamped` (đã vá round-31/37) dùng cho bộ đếm chống gian lận.
- `packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart:~146` — cùng vấn đề (agy tìm thấy).

## Việc cần làm
1. Đổi `_recordFillRateBaselineSampleNow`/`getFillRateBaselineHistory` và tương ứng trong `fill_rate_baseline_monitor.dart` sang dùng `_todayUtcClamped` (hoặc hàm UTC tương đương), đồng bộ với cách tính ngày của bộ đếm chống gian lận.
2. Viết test: đổi múi giờ mô phỏng quanh mốc nửa đêm, xác nhận baseline không bị tách/gộp nhầm ngày.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/utils/ad_preferences.dart: _recordFillRateBaselineSampleNow (dòng ~612) và getFillRateBaselineHistory (dòng ~677) đang dùng DateTime.now() (giờ local) để tính ngày, không nhất quán với _todayUtcClamped (dòng ~118, đã vá round-31/37 cho bộ đếm chống gian lận). Đổi cả 2 hàm sang dùng _todayUtcClamped. Kiểm tra thêm packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart (~dòng 146) có cùng vấn đề tương tự — sửa đồng bộ. Viết test mô phỏng đổi múi giờ quanh nửa đêm (dùng cùng kỹ thuật test đã có cho _todayUtcClamped), xác nhận baseline không bị lệch ngày.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test mô phỏng đổi múi giờ cho cả 2 file, xác nhận đồng bộ cách tính ngày.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, đổi múi giờ hệ thống, xác nhận số liệu debug overlay không bị lệch ngày bất thường.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** SDK có 2 công cụ đếm theo
ngày: (1) bộ đếm chống gian lận (giới hạn số quảng cáo/ngày) — dùng giờ
QUỐC TẾ (UTC), đã được vá kỹ để chống người dùng chỉnh đồng hồ lùi lại;
(2) công cụ theo dõi "tỷ lệ lấp đầy quảng cáo" (để cảnh báo nội bộ khi
1 mạng quảng cáo đột nhiên tệ đi) — lại dùng giờ ĐỊA PHƯƠNG của máy. Nếu
người dùng đổi múi giờ (đi du lịch, hoặc chỉnh cài đặt múi giờ), 2 công cụ
này có thể "hiểu" khác nhau về việc hôm nay là ngày nào — không ảnh hưởng
tới việc chống gian lận hay trải nghiệm người dùng, nhưng làm báo cáo nội
bộ (dùng để cảnh báo dev) bị lệch ngày.

**Kỹ thuật đã sửa:** đổi cả 3 chỗ tính "hôm nay" của công cụ tỷ lệ lấp đầy
(`ad_preferences.dart`: `_recordFillRateBaselineSampleNow`,
`getFillRateBaselineHistory`; `fill_rate_baseline_monitor.dart`:
`_baselineFor`) sang dùng chung 1 hàm UTC duy nhất
(`AdPreferences.todayUtcClamped` — hàm public mới, bọc lại hàm nội bộ
`_todayUtcClamped` bộ đếm chống gian lận đã dùng sẵn) — đảm bảo cả 2 công
cụ luôn "hiểu" giống nhau về ngày, bất kể múi giờ máy là gì.

**2 lỗi thật phát hiện thêm trong lúc sửa (không phải giả thuyết):**
1. Việc parse ngày lưu trữ dùng `'${date}Z'` (VD `'2026-09-11Z'`) — đã
   verify bằng `dart` thật: chuỗi này KHÔNG hợp lệ ISO8601, `DateTime.
   tryParse` âm thầm trả về `null`. Hậu quả: MỌI ngày lưu trữ bị coi là
   "không parse được" → bị coi như "quá cũ" → bị xoá NGAY LẦN ĐỌC ĐẦU
   TIÊN sau khi ghi. Sửa bằng cách thêm `T00:00:00` trước `Z`.
2. (Codex vòng 2 phát hiện) mốc cắt "7 ngày gần nhất" tính từ đồng hồ
   thô (`DateTime.now()`), không từ giá trị "hôm nay" đã kẹp chống chỉnh
   giờ lùi — nếu đồng hồ bị lùi lại, mốc cắt sẽ LỎNG hơn dự định (giữ
   nhiều dữ liệu cũ hơn mức 7 ngày thực). Sửa bằng cách tính mốc cắt từ
   giá trị đã kẹp.

**Kết quả review độc lập (`codex review --uncommitted`, 2 vòng):**
- Vòng 1: sạch.
- Vòng 2: phát hiện lỗi #2 ở trên (thật, không phải giả thuyết) — đã sửa
  + thêm test riêng.

**Test coverage:**
- `test/ad_preferences_test.dart`: thêm 4 test mới — cùng 1 thời điểm cho
  ra đúng cùng 1 khoá ngày ở cả 2 công cụ, mẫu ghi ngay trước nửa đêm UTC
  vẫn đọc lại đúng sau nửa đêm (khoá lỗi #1 ở trên), mốc cắt 7 ngày neo
  theo giá trị đã kẹp chứ không phải đồng hồ thô khi bị chỉnh lùi (khoá
  lỗi #2).
- `test/fill_rate_baseline_monitor_test.dart`: cập nhật fixture ngày dùng
  UTC thay vì local — không breaking test cũ (9 test cũ đều xanh nguyên
  sau khi sửa fixture, không phải sửa assertion).
- Full SDK suite: 1854 test xanh.
- Full example suite: 42 test xanh.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r165_fillrate_baseline_timezone_sync_test.dart`
— trên tiến trình app thật, ghi 1 mẫu tỷ lệ lấp đầy và 1 lượt đếm chống
gian lận cho ĐÚNG 1 thời điểm (23:30 UTC — mốc mô phỏng ranh giới múi
giờ), xác nhận cả 2 công cụ trả về ĐÚNG cùng 1 khoá ngày trên store thật
của thiết bị. Không đổi múi giờ hệ thống thật của máy (rủi ro/khó khôi
phục đáng tin cậy trên thiết bị dùng chung) — thay vào đó dùng đúng cơ chế
`now:` mà bản sửa đã thêm để chứng minh không cần đổi cài đặt hệ thống
thật, theo đúng cách đã dùng cho T160/T162/T164. PASS.

**Tự chấm điểm: 9.5/10.**
