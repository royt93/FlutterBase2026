# T184 — Lưu tạm trạng thái quảng cáo trong bộ nhớ mã hoá để mở lại app nhanh hơn

**Loại:** idea (thử nghiệm, chấp nhận làm)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Làm (lưu ý: phải có cơ chế lưu định kỳ xuống đĩa để bù lại rủi ro mất dữ liệu khi app bị tắt đột ngột — đã nêu rõ trong lúc hỏi ý kiến)

## Ý tưởng
Thay vì lưu trạng thái phiên quảng cáo xuống đĩa mỗi lần, giữ tạm trong bộ nhớ mã hoá (AES-GCM, key tạo tạm mỗi phiên trong RAM) để mở lại app nhanh hơn (ít đợi chờ đĩa — loại bỏ độ trễ I/O khi chuyển background/foreground).

## Rủi ro đã xác nhận với chủ dự án
Nếu hệ điều hành tắt hẳn app đột ngột (hay xảy ra khi chạy nền lâu), dữ liệu snapshot chưa kịp lưu xuống đĩa có thể mất. **Chủ dự án đã đồng ý chấp nhận rủi ro này NHƯNG yêu cầu bắt buộc có cơ chế ghi định kỳ (periodic write-through) xuống storage để giảm thiểu mất mát** — không được chỉ giữ trong RAM thuần không có bù đắp nào.

## Việc cần làm
1. Thiết kế snapshot: trạng thái phiên quảng cáo nào thực sự cần cache nhanh (không phải toàn bộ state — chỉ phần đọc/ghi thường xuyên lúc resume, VD trạng thái slot hiện tại, không phải VIP/consent vốn đã có cơ chế riêng).
2. Mã hoá AES-GCM với key tạo mỗi phiên (không lưu key xuống đĩa — key sống trong RAM, mất theo phiên).
3. Thêm cơ chế ghi định kỳ xuống `AdPreferences`/SharedPreferences (VD mỗi N giây hoặc mỗi lần thay đổi quan trọng) để bù lại rủi ro mất dữ liệu khi bị kill.
4. Viết test: resume nhanh hơn có thể đo được (so sánh thời gian trước/sau); mô phỏng "app bị kill" giữa 2 lần ghi định kỳ, xác nhận dữ liệu chỉ mất tối đa khoảng thời gian giữa 2 lần ghi (không mất toàn bộ).
5. Thêm demo trong `example/` đo thời gian resume trước/sau.
6. Cập nhật CHANGELOG.md và README.md (giải thích cơ chế mới, giới hạn dữ liệu có thể mất tối đa bao lâu).

## Prompt để chạy loop-fix
```
Thiết kế và implement cơ chế lưu tạm trạng thái phiên quảng cáo trong bộ nhớ mã hoá (AES-GCM, key tạo mỗi phiên, không lưu key xuống đĩa) để giảm độ trễ I/O khi resume app, ĐỒNG THỜI bắt buộc có cơ chế ghi định kỳ (periodic write-through) xuống AdPreferences/SharedPreferences để giảm thiểu mất dữ liệu nếu app bị OS kill đột ngột — đây là yêu cầu bắt buộc từ chủ dự án, không được bỏ qua. Xác định rõ phạm vi state nào cần cache nhanh (không phải toàn bộ SDK state, chỉ phần đọc/ghi thường xuyên lúc resume). Viết test: đo thời gian resume trước/sau (nếu có benchmark harness sẵn, dùng lại; nếu không, đo bằng timestamp trong integration test); mô phỏng kill giữa 2 lần ghi định kỳ, xác nhận mất dữ liệu tối đa đúng bằng khoảng ghi định kỳ, không mất toàn bộ phiên. Thêm demo đo thời gian resume trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho mã hoá/giải mã snapshot; test ghi định kỳ; test mô phỏng kill giữa 2 lần ghi (mất dữ liệu có giới hạn, không mất toàn bộ).
3. Demo đo thời gian resume trong `example/` + CHANGELOG.md/README.md cập nhật (ghi rõ giới hạn mất dữ liệu tối đa).
4. Audit độc lập (đặc biệt kiểm tra kỹ: key AES-GCM không bị lưu/leak xuống đĩa hay log) — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, đo thời gian resume trước/sau bằng số liệu thật; test kill app (force-stop) giữa chừng, mở lại, xác nhận dữ liệu chỉ mất trong giới hạn đã thiết kế.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
