# T162 — Tính năng dự đoán nạp trước quảng cáo âm thầm hỏng nếu tên route chứa dấu "|"

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy, tự verify đúng code thật
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Nếu 2 tính năng tự động (gom nhóm theo "signal" + theo `type`) cùng chạy và tên route/sự kiện của app có chứa dấu "|" (hiếm, nhưng có thể xảy ra nếu dev đặt tên route kiểu `/store|deal`), tính năng "dự đoán lúc nào nên nạp trước quảng cáo" (`JourneyPrefetcher`) sẽ âm thầm ngừng hoạt động cho đúng route đó — không báo lỗi, chỉ là tính năng tối ưu ngầm không còn tác dụng ở chỗ đó.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart:134-135` — `entry.key.split('|')` giả định khóa chỉ có đúng 2 phần tử `[signal, type]`; nếu `signal`/route name chứa `|`, `parts.length != 2` → `continue`, bỏ qua vĩnh viễn.

## Việc cần làm
1. Đổi cách tách chuỗi để không phụ thuộc vào số lượng dấu `|` (VD dùng `entry.key.lastIndexOf('|')` để tách đúng phần `type` ở cuối, phần còn lại luôn là `signal` dù có chứa `|`).
2. Thêm test: signal chứa dấu `|` (VD `'/store|deal'`), xác nhận vẫn khớp đúng và tính rolling average bình thường.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart dòng ~134-135: entry.key.split('|') giả định đúng 2 phần tử [signal, type], nếu signal/route name chứa dấu '|' thì parts.length != 2 khiến continue bỏ qua vĩnh viễn signal đó. Đổi sang dùng lastIndexOf('|') để tách đúng phần type ở cuối chuỗi, phần còn lại (có thể chứa '|') luôn là signal — không phụ thuộc số lượng dấu '|' trong key. Kiểm tra chỗ tạo key ban đầu (nơi ghép signal+type thành key) để đảm bảo logic tách khớp đúng logic ghép. Viết unit test: signal = '/store|deal', xác nhận JourneyPrefetcher vẫn match và tính _timeToShow đúng.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho signal chứa dấu `|`.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với route đặt tên có dấu `|`, xác nhận tính năng dự đoán nạp trước vẫn hoạt động (log/debug overlay xác nhận).
7. Thành công: commit + push. Thất bại: quay lại bước 1.
