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

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** `JourneyPrefetcher` là tính
năng tự học "sau tín hiệu X (VD người dùng vào màn hình cửa hàng) thì
khoảng bao lâu sau quảng cáo mới thực sự hiện ra" để biết lúc nào nên bắt
đầu nạp trước quảng cáo cho kịp. Nó lưu dữ liệu bằng cách ghép chuỗi
`"tín_hiệu|loại_quảng_cáo"` rồi tách lại bằng dấu `|`. Nếu tên tín hiệu
(hoặc tên route, khi dùng chế độ tự động theo route) chính nó lại chứa
dấu `|` (VD `/store|deal`), chuỗi ghép ra có nhiều hơn 2 phần, và code cũ
chỉ chấp nhận đúng 2 phần — mọi tín hiệu như vậy bị bỏ qua VĨNH VIỄN,
không có thông báo lỗi gì cả. Hậu quả: tính năng tối ưu này âm thầm không
hoạt động cho route/tín hiệu đó, quảng cáo vẫn hiện bình thường nhưng mất
đi lợi ích "nạp trước đúng lúc".

**Kỹ thuật đã sửa (`journey_prefetcher.dart:134-146`):** đổi từ tách
theo TẤT CẢ dấu `|` sang chỉ tách tại dấu `|` CUỐI CÙNG
(`lastIndexOf('|')`) — vì phần loại quảng cáo (`type.name`) luôn được
ghép vào SAU CÙNG khi tạo khóa (`_key()`), nên phần còn lại phía trước,
dù chứa bao nhiêu dấu `|`, luôn chính xác là tín hiệu gốc.

**Kết quả review độc lập (`codex review --uncommitted`, 1 vòng):** sạch,
không tìm ra lỗi.

**Test coverage:**
- `test/journey_prefetcher_test.dart`: thêm 3 test mới (nhóm "signal
  containing a literal '|' (T162)") — tín hiệu chứa 1 dấu `|` vẫn khớp
  đúng và ghi nhận mẫu, tín hiệu có tiền tố trùng với tín hiệu khác không
  bị nhầm lẫn, tín hiệu chứa NHIỀU dấu `|` vẫn được coi toàn bộ là 1 tín
  hiệu. Không sửa/breaking test cũ nào (16 test cũ vẫn xanh nguyên).
- Full SDK suite: 1837 test xanh.
- Full example suite: 42 test xanh.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r162_journey_prefetcher_pipe_signal_test.dart`
— tạo `JourneyPrefetcher` thật, bật qua `AdManager().enableJourneyPrefetcher(...)`
trên tiến trình app thật, gọi `notifySignal('/store|deal', AdSlotType.interstitial)`,
phát 1 `AdShowEvent` thật qua `AdManager().debugEmit(...)`, xác nhận
`averageTimeToShow('/store|deal', ...)` trả về giá trị hợp lệ (không phải
`null`) — đúng bug thật task mô tả: trước fix, tín hiệu này sẽ bị bỏ qua
vĩnh viễn và `averageTimeToShow` luôn trả `null`. PASS.

**Tự chấm điểm: 9.5/10.** Trừ điểm vì: bug thuộc loại logic thuần túy
(không có UI hiển thị trực tiếp), example app hiện chưa dùng
`JourneyPrefetcher` trong bất kỳ màn hình demo nào — bằng chứng device
chỉ qua API nội bộ chứ không qua thao tác chạm màn hình thực tế.
