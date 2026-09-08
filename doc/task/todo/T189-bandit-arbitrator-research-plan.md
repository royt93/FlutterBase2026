# T189 — Tự "học" chọn mạng quảng cáo trả tiền cao nhất theo thời gian thực (NGHIÊN CỨU, CHƯA CODE)

**Loại:** exclusive-feature (idea, rủi ro trung bình)
**Ưu tiên:** P2 (nghiên cứu)
**Trạng thái:** todo (research-only, KHÔNG code ngay)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Chưa làm, chỉ ghi plan vào backlog

## Ý tưởng
Hiện SDK tự đổi qua mạng quảng cáo trả tiền cao hơn theo luật đơn giản (`MonetizationArbitrator` — nếu 1 mạng lỗi nhiều thì chuyển). Ý tưởng mới: cho SDK "tự học" thông minh hơn (thuật toán multi-armed bandit) để luôn chọn đúng mạng trả tiền cao nhất theo thời gian thực, cân bằng giữa "khai thác" (chọn mạng tốt nhất hiện biết) và "khám phá" (thử mạng khác để cập nhật thông tin mới).

## Rủi ro đã xác nhận với chủ dự án
Nếu thuật toán "tự học" sai lúc đầu (dữ liệu chưa đủ), có thể chọn nhầm mạng trả ít tiền hơn một thời gian trước khi tự sửa — ảnh hưởng trực tiếp tới doanh thu đang ổn định. **Chủ dự án chọn KHÔNG làm ngay, chỉ ghi kế hoạch, vì rủi ro giảm doanh thu tạm thời chưa xứng đáng so với lợi ích chưa kiểm chứng.**

## Việc cần làm (CHỈ giai đoạn nghiên cứu — KHÔNG code)
1. Đọc kỹ `MonetizationArbitrator` hiện tại (`packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`) để hiểu đúng luật đơn giản đang dùng và giới hạn của nó.
2. Nghiên cứu thuật toán bandit phù hợp cho bối cảnh client-side, dữ liệu ít, không có backend trung tâm để tổng hợp (VD epsilon-greedy đơn giản, Thompson Sampling nhẹ) — so sánh độ phức tạp implement vs độ an toàn (tránh chọn sai kéo dài).
3. Đề xuất cơ chế "an toàn khi mới học" (cold-start guard): trong giai đoạn đầu (dữ liệu ít), ưu tiên hành vi gần giống luật đơn giản hiện tại, chỉ "khám phá" mạnh hơn khi đã có đủ dữ liệu tin cậy.
4. Đề xuất cách A/B test nội bộ trước khi bật thật cho toàn bộ người dùng (VD bật cho 1 tỷ lệ nhỏ, so sánh doanh thu với nhóm còn lại dùng luật cũ).
5. Viết kết luận vào mục "Kết luận nghiên cứu" bên dưới.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Đọc kỹ packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart và test tương ứng để hiểu đúng luật đơn giản hiện tại. KHÔNG code tính năng mới. Viết bản kế hoạch (design doc) trả lời: (1) thuật toán bandit nào phù hợp cho bối cảnh client-side (không backend trung tâm, dữ liệu mỗi thiết bị độc lập) — so sánh epsilon-greedy vs Thompson Sampling vs phương án khác, (2) cơ chế cold-start guard để tránh chọn sai kéo dài lúc dữ liệu còn ít, (3) cách A/B test an toàn trước khi bật thật cho mọi người dùng, (4) effort ước tính, (5) rủi ro cụ thể còn lại sau khi có cold-start guard. Cập nhật kết luận vào file task T189 này, không sửa code SDK.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới. KHÔNG commit code mới. Chờ chủ dự án đọc và quyết định có chuyển thành task code thật hay không — ĐẶC BIỆT cần chủ dự án xác nhận rõ ràng trước khi bắt đầu code, vì đây là thay đổi ảnh hưởng trực tiếp tới doanh thu đang ổn định.

## Kết luận nghiên cứu
(để trống, điền sau khi nghiên cứu xong)
